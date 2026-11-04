#!/usr/bin/env python3
"""Check d3dm_dxgi.h against MinGW-w64's DXGI headers: base interface, IID, vtable order and parameter types.

The MinGW headers are only read for comparison; nothing is copied from them.
Usage: check_abi.py [MINGW_INCLUDE_DIR]
"""
import re
import sys
import subprocess
from pathlib import Path

OURS = Path(__file__).resolve().parent.parent / "include" / "d3dm_dxgi.h"

INTERFACE = re.compile(r"\b(IDXGI\w+)\s*:\s*public\s+(\w+)\s*\{(.*?)\n\};", re.S)
METHOD = re.compile(r"virtual\s+(.+?)\s+STDMETHODCALLTYPE\s+(\w+)\s*\((.*?)\)\s*=\s*0\s*;", re.S)
OUR_UUID = re.compile(r"__CRT_UUID_DECL\((\w+),\s*([^)]*)\)")
MIDL = re.compile(r'MIDL_INTERFACE\("([0-9a-fA-F-]+)"\)\s*(\w+)')


def param_type(param):
    param = " ".join(param.split())
    if param in ("", "void"):
        return None
    # Drop the parameter name; keep pointer and const placement.
    param = re.sub(r"\s*\b\w+$", "", param) if re.search(r"[\w\]]\s+\w+$|\*\s*\w+$", param) else param
    return re.sub(r"\s*\*\s*", "*", param).replace("WINBOOL", "BOOL")


def interfaces(text):
    result = {}
    for name, base, body in INTERFACE.findall(text):
        methods = []
        for ret, method, params in METHOD.findall(body):
            types = [t for t in (param_type(p) for p in params.split(",")) if t]
            methods.append((" ".join(ret.split()).replace("WINBOOL", "BOOL"), method, types))
        result[name] = (base, methods)
    return result


def our_uuid(fields):
    v = [int(x, 16) for x in fields.split(",")]
    return f"{v[0]:08x}-{v[1]:04x}-{v[2]:04x}-{v[3]:02x}{v[4]:02x}-" + "".join(f"{x:02x}" for x in v[5:])


def main():
    if len(sys.argv) > 1:
        mingw = Path(sys.argv[1])
    else:
        root = subprocess.check_output(['x86_64-w64-mingw32-gcc', '-print-sysroot'], text=True).strip()
        candidates = [Path(root) / 'include', Path(root) / 'x86_64-w64-mingw32/include']
        mingw = next((path for path in candidates if (path / 'dxgi.h').is_file()), candidates[0])
    if not (mingw / 'dxgi.h').is_file():
        raise SystemExit(f'check_abi: DXGI headers missing: {mingw}')
    ours_text = OURS.read_text()
    theirs_text = "\n".join(p.read_text() for p in sorted(mingw.glob("dxgi*.h")))
    ours, theirs = interfaces(ours_text), interfaces(theirs_text)
    uuids = {name: our_uuid(fields) for name, fields in OUR_UUID.findall(ours_text)}
    their_uuids = {name: guid.lower() for guid, name in MIDL.findall(theirs_text)}
    errors = []
    for name, (base, methods) in ours.items():
        if name not in theirs:
            errors.append(f"{name}: not in MinGW headers")
            continue
        their_base, their_methods = theirs[name]
        if base != their_base:
            errors.append(f"{name}: base {base}, MinGW {their_base}")
        if uuids.get(name) != their_uuids.get(name):
            errors.append(f"{name}: IID {uuids.get(name)}, MinGW {their_uuids.get(name)}")
        for slot, (mine, other) in enumerate(zip(methods, their_methods)):
            if mine != other:
                errors.append(f"{name} method {slot}: {mine} vs MinGW {other}")
        if len(methods) != len(their_methods):
            errors.append(f"{name}: {len(methods)} methods, MinGW {len(their_methods)}")
    for error in errors:
        print("check_abi:", error, file=sys.stderr)
    count = sum(len(m) for _, m in ours.values())
    print(f"check_abi: {len(ours)} interfaces, {count} methods, {len(errors)} mismatches")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
