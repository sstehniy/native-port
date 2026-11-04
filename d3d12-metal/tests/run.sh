#!/usr/bin/env bash
# Build the library and run its native tests. They open windows and capture them, so they need a GUI session
# with screen-recording permission for the terminal.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
python3 tests/check_abi.py
./build.sh >/dev/null
D=${D3DM_DEPS:-../build/d3d12-metal/deps}
O=${D3DM_OUT:-../build/d3d12-metal}
H=$D/DirectX-Headers
"${CXX:-clang++}" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude tests/dxgi_test.mm "$O/libd3d12-metal.a" \
    -framework AppKit -framework MetalFX -framework Metal -framework QuartzCore -o "$O/dxgi_test"
"$O/dxgi_test"
"${CXX:-clang++}" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude -Isrc tests/device_test.mm "$O/libd3d12-metal.a" \
    -framework AppKit -framework MetalFX -framework Metal -framework QuartzCore -o "$O/device_test"
"$O/device_test"
"${CXX:-clang++}" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude tests/resource_test.mm "$O/libd3d12-metal.a" \
    -framework AppKit -framework MetalFX -framework Metal -framework QuartzCore -o "$O/resource_test"
env -u AGX_SUPPORT_D24_S8 "$O/resource_test"
# Independent, pinned Apple descriptor-table helpers are test-only dependencies.
IR="$D/metal-irconverter-runtime"
mkdir -p "$IR"
for file in metal_irconverter_runtime.h ir_tessellator_tables.h ir_raytracing.h; do
    if [[ ! -f "$IR/$file" ]]; then
        curl -fLsS "https://raw.githubusercontent.com/wmarti/metal-shader-converter/eb320d8a6d65fc15ef2c226da7a405f39cb0d697/include/metal_irconverter_runtime/$file" -o "$IR/$file"
    fi
done
(cd "$IR" && shasum -a 256 -c <<'HASHES'
d83db88b41945fc23340e8def1f401998ef5597e9f104505a02dbf4ff7db53a5  metal_irconverter_runtime.h
a7a799d47795674216d686d7dd077fd5a455af689bdf57c79770fd0f35120ebb  ir_tessellator_tables.h
738cbc24a3763f2832a46cb891b9c13c938b030e61b212e2bc6f1119cf7a94e1  ir_raytracing.h
HASHES
)
EXTRA=()
if [[ -n "${D3DM_DESCRIPTOR_CASES:-}" ]]; then EXTRA+=("-DD3DM_DESCRIPTOR_CASES=\"$D3DM_DESCRIPTOR_CASES\""); fi
"${CXX:-clang++}" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude -I"$IR" "${EXTRA[@]}" tests/descriptor_test.mm "$O/libd3d12-metal.a" \
    -framework AppKit -framework MetalFX -framework Metal -framework QuartzCore -o "$O/descriptor_test"
env -u AGX_SUPPORT_D24_S8 "$O/descriptor_test"
python3 - "$O/descriptor_test" <<'PY'
import signal
import subprocess
import sys
for case in ('misaligned', 'overflow', 'stale', 'gpu-source', 'dead-cbv', 'minmax'):
    result = subprocess.run([sys.argv[1], case], capture_output=True, text=True)
    if case == 'minmax' and result.returncode == 77:
        continue
    assert result.returncode == -signal.SIGABRT and 'd3d12-metal descriptor:' in result.stderr, (case, result.returncode, result.stderr)
print('descriptor_test: invalid handle/range/lifetime/copy-source controls passed')
PY
EXTRA=()
if [[ -n "${D3DM_ROOT_SIGNATURE_CASES:-}" ]]; then EXTRA+=("-DD3DM_ROOT_SIGNATURE_CASES=\"$D3DM_ROOT_SIGNATURE_CASES\""); fi
"${CXX:-clang++}" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude "${EXTRA[@]}" tests/root_signature_test.mm "$O/libd3d12-metal.a" \
    -framework AppKit -framework MetalFX -framework Metal -framework QuartzCore -o "$O/root_signature_test"
"$O/root_signature_test" "$O"
"${CXX:-clang++}" -arch arm64 -std=c++20 -fobjc-arc -fno-exceptions -fno-rtti -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -I"$H/include" -I"$H/include/wsl/stubs" -Iinclude tests/command_test.mm "$O/libd3d12-metal.a" \
    -framework AppKit -framework MetalFX -framework Metal -framework QuartzCore -o "$O/command_test"
"$O/command_test"
