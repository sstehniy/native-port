#!/usr/bin/env bash
# Build the native runtime against bbcpu; tools/recomp_build.sh is the complete build entry point.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
D=${BB_DEPS:-build/recomp/deps}
O=${BB_OUT:-build/recomp/toolchain}
uv run tools/recomp_math_build.py
./d3d12-metal/build.sh >/dev/null
H=${D3DM_DEPS:-build/d3d12-metal/deps}/DirectX-Headers
G=${D3DM_OUT:-build/d3d12-metal}/libd3d12-metal.a
GF=(-I"$H/include" -I"$H/include/wsl/stubs" -Id3d12-metal/include)
rm -rf build/recomp/runtime && mkdir -p build/recomp/runtime
for source in runtime/*.cpp runtime/*.mm; do
    clang++ -arch arm64 -O2 -g -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -Wall -Wextra -Werror -Wno-unused-parameter -I"$D/include" -Irecomp/src "${GF[@]}" \
        -c "$source" -o "build/recomp/runtime/$(basename "$source").o"
done
clang++ -arch arm64 -Wl,-reproducible build/recomp/runtime/*.o "$O/libbbcpu.a" \
    "$D/lib/libZydis.a" "$D/lib/libZycore.a" "$G" runtime/image_reservation.S \
    -Wl,-segaddr,__GUEST,0x140000000 -Wl,-segprot,__GUEST,rw,rw -framework CoreGraphics -framework AppKit -framework QuartzCore -framework GameController -framework MetalFX -framework Metal -framework AudioToolbox -framework CoreAudio -o build/recomp/sinking-star
dsymutil build/recomp/sinking-star -o build/recomp/sinking-star.dSYM
echo build/recomp/sinking-star
