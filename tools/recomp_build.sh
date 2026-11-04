#!/usr/bin/env bash
# One-command native build from the installed PE. Default outputs stay in ignored build/recomp/.
set -euo pipefail
SCRIPT=$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
cd -- "$(dirname -- "$SCRIPT")/.."
clean=0
if [[ ${1:-} == --clean ]]; then clean=1; shift; fi
if (($# > 1)); then echo "usage: $0 [--clean] [sinking_star.exe]" >&2; exit 2; fi
EXE=${1:-${SS_GAME_EXE:-}}
if [[ -z $EXE || ! -f $EXE ]]; then echo "usage: $0 [--clean] /path/to/sinking_star.exe" >&2; exit 2; fi
EXE=$(cd -- "$(dirname -- "$EXE")" && pwd)/$(basename -- "$EXE")
export SS_GAME_EXE="$EXE"
BB=recomp
PE=build/recomp/pe
G=build/recomp/gen
OPT=${OPT:-2}
# Optional compiler profiling: LTO=thin links librecomp.dylib with ThinLTO;
# PGO_GEN=1 instruments it; PGO_USE=<file.profdata> optimizes with a local profile.
LTO=${LTO:-}
PGO_GEN=${PGO_GEN:-}
PGO_USE=${PGO_USE:-}
GEN_FLAGS=()
LINK_FLAGS=()
if [[ $LTO == thin ]]; then GEN_FLAGS+=(-flto=thin); LINK_FLAGS+=(-flto=thin "-Wl,-cache_path_lto,$PWD/build/recomp/lto-cache"); fi
if [[ -n $PGO_GEN ]]; then GEN_FLAGS+=(-fprofile-instr-generate -DBB_PGO_GEN); LINK_FLAGS+=(-fprofile-instr-generate); fi
if [[ -n $PGO_USE ]]; then
    [[ $PGO_USE == /* ]] || PGO_USE="$PWD/$PGO_USE"
    GEN_FLAGS+=("-fprofile-instr-use=$PGO_USE" -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date)
fi
export BB_OUT=${BB_OUT:-$PWD/build/recomp/toolchain}
export BB_DEPS=${BB_DEPS:-$PWD/build/recomp/deps}
[[ $BB_OUT == /* ]] || export BB_OUT="$PWD/$BB_OUT"
[[ $BB_DEPS == /* ]] || export BB_DEPS="$PWD/$BB_DEPS"
export ZERO_AR_DATE=1 LC_ALL=C
D=$BB_DEPS
if ((clean)); then
    rm -rf "$G" build/recomp/runtime build/recomp/sinking-star.dSYM
    rm -f build/recomp/librecomp.dylib build/recomp/sinking-star
fi
mkdir -p "$G/new" build/recomp/logs
"$BB/build.sh"
uv run tools/recomp_pe.py "$EXE" --report "$PWD/$PE/frontend.json"

tail -n +2 "$PE/functions.tsv" | cut -f1 > "$PE/all.txt"
rm -f "$G"/new/*
BB_JIT=0 "$BB_OUT/recomp/bbrecomp" "$PE/image.elf" "$PE/functions.tsv" "$G/new/recomp.c" "@$PE/all.txt" \
    > build/recomp/logs/bbrecomp.log 2>&1
tail -n 1 build/recomp/logs/bbrecomp.log


{
    printf 'OPT=%s\n' "$OPT"
    printf 'LTO=%s PGO_GEN=%s PGO_USE=%s\n' "$LTO" "$PGO_GEN" "$PGO_USE"
    if [[ -n $PGO_USE ]]; then shasum -a 256 "$PGO_USE"; fi
    clang --version
    shasum -a 256 "$SCRIPT" "$BB/build.sh"
} > "$G/new/compiler-config.txt"
config_changed=0
if ! cmp -s "$G/new/compiler-config.txt" "$G/compiler-config.txt"; then config_changed=1; fi

# Every generated object includes these shared helpers and decoder types.
newest_header=$BB/src/recomp/rc.h
while IFS= read -r header; do
    if [[ $header -nt $newest_header ]]; then newest_header=$header; fi
done < <(find "$BB/src/cpu" "$BB/src/recomp" "$D/include" -type f -name '*.h')

for f in "$G"/recomp*.c; do [[ -e $f && ! -e $G/new/$(basename "$f") ]] && rm -f "$f" "$f.o" "$f.log"; done
changed=()
for f in "$G"/new/recomp*.c; do
    old=$G/$(basename "$f")
    if ((config_changed == 0)) && cmp -s "$f" "$old" && [[ -e $old.o && $old.o -nt $old && $old.o -nt $newest_header ]]; then continue; fi
    mv "$f" "$old"
    changed+=("$old")
done
echo "${#changed[@]} files to compile"
export BB D OPT
GEN_EXTRA="${GEN_FLAGS[*]:-}"
export GEN_EXTRA
compile() {
    # shellcheck disable=SC2086 # GEN_EXTRA holds separate flags (no spaces in their values)
    clang -arch arm64 "-O$OPT" $GEN_EXTRA -g -std=gnu11 -Wall -Wno-unused-label -Wno-unused-variable -ffp-contract=off \
        -fno-strict-aliasing -fvisibility=hidden -I"$D/include" -I"$BB/src" -c "$1" -o "$1.o" 2> "$1.log" \
        || { echo "failed: $1"; cat "$1.log"; return 1; }
}
export -f compile
if ((${#changed[@]})); then printf '%s\n' "${changed[@]}" | xargs -P "$(sysctl -n hw.ncpu)" -I{} bash -c 'compile {}'; fi
clang -arch arm64 "-O$OPT" ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} -Wl,-reproducible -dynamiclib "$G"/recomp*.o -o build/recomp/librecomp.dylib
mv "$G/new/compiler-config.txt" "$G/compiler-config.txt"
runtime/build.sh
echo "native build complete: build/recomp/sinking-star"
