#!/usr/bin/env python3
"""Generate clangd's compilation database without rebuilding the game."""
import argparse
import json
import subprocess

from recomp_paths import D3DM_DEPS, D3DM_OUT, DEPS, GRAPHICS_INCLUDES, INCLUDE, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='also check representative files with clangd')
    args = parser.parse_args()
    if not (DEPS / 'include/Zydis/Zydis.h').is_file():
        parser.error('missing Zydis headers; run tools/recomp_build.sh first')

    includes = [INCLUDE, '-Irecomp/src', '-Iruntime']
    commands = []
    for directory in ('runtime', 'recomp/src', 'recomp/tools', 'recomp/tests', 'd3d12-metal'):
        for source in sorted((ROOT / directory).rglob('*')):
            if source.suffix not in ('.c', '.cpp', '.mm'):
                continue
            relative = source.relative_to(ROOT).as_posix()
            compiler = 'clang'
            flags = ['-arch', 'arm64', '-std=gnu11', '-O2', '-g', '-Wall', '-Wextra',
                     '-Wno-unused-parameter', *includes]
            if source.name in ('test_bbcpu.c', 'x86_oracle.c', 'jit_guest.c'):
                flags[1] = 'x86_64'
                flags += ['-mavx', '-msse4.1', '-mpopcnt', '-mbmi', '-mlzcnt']
            elif source.suffix in ('.cpp', '.mm'):
                compiler = 'clang++'
                flags[2] = '-std=c++20'
                if directory in ('runtime', 'd3d12-metal'):
                    flags += [*GRAPHICS_INCLUDES, '-Id3d12-metal/src']
                    if directory=='d3d12-metal': flags += [f'-I{D3DM_OUT / "obj"}']
                    flags += ['-fno-exceptions', '-fno-rtti']
                if source.suffix == '.mm':
                    flags += ['-fobjc-arc']
            fixture = {'cpu_identity_test.c': 'build/recomp/cpu-identity/fixture',
                       'dispatch_test.c': 'build/recomp/dispatch',
                       'scan_oracle_test.c': 'build/recomp/dispatch',
                       'memory_order_test.c': 'build/recomp/memory-order'}.get(source.name)
            if fixture:
                flags += [f'-I{fixture}']
            if source.name == 'descriptor_test.mm':
                flags += [f'-I{D3DM_DEPS / "metal-irconverter-runtime"}']
            commands.append({'directory': str(ROOT), 'file': str(source),
                             'arguments': [compiler, *flags, '-c', relative]})

    database = ROOT / 'compile_commands.json'
    database.write_text(json.dumps(commands, indent=2) + '\n')
    print(f'{database}: {len(commands)} source files')
    if args.check:
        for source in ('runtime/package.mm', 'runtime/graphics.mm', 'runtime/loader.cpp',
                       'runtime/window.mm', 'runtime/files.cpp', 'runtime/sync.cpp', 'runtime/audio.mm',
                       'runtime/tests/runtime_test.cpp', 'runtime/tests/crt_test.cpp',
                       'runtime/tests/launcher_test.mm', 'd3d12-metal/src/device.mm',
                       'd3d12-metal/src/swapchain.mm', 'd3d12-metal/src/descriptors.mm',
                       'd3d12-metal/src/pipeline.mm', 'd3d12-metal/src/commands.mm',
                       'd3d12-metal/tests/descriptor_test.mm', 'd3d12-metal/tests/resource_test.mm',
                       'd3d12-metal/tests/command_test.mm', 'recomp/src/cpu/cpu.c',
                       'recomp/tools/recomp/replay.c', 'recomp/tests/x86_oracle.c'):
            # Apple clangd's refactoring self-tests fail on valid loops; check parsing/navigation only.
            subprocess.run(['clangd', f'--check={ROOT / source}', '--tweaks=none'], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
