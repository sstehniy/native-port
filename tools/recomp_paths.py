"""Build paths shared by the native build's debugging and verification tools."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME_EXE = Path(os.environ.get('SS_GAME_EXE', str(Path.home() / 'Games/Order.of.the.Sinking.Star/sinking_star.exe'))).expanduser().resolve()
GAME_SHA256 = 'd63cd79580db594e59faf0df316d6733a86f3b172bc0a182335762388f0d4f8c'
TOOLCHAIN = (ROOT / os.environ.get('BB_OUT', 'build/recomp/toolchain')).resolve()
DEPS = (ROOT / os.environ.get('BB_DEPS', 'build/recomp/deps')).resolve()
INCLUDE = f'-I{DEPS / "include"}'
CPU_LIBS = [TOOLCHAIN / 'libbbcpu.a', DEPS / 'lib/libZydis.a', DEPS / 'lib/libZycore.a']
IMAGE_RESERVATION = [ROOT / 'runtime/image_reservation.S', '-Wl,-segaddr,__GUEST,0x140000000',
                     '-Wl,-segprot,__GUEST,rw,rw']

D3DM_DEPS = (ROOT / os.environ.get('D3DM_DEPS', 'build/d3d12-metal/deps')).resolve()
D3DM_OUT = (ROOT / os.environ.get('D3DM_OUT', 'build/d3d12-metal')).resolve()
GRAPHICS_INCLUDES = [f'-I{D3DM_DEPS / "DirectX-Headers/include"}',
                     f'-I{D3DM_DEPS / "DirectX-Headers/include/wsl/stubs"}', f'-I{ROOT / "d3d12-metal/include"}']

# clang accepts ARC for C++ translation units and applies it to the Objective-C++ backend.
UI_FLAGS = ['-fobjc-arc', '-framework', 'CoreGraphics', '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'GameController',
            '-framework', 'MetalFX', '-framework', 'Metal', '-framework', 'AudioToolbox', '-framework', 'CoreAudio', *GRAPHICS_INCLUDES, str(D3DM_OUT / 'libd3d12-metal.a')]


def runtime_sources(directory=ROOT / 'runtime'):
    return sorted([*directory.glob('*.cpp'), *directory.glob('*.mm')])
