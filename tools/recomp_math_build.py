# /// script
# requires-python = ">=3.11"
# dependencies = ["pefile==2024.8.26"]
# ///
"""Recompile the pinned SDK math routines as local arm64 code."""
import collections
import json
import subprocess

import pefile

from recomp_ucrt import NAMES, digest, microsoft_ucrt
from recomp_paths import DEPS, INCLUDE, ROOT, TOOLCHAIN
from recomp_pe import pdata_entries, read_tsv, reloc_pointers, write_elf

OUT = ROOT / 'build/recomp/math'

# CRT per-thread/app state, cookie validation and memset are supplied by runtime/math.cpp.
HOOKS = {0x12ac0, 0x1435c, 0x25b50, 0x9fabc, 0xb35d0, 0xed5c0}


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    directory, dll = microsoft_ucrt(ROOT / 'build/recomp/crt/oracle')
    pe = pefile.PE(data=dll)
    exports = {symbol.name.decode(): symbol.address for symbol in pe.DIRECTORY_ENTRY_EXPORT.symbols if symbol.name}
    roots = [exports[name] for name in NAMES]
    image = bytearray(pe.get_memory_mapped_image())
    image.extend(bytes(pe.OPTIONAL_HEADER.SizeOfImage - len(image)))
    # Startup dispatch state for the pinned SDK image.
    image[0x1374c8:0x1374cc] = (5).to_bytes(4, 'little')
    image[0x138e60:0x138e64] = (3).to_bytes(4, 'little')
    relocs = [e.rva for block in pe.DIRECTORY_ENTRY_BASERELOC for e in block.entries if e.type == 10]
    text = next(s for s in pe.sections if s.Name.startswith(b'.text'))
    payload = '#include "math_image.h"\nstatic const unsigned char bytes[] = {\n'
    payload += ',\n'.join(','.join(map(str, image[i:i + 128])) for i in range(0, len(image), 128)) + '\n};\n'
    payload += 'static const uint32_t relocs[] = {' + ','.join(map(str, relocs)) + '};\n'
    payload += ('__attribute__((visibility("default"))) const SsMathImage ss_math_image = {'
                f'{len(image)},{text.VirtualAddress},{text.Misc_VirtualSize},bytes,relocs,{len(relocs)},'
                '{' + ','.join(map(str, roots)) + '}};\n')
    (OUT / 'payload.c').write_text(payload)
    entries = sorted((begin, end) for begin, end, _ in pdata_entries(pe))
    write_elf(pe, dll, OUT / 'image.elf', entries)
    _, pointers = reloc_pointers(pe)
    seeds = sorted(set(roots + [p for p in pointers if text.VirtualAddress <= p < text.VirtualAddress + text.Misc_VirtualSize]))
    (OUT / 'pointers.txt').write_text(''.join(f'{n:#x}\n' for n in seeds))
    with (OUT / 'scan.log').open('w') as log:
        subprocess.run([str(TOOLCHAIN / 'recomp/scan'), str(OUT / 'image.elf'), str(OUT), str(OUT / 'pointers.txt')],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    functions = {int(a, 16) for a, *_ in read_tsv(OUT / 'functions.tsv')}
    edges = collections.defaultdict(set)
    for a, b, *_ in read_tsv(OUT / 'calls.tsv'):
        edges[int(a, 16)].add(int(b, 16))
    seen = set()
    pending = roots[:]
    while pending:
        address = pending.pop()
        if address in seen:
            continue
        seen.add(address)
        if address not in HOOKS:
            pending.extend(edges[address])
    selected = sorted((seen & functions) - HOOKS)
    (OUT / 'closure.txt').write_text(''.join(f'{n:#x}\n' for n in selected))
    # Remove only stale generator outputs; the generator can change its number of shards.
    for path in OUT.glob('ucrt*.c'):
        path.unlink()
    with (OUT / 'generate.log').open('w') as log:
        subprocess.run([str(TOOLCHAIN / 'recomp/bbrecomp'), str(OUT / 'image.elf'), str(OUT / 'functions.tsv'),
                        str(OUT / 'ucrt.c'), '@' + str(OUT / 'closure.txt')], cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    with (OUT / 'compile.log').open('w') as log:
        subprocess.run(['clang', '-arch', 'arm64', '-O2', '-std=gnu11', '-fno-strict-aliasing', '-ffp-contract=off',
                        INCLUDE, '-Irecomp/src', '-Iruntime', '-dynamiclib', '-Wl,-reproducible',
                        *map(str, sorted(OUT.glob('ucrt*.c'))), str(OUT / 'payload.c'),
                        '-o', str(OUT / 'ucrt.dylib')], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    manifest = {'dll_sha256': digest(dll), 'functions': len(selected), 'exports': dict(zip(NAMES, roots)),
                'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
                'dependencies': str(DEPS), 'hooks': sorted(HOOKS)}
    (OUT / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'UCRT math: {len(selected)} functions -> {OUT / "ucrt.dylib"}')


if __name__ == '__main__':
    build()
