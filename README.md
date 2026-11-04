# Order of the Sinking Star

An experimental native Apple Silicon port of **Order of the Sinking Star**, using static
recompilation of the Windows executable and a D3D12-to-Metal renderer. Includes a native launcher,
MetalFX spatial upscaling, optional Smooth 30 FPS pacing, and local saves.

**You must own your own copy of the game.** No game executable, assets, extracted shaders or
compiled game code are included in this repository. Do not upload generated game files or the
self-contained installer to this source repository.

## How it works

1. The recompiler reads your Windows executable and translates its x86-64 functions into C.
   Clang compiles those functions into an arm64 library. A small interpreter handles remaining
   instruction cases. The original executable and assets remain local runtime inputs.
2. The native runtime supplies the Windows services the game calls: files, threads, input,
   windows, audio and offline Steam interfaces.
3. The D3D12/DXGI layer maps graphics commands to Metal. Build tools extract shaders from your
   game and convert them locally. Pipeline preparation warms the GPU cache on first launch.

The resulting app runs without Wine, CrossOver or Rosetta. Build-time shader conversion currently
uses CrossOver's x86-64 Metal Shader Converter, which requires Rosetta; neither is bundled.

## Development

Requires an Apple Silicon Mac running macOS 27+, Xcode with the Metal toolchain, CMake, Ninja,
Python 3.11+, `uv`, liblz4, and a local CrossOver installation (tested with 26.3) for its shader converter and DXC libraries.
Build dependencies are fetched locally; proprietary tools and game content are not redistributed.

```sh
brew install cmake ninja python uv lz4
export SS_GAME_EXE="/path/to/Order of the Sinking Star/sinking_star.exe"
# Optional when CrossOver is installed elsewhere:
# export SS_METAL_CONVERTER="/path/to/Resources/libmetalirconverter.dylib"

tools/recomp_build.sh "$SS_GAME_EXE"
uv run tools/recomp_shaders.py
python3 tools/recomp_pipelines.py
uv run tools/recomp_package.py --exe "$SS_GAME_EXE"
```

The supported executable is the 8 October 2026 build with SHA-256
`d63cd79580db594e59faf0df316d6733a86f3b172bc0a182335762388f0d4f8c`.
Other game versions are not supported. The build checks this before recompilation.

All downloads, extracted inputs, generated C, binaries and installers stay under ignored `build/`.
The first build downloads the pinned Zydis/Zycore, DirectX-Headers and Microsoft SDK math inputs.
Recompilation can take substantial time and disk space. Subsequent builds reuse unchanged objects.

The code is organized as follows:

- `recomp/`: x86-64 decoder, interpreter fallback and static C generator.
- `runtime/`: native platform services, package setup and launcher.
- `d3d12-metal/`: D3D12/DXGI implementation backed by Metal.
- `tools/`: executable/shader preparation, pipeline configuration, builds and packaging.

For editor support, run `python3 tools/recomp_compdb.py` after building dependencies.
Run `python3 -m unittest discover -s tools -p 'test_*.py'` for build-input checks and
`runtime/tests/run.sh` for native runtime checks. Renderer tests are in `d3d12-metal/tests/run.sh`;
they require a GUI session and screen-recording permission. Some compute tests currently hit a
Metal compiler XPC failure on the development machine.

## Usage

Open `build/recomp/delivery/Order of the Sinking Star.dmg`, drag the app to Applications, then
open it. Choose MetalFX upscaling and/or Smooth 30 FPS in the launcher and press **Play**.
First launch prepares shaders for the current Mac. **Close** exits without starting the game.
Packages are self-contained but contain your game files, so keep them separate from the public source.

- Move/push: WASD or arrows. Undo: Z. Restart: R. Menu: Escape. Quit: Command-Q.
- FPS overlay: Command-Shift-F or the app menu.
- Smooth 30 FPS: keep the game's FPS cap at 60 and VSync off. It adds presentation latency.
- MetalFX: choose a lower scene resolution in the game's Graphics settings; UI remains sharp.

Existing saves and launcher preferences are retained. Native saves and logs remain at
`~/Library/Application Support/Sinking Star Native/Player`; the older folder name is intentional.
For development runs, supply the executable explicitly and use the generated shader cache:

```sh
SS_SHADER_CACHE="$PWD/build/recomp/shaders/cache" \
  build/recomp/sinking-star "$SS_GAME_EXE"
```

This is an unofficial work in progress. Gameplay, audio, long sessions and other Macs are not fully
qualified. Local packages are ad-hoc signed and are not notarized.

## License and credits

GPL-2.0-or-later; see [LICENSE](LICENSE). The recompiler is based on
[bloodborne-recomp](https://github.com/bloodborne-native/bloodborne-recomp), forked at
`b9652d75edc0a281f06cec0da6ff72e9f5150a70`, with earlier work from bbport and shadPS4.
Zydis/Zycore and DirectX-Headers retain their upstream licenses. The converter interface and Unicode
notices are retained under `common/` and `runtime/`. The game and proprietary build tools remain
subject to their owners' terms and are not covered by this project's license.
