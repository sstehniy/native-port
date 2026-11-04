#!/usr/bin/env bash
# Build bbcpu and its scanner/recompiler. BB_OUT and BB_DEPS may put all outputs outside this fork.
set -euo pipefail
cd -- "$(dirname -- "$0")"
D=${BB_DEPS:-deps}
O=${BB_OUT:-out}
ZYDIS_VERSION=v4.1.1
CC=${CC:-clang}
export ZERO_AR_DATE=1
arch=()
[[ $(uname -s) == Darwin ]] && arch=(-arch "$(uname -m)")

if [[ ! -f $D/lib/libZydis.a ]]; then
    echo "== zydis $ZYDIS_VERSION into $D"
    prefix=$(mkdir -p "$D" && cd "$D" && pwd)
    work=$prefix/build
    mkdir -p "$work"
    [[ -d $work/zydis ]] || git clone -q --recursive --depth 1 -b "$ZYDIS_VERSION" https://github.com/zyantific/zydis.git "$work/zydis"
    common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF)
    cmake -S "$work/zydis/dependencies/zycore" -B "$work/zycore-build" "${common[@]}" >/dev/null
    cmake --build "$work/zycore-build" >/dev/null && cmake --install "$work/zycore-build" >/dev/null
    cmake -S "$work/zydis" -B "$work/zydis-build" "${common[@]}" -DZYAN_SYSTEM_ZYCORE=ON \
        -DCMAKE_C_FLAGS="-I$prefix/include" -DZYDIS_BUILD_TOOLS=OFF -DZYDIS_BUILD_EXAMPLES=OFF \
        -DZYDIS_BUILD_DOXYGEN=OFF >/dev/null
    cmake --build "$work/zydis-build" >/dev/null && cmake --install "$work/zydis-build" >/dev/null
fi

mkdir -p "$O/cpu" "$O/recomp"
for source in src/cpu/*.c src/cpu/hostcall.S; do
    "$CC" "${arch[@]}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wno-unused-parameter -I"$D/include" \
        -c "$source" -o "$O/cpu/$(basename "$source").o"
done
rm -f "$O/libbbcpu.a" && ar rcs "$O/libbbcpu.a" "$O"/cpu/*.o
echo "$O/libbbcpu.a"

"$CC" "${arch[@]}" -O2 -I"$D/include" -c tools/recomp/scan.c -o "$O/recomp/scan.o"
"$CC" "${arch[@]}" -Wl,-reproducible "$O/recomp/scan.o" "$D/lib/libZydis.a" "$D/lib/libZycore.a" -o "$O/recomp/scan"
"$CC" "${arch[@]}" -O1 -g -std=gnu11 -Wall -I"$D/include" -c tools/recomp/bbrecomp.c -o "$O/recomp/bbrecomp.o"
"$CC" "${arch[@]}" -Wl,-reproducible "$O/recomp/bbrecomp.o" "$O/libbbcpu.a" \
    "$D/lib/libZydis.a" "$D/lib/libZycore.a" -o "$O/recomp/bbrecomp"
echo "$O/recomp/scan, $O/recomp/bbrecomp"
