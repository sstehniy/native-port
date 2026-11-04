# /// script
# requires-python = ">=3.11"
# dependencies = ["pefile==2024.8.26"]
# ///
"""Read the user-owned executable and generate local scanner/recompiler inputs."""
import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

import pefile

from recomp_paths import GAME_EXE, GAME_SHA256, ROOT, TOOLCHAIN

EXE = GAME_EXE
OUT = ROOT / 'build/recomp/pe'
SCAN = TOOLCHAIN / 'recomp/scan'
SUMMARY = OUT / 'frontend.json'

LOAD_SECTIONS = ('.text', '.rdata', '.data', '.pdata', '.tls', '_RDATA')
PT_LOAD, PT_GNU_EH_FRAME = 1, 0x6474E550
UNW_FLAG_EHANDLER, UNW_FLAG_UHANDLER, UNW_FLAG_CHAININFO = 1, 2, 4
IMAGE_REL_BASED_ABSOLUTE, IMAGE_REL_BASED_DIR64 = 0, 10


def align(v, a):
    return (v + a - 1) & ~(a - 1)


def section_of(pe, rva):
    for s in pe.sections:
        if s.VirtualAddress <= rva < s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData):
            return s.Name.rstrip(b'\0').decode()
    return None


def pdata_entries(pe):
    d = pe.OPTIONAL_HEADER.DATA_DIRECTORY[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXCEPTION']]
    raw = pe.get_data(d.VirtualAddress, d.Size)
    return [struct.unpack_from('<III', raw, i) for i in range(0, len(raw), 12)]


def unwind_facts(pe, entries):
    """Chained entries and the language-specific handlers (RVAs, not relocated) of each entry."""
    chained, handlers = 0, set()
    for _, _, info in entries:
        head = pe.get_data(info, 4)
        flags, codes = head[0] >> 3, head[2]
        if flags & UNW_FLAG_CHAININFO:
            chained += 1
        elif flags & (UNW_FLAG_EHANDLER | UNW_FLAG_UHANDLER):
            handlers.add(pe.get_dword_at_rva(info + 4 + 2 * align(codes, 2)))
    return chained, handlers


def reloc_pointers(pe):
    kinds, targets = {}, []
    base = pe.OPTIONAL_HEADER.ImageBase
    for block in pe.DIRECTORY_ENTRY_BASERELOC:
        for e in block.entries:
            kinds[e.type] = kinds.get(e.type, 0) + 1
            if e.type == IMAGE_REL_BASED_DIR64:
                targets.append(pe.get_qword_at_rva(e.rva) - base)
    return kinds, targets


def write_elf(pe, data, path, functions):
    """An ELF64 image at RVAs; scan.c and bbrecomp.c read its PT_LOADs and PT_GNU_EH_FRAME."""
    loads = []
    for s in pe.sections:
        name = s.Name.rstrip(b'\0').decode()
        if name in LOAD_SECTIONS:
            flags = (4 if s.Characteristics & 0x40000000 else 0) | (2 if s.Characteristics & 0x80000000 else 0) | \
                    (1 if s.Characteristics & 0x20000000 else 0)
            raw = data[s.PointerToRawData:s.PointerToRawData + min(s.SizeOfRawData, s.Misc_VirtualSize)]
            loads.append((s.VirtualAddress, raw, max(s.Misc_VirtualSize, len(raw)), flags))

    eh_at = align(pe.OPTIONAL_HEADER.SizeOfImage, 0x1000)
    count = len(functions)
    table_end = 12 + 8 * count
    eh = bytearray(struct.pack('<BBBBiI', 1, 0x1b, 0x03, 0x3b, 0, count))
    for i, (start, _) in enumerate(functions):
        eh += struct.pack('<ii', start - eh_at, table_end + 16 * i)
    for start, end in functions:
        eh += struct.pack('<IIiI', 12, 0, 0, end - start)  # length, CIE pointer (unused), pc_begin (unused), pc_range
    loads.append((eh_at, bytes(eh), len(eh), 4))

    phnum = len(loads) + 1
    offset = align(64 + 56 * phnum, 0x10)
    phdrs, body = [], bytearray()
    for vaddr, raw, memsz, flags in loads:
        eh_offset = offset + len(body)  # the last load is the unwind table
        phdrs.append(struct.pack('<IIQQQQQQ', PT_LOAD, flags, eh_offset, vaddr, vaddr, len(raw), memsz, 0x1000))
        body += raw
        body += bytes(align(len(body), 0x10) - len(body))
    phdrs.append(struct.pack('<IIQQQQQQ', PT_GNU_EH_FRAME, 4, eh_offset, eh_at, eh_at, 12 + 8 * count, 12 + 8 * count, 4))
    ehdr = struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + bytes(9), 2, 62, 1,
                       pe.OPTIONAL_HEADER.AddressOfEntryPoint, 64, 0, 0, 64, 56, phnum, 0, 0, 0)
    head = ehdr + b''.join(phdrs)
    path.write_bytes(head + bytes(offset - len(head)) + body)
    return eh_at


def jump_stub_target(pe, start, iat):
    """The import a function forwards to when it is only `jmp [rip+slot]` (ff 25, optionally REX.W)."""
    code = pe.get_data(start, 7)
    if code[0] == 0x48:
        code = code[1:]
    if code[:2] != b'\xff\x25':
        return None
    length = 7 if pe.get_data(start, 1)[0] == 0x48 else 6
    return iat.get(start + length + struct.unpack_from('<i', code, 2)[0])


def read_tsv(path):
    lines = path.read_text().splitlines()[1:]
    return [line.split('\t') for line in lines]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exe', nargs='?', type=Path, default=EXE)
    parser.add_argument('--report', type=Path, default=SUMMARY)
    args = parser.parse_args()
    exe = args.exe
    OUT.mkdir(parents=True, exist_ok=True)
    data = exe.read_bytes()
    if hashlib.sha256(data).hexdigest() != GAME_SHA256:
        parser.error('unsupported game executable; use the version identified in README.md')
    pe = pefile.PE(data=data)
    oh = pe.OPTIONAL_HEADER
    text = next(s for s in pe.sections if s.Name.startswith(b'.text'))
    text_lo, text_hi = text.VirtualAddress, text.VirtualAddress + text.Misc_VirtualSize

    entries = pdata_entries(pe)
    functions = sorted((b, e) for b, e, _ in entries)
    assert all(text_lo <= b < e <= text_hi for b, e in functions), '.pdata entry outside .text'
    overlaps = sum(1 for (b0, e0), (b1, _) in zip(functions, functions[1:]) if b1 < e0)
    chained, handlers = unwind_facts(pe, entries)

    reloc_kinds, reloc_targets = reloc_pointers(pe)
    export_dir = getattr(pe, 'DIRECTORY_ENTRY_EXPORT', None)
    exports = [e.address for e in export_dir.symbols] if export_dir else []
    seeds = {
        'relocations': {t for t in reloc_targets if text_lo <= t < text_hi},
        'exports': {a for a in exports if text_lo <= a < text_hi},
        'entry_point': {oh.AddressOfEntryPoint},
        'unwind_handlers': {h for h in handlers if text_lo <= h < text_hi},
    }
    pointers = sorted(set().union(*seeds.values()))
    (OUT / 'pointers.txt').write_text(''.join(f'{t:#x}\n' for t in pointers))

    iat = {}
    for d in pe.DIRECTORY_ENTRY_IMPORT:
        for imp in d.imports:
            name = imp.name.decode() if imp.name else f'#{imp.ordinal}'
            iat[imp.address - oh.ImageBase] = f'{d.dll.decode()}!{name}'

    tls = pe.DIRECTORY_ENTRY_TLS.struct
    image = {
        'image_base': oh.ImageBase, 'size_of_image': oh.SizeOfImage, 'entry_point': oh.AddressOfEntryPoint,
        'size_of_headers': oh.SizeOfHeaders,
        'stack_reserve': oh.SizeOfStackReserve, 'stack_commit': oh.SizeOfStackCommit,
        'sections': [{'name': s.Name.rstrip(b'\0').decode(), 'rva': s.VirtualAddress, 'virtual_size': s.Misc_VirtualSize,
                      'raw_offset': s.PointerToRawData, 'raw_size': s.SizeOfRawData,
                      'characteristics': s.Characteristics} for s in pe.sections],
        'tls': {'start_raw_data': tls.StartAddressOfRawData - oh.ImageBase,
                'end_raw_data': tls.EndAddressOfRawData - oh.ImageBase,
                'address_of_index': tls.AddressOfIndex - oh.ImageBase,
                'address_of_callbacks': tls.AddressOfCallBacks - oh.ImageBase,
                'size_of_zero_fill': tls.SizeOfZeroFill},
        'iat': {f'{k:#x}': v for k, v in sorted(iat.items())},
    }
    (OUT / 'image.json').write_text(json.dumps(image, indent=1) + '\n')

    elf = OUT / 'image.elf'
    eh_at = write_elf(pe, data, elf, functions)
    scan = subprocess.run([str(SCAN), str(elf), str(OUT), str(OUT / 'pointers.txt')],
                          capture_output=True, text=True, check=True)
    (OUT / 'scan.log').write_text(scan.stderr + scan.stdout)

    rows = read_tsv(OUT / 'functions.tsv')
    found = {int(a, 16): (int(size), int(n), int(bad)) for a, size, n, bad in rows}
    missing = [b for b, e in functions if found.get(b, (0,))[0] != e - b]
    assert all(text_lo <= a < text_hi for a in found), 'scan returned a function outside .text'
    unwound = {b for b, _ in functions}
    extra = {a: v for a, v in found.items() if a not in unwound}

    calls_through_iat = {}
    for caller, slot in read_tsv(OUT / 'slots.tsv'):
        slot = int(slot, 16)
        if slot in iat:
            calls_through_iat.setdefault(slot, set()).add(int(caller, 16))
    stubs = {}
    for start in found:
        name = jump_stub_target(pe, start, iat)
        if name:
            stubs[start] = name
    (OUT / 'imports.tsv').write_text('address\tname\n' + ''.join(f'{a:#x}\t{n}\n' for a, n in sorted((stubs | iat).items())))

    summary = {
        'executable_sha256': hashlib.sha256(data).hexdigest(),
        'command': 'uv run tools/recomp_pe.py (scan: recomp/, built by recomp/build.sh)',
        'outputs': 'build/recomp/pe/ (ignored): image.elf, image.json, pointers.txt, functions.tsv, calls.tsv, '
                   'slots.tsv, strings.tsv, imports.tsv, scan.log',
        'image_elf': {'loads': list(LOAD_SECTIONS), 'eh_frame_hdr_at': hex(eh_at), 'addresses': 'image offsets (RVAs)'},
        'pdata': {'entries': len(entries), 'chained_entries': chained, 'overlapping_entries': overlaps,
                  'distinct_language_handlers': len(handlers)},
        'relocations': {'by_type': {str(k): v for k, v in sorted(reloc_kinds.items())},
                        'dir64': len(reloc_targets), 'distinct_targets': len(set(reloc_targets)),
                        'distinct_targets_in_text': len(seeds['relocations'])},
        'discovery_seeds': {k: len(v) for k, v in seeds.items()} | {'pointers_txt': len(pointers)},
        'functions': {
            'total': len(found),
            'from_pdata': len(unwound),
            'pdata_missing_or_resized': len(missing),
            'extra_discovered': len(extra),
            'extra_bytes': sum(v[0] for v in extra.values()),
            'extra_instructions': sum(v[1] for v in extra.values()),
        },
        'instructions': {
            'in_functions': sum(v[1] for v in found.values()),
            'undecodable_bytes_in_functions': sum(v[2] for v in found.values()),
            'functions_with_undecodable_bytes': sum(1 for v in found.values() if v[2]),
            'bytes_covered': sum(v[0] for v in found.values()),
            'text_bytes': text.Misc_VirtualSize,
        },
        'imports': {'iat_slots': len(iat), 'slots_called': len(calls_through_iat),
                    'call_sites_functions': sum(len(c) for c in calls_through_iat.values()),
                    'jump_stub_functions': len(stubs),
                    'setjmp_call_sites': sum(len(c) for s, c in calls_through_iat.items() if 'setjmp' in iat[s])},
        'tls': {k: hex(v) for k, v in image['tls'].items()},
        'scan_output': scan.stdout.strip(),
        'scan_rounds': [line for line in scan.stderr.splitlines() if line.startswith('round')],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(summary, indent=1) + '\n')
    print(json.dumps(summary['functions']), json.dumps(summary['instructions']))
    if missing:
        sys.exit(f'{len(missing)} .pdata entries missing or resized, first {missing[0]:#x}')


if __name__ == '__main__':
    main()
