#!/usr/bin/env bash
# Build libd3d12-metal.a. D3DM_DEPS and D3DM_OUT may put the headers clone and outputs elsewhere.
set -euo pipefail
cd -- "$(dirname -- "$0")"
D=${D3DM_DEPS:-../build/d3d12-metal/deps}
O=${D3DM_OUT:-../build/d3d12-metal}
HEADERS_VERSION=v1.619.5
CXX=${CXX:-clang++}
export ZERO_AR_DATE=1

H=$D/DirectX-Headers
if [[ ! -f $H/include/directx/d3d12.h ]]; then
    echo "== DirectX-Headers $HEADERS_VERSION into $D"
    mkdir -p "$D"
    git clone -q --depth 1 -b "$HEADERS_VERSION" https://github.com/microsoft/DirectX-Headers.git "$H"
fi

mkdir -p "$O/obj"
xcrun metal -std=metal3.1 -mmacosx-version-min=14.0 -c src/utility.metal -o "$O/obj/utility.air"
xcrun metallib "$O/obj/utility.air" -o "$O/obj/utility.metallib"
xxd -i -n d3dm_utility "$O/obj/utility.metallib" > "$O/obj/utility_metallib.h"
for source in src/*.mm; do
    "$CXX" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O2 -g -Wall -Wextra -Werror \
        -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude -I"$O/obj" \
        -c "$source" -o "$O/obj/$(basename "$source").o"
done
# The upstream DEFINE_GUID constants, such as WKPDID_D3DDebugObjectNameW.
"$CXX" -arch arm64 -std=c++20 -O2 -I"$H/include" -I"$H/include/wsl/stubs" -c "$H/src/dxguids.cpp" -o "$O/obj/dxguids.o"
rm -f "$O/libd3d12-metal.a" && ar rcs "$O/libd3d12-metal.a" "$O"/obj/*.o
echo "$O/libd3d12-metal.a"
