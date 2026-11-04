#!/usr/bin/env bash
# Builds and runs runtime/tests/runtime_test.cpp against the runtime (its main renamed away).
set -euo pipefail
cd -- "$(dirname -- "$0")/../.."
R=recomp
D=${BB_DEPS:-build/recomp/deps}
O=${BB_OUT:-build/recomp/toolchain}
./d3d12-metal/build.sh >/dev/null
H=${D3DM_DEPS:-build/d3d12-metal/deps}/DirectX-Headers
G=${D3DM_OUT:-build/d3d12-metal}/libd3d12-metal.a
mkdir -p build/recomp
F=(-arch arm64 -O1 -g -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -Wall -Werror -Wno-unused-parameter -I"$D/include" -I"$R/src" -I"$H/include" -I"$H/include/wsl/stubs" -Id3d12-metal/include)
clang++ "${F[@]}" -Dmain=loader_main -c runtime/loader.cpp -o build/recomp/loader_test.o
clang++ "${F[@]}" runtime/tests/runtime_test.cpp build/recomp/loader_test.o $(printf "%s\n" runtime/*.cpp runtime/*.mm | grep -v loader.cpp) "$O/libbbcpu.a" \
    "$D/lib/libZydis.a" "$D/lib/libZycore.a" "$G" -framework CoreGraphics -framework AppKit -framework QuartzCore -framework GameController -framework MetalFX -framework Metal -framework AudioToolbox -framework CoreAudio -o build/recomp/runtime_test
# Nano's aggregate statistics drift across realloc; use the standard allocator for live-block soak accounting.
MallocNanoZone=0 build/recomp/runtime_test

clang++ "${F[@]}" runtime/tests/crt_test.cpp build/recomp/loader_test.o $(printf "%s\n" runtime/*.cpp runtime/*.mm | grep -v loader.cpp) "$O/libbbcpu.a" \
    "$D/lib/libZydis.a" "$D/lib/libZycore.a" "$G" -framework CoreGraphics -framework AppKit -framework QuartzCore -framework GameController -framework MetalFX -framework Metal -framework AudioToolbox -framework CoreAudio -o build/recomp/crt_test
build/recomp/crt_test
