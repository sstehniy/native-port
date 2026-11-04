#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pefile==2024.8.26", "dmgbuild==1.6.7"]
# ///
"""Package the native app and a drag-to-Applications disk image."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import struct
import tempfile
from pathlib import Path

from recomp_paths import D3DM_OUT, GAME_EXE, GRAPHICS_INCLUDES

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/recomp'
VERSION = '12'
APP_NAME = 'Order of the Sinking Star'
DEFAULT_GAME = GAME_EXE


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def install_icon(exe, app):
    import pefile

    with pefile.PE(str(exe)) as pe:
        resources = {entry.id: entry.directory.entries for entry in pe.DIRECTORY_ENTRY_RESOURCE.entries}
        group = resources[14][0].directory.entries[0]
        data = pe.get_data(group.data.struct.OffsetToData, group.data.struct.Size)
        reserved, kind, count = struct.unpack_from('<HHH', data)
        if reserved != 0 or kind != 1 or not count:
            raise ValueError('invalid game icon group')
        entries = [struct.unpack_from('<BBBBHHIH', data, 6 + 14 * i) for i in range(count)]
        largest = max(entries, key=lambda e: ((e[0] or 256) * (e[1] or 256), e[5]))
        image = next(e for e in resources[3] if e.id == largest[7]).directory.entries[0]
        pixels = pe.get_data(image.data.struct.OffsetToData, image.data.struct.Size)
        if len(pixels) != largest[6]:
            raise ValueError('game icon resource size mismatch')
    icon = app / 'Contents/Resources/GameIcon.icns'
    with tempfile.TemporaryDirectory(prefix='game-icon-', dir=BUILD) as temporary:
        folder = Path(temporary)
        source = folder / 'game.ico'
        source.write_bytes(struct.pack('<HHH', 0, 1, 1) +
                           struct.pack('<BBBBHHII', *largest[:6], len(pixels), 22) + pixels)
        iconset = folder / 'GameIcon.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = '@2x' if scale == 2 else ''
                subprocess.run(['sips', '-s', 'format', 'png', '-z', str(size * scale), str(size * scale),
                                str(source), '--out', str(iconset / f'icon_{size}x{size}{suffix}.png')],
                               check=True, capture_output=True)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(icon)], check=True)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIconFile'] = icon.name
    info_path.write_bytes(plistlib.dumps(info))


def build_dmg(app):
    if plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] != VERSION:
        raise ValueError('app version differs from the current package version')
    import dmgbuild

    output = app.with_suffix('.dmg')
    with tempfile.TemporaryDirectory(prefix='dmg-', dir=app.parent) as temporary:
        image = Path(temporary) / output.name
        dmgbuild.build_dmg(str(image), APP_NAME, settings={
            'format': 'UDZO',
            'files': [str(app)], 'symlinks': {'Applications': '/Applications'},
            'icon': str(app / 'Contents/Resources/GameIcon.icns'),
            'background': 'builtin-arrow', 'window_rect': ((200, 200), (640, 280)),
            'icon_locations': {app.name: (140, 120), 'Applications': (500, 120)},
            # Hiding bundle extensions writes FinderInfo that breaks strict code-signature checks.
            'icon_size': 96, 'text_size': 14,
            'default_view': 'icon-view', 'show_status_bar': False,
            'show_toolbar': False, 'show_sidebar': False,
        })
        subprocess.run(['hdiutil', 'verify', str(image)], check=True)
        image.rename(output)
    return output


def bundle_game(exe, app):
    resources = app / 'Contents/Resources'
    game = resources / 'Game'
    game.mkdir()
    shutil.copy2(exe, game / 'sinking_star.exe')
    for name in ('data', 'data-common', 'data-pc'):
        source = exe.parent / name
        if any(path.is_symlink() for path in source.rglob('*')):
            raise ValueError(f'game content must not contain external links: {source}')
        shutil.copytree(source, game / name, ignore=shutil.ignore_patterns('.DS_Store'))
    shutil.copy2(exe.parent / 'Software Licenses.txt', game / 'Software Licenses.txt')
    licenses = resources / 'Licenses'
    licenses.mkdir(exist_ok=True)
    for source, name in ((ROOT / 'recomp/LICENSE', 'Recompiler-GPL-2.0.txt'),
                         (ROOT / 'runtime/UNICODE-LICENSE.txt', 'Unicode.txt'),
                         (ROOT / 'common/metal_converter.LICENSE.txt', 'Metal-Shader-Converter.txt')):
        shutil.copy2(source, licenses / name)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    for key in ('SSDefaultGameExecutable', 'SSSeedSaves'):
        info.pop(key, None)
    info_path.write_bytes(plistlib.dumps(info))


def write_readme(app):
    (app / 'Contents/Resources/README.txt').write_text(
        f'{APP_NAME}, personal development build\n\n'
        'Open the DMG and drag the game icon to Applications, then eject the disk image.\n'
        'Double-click the installed app in Applications to play.\n'
        'All game content is included. No separate game installation is needed.\n'
        'Requires Apple Silicon and macOS 27 or later. No Wine, CrossOver or Rosetta is needed.\n'
        'Startup can take tens of seconds. Menus use arrows and Enter.\n'
        'First launch prepares captured graphics/compute pipelines for this GPU and macOS.\n'
        'The cache is reused until the GPU, macOS or pipeline data changes.\n'
        'Move/push: WASD. Undo: Z. Restart: R. Menu: Escape. Quit: Command-Q.\n\n'
        f'FPS overlay: Command-Shift-F, or {APP_NAME} > FPS Overlay.\n'
        'The Metal performance HUD includes FPS, frame time and GPU statistics. It starts hidden.\n\n'
        'New profiles start at 1080p, Very Performance, 4x MSAA On, VSync Off and a 60 FPS cap.\n'
        'These are the tested M1 settings. Existing preferences are kept.\n'
        'Change them under Graphics; display-size resolution costs substantially more GPU time.\n\n'
        'Original frame pacing is the default. Optional Smooth 30 FPS aims for steadier delivery\n'
        'using display sync, with more presentation delay. Keep the game cap at 60 and VSync Off.\n'
        'Enable Smooth 30 FPS in the launcher before pressing Play.\n'
        'Resolution, effects and save formats are unchanged by this setting.\n\n'
        'Undo can still produce visible pauses in either mode.\n\n'
        'Original upscaling is used by default to reduce GPU cost.\n'
        'Enable optional MetalFX upscaling in the launcher before pressing Play.\n'
        'Choose a lower resolution under Graphics > Resolution. UI stays at display resolution.\n'
        'Unverified shader variants keep the original scaling. No FPS improvement is guaranteed.\n\n'
        'Saves and logs: ~/Library/Application Support/Sinking Star Native/Player\n'
        'Each Mac uses its own native save profile. Existing native saves are kept.\n\n'
        'Known limits: occasional audio crackling; full content, progression and session\n'
        'verification remain unfinished. This is not the fully verified PB1 release.\n'
        'Ad-hoc signed for personal local use; not notarized or qualified for redistribution.\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=DEFAULT_GAME)
    parser.add_argument('--output', type=Path, default=BUILD / f'delivery/{APP_NAME}.app')
    parser.add_argument('--from-app', type=Path, help='reuse a verified app\'s libraries and shaders with the current native runtime')
    args = parser.parse_args()
    exe, app = args.exe.resolve(), args.output.resolve()
    for path in (exe, exe.parent / 'Software Licenses.txt', exe.parent / 'data/levels.package'):
        if not path.is_file():
            parser.error(f'missing game input: {path}')
    for name in ('data', 'data-common', 'data-pc'):
        if not (exe.parent / name).is_dir():
            parser.error(f'missing game content directory: {exe.parent / name}')
    if app.suffix != '.app':
        parser.error('--output must end in .app')
    for output in (app, app.with_suffix('.dmg')):
        if output.exists():
            parser.error(f'output already exists: {output}; choose a new --output')
    if args.from_app:
        if not (BUILD / 'sinking-star').is_file():
            parser.error('missing native runtime; run runtime/build.sh before packaging')
        source = args.from_app.resolve()
        info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
        if sha256(exe) != info['SSGameExecutableSHA256']:
            parser.error('game executable differs from the source app input')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
        shutil.copytree(source, app, ignore=lambda folder, names:
                        ['Game'] if Path(folder) == source / 'Contents/Resources' else [])
        info['CFBundleVersion'] = VERSION
        info['CFBundleName'] = APP_NAME
        info['CFBundleDisplayName'] = APP_NAME
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copy2(BUILD / 'sinking-star', app / 'Contents/MacOS/native-game')
        write_readme(app)
        install_icon(exe, app)
        bundle_game(exe, app)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app / 'Contents/MacOS/native-game')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        dmg = build_dmg(app)
        print(json.dumps({'app': str(app), 'dmg': str(dmg), 'source_app': str(source)}))
        return
    cache = BUILD / 'shaders/cache'
    for path in (exe, exe.parent / 'data/levels.package', BUILD / 'sinking-star',
                 BUILD / 'librecomp.dylib', BUILD / 'math/ucrt.dylib', BUILD / 'pe/frontend.json',
                 BUILD / 'pipelines/reference-summary.json'):
        if not path.is_file():
            parser.error(f'missing input: {path}')
    exe_hash = sha256(exe)
    if exe_hash != json.loads((BUILD / 'pe/frontend.json').read_text())['executable_sha256']:
        parser.error('game executable differs from the recompiled build input; rebuild before packaging')
    shaders = sorted(cache.glob('*.metallib'))
    if not shaders or any(not p.with_suffix('.json').is_file() for p in shaders):
        parser.error('missing prebuilt shader libraries or reflection')
    contents = app / 'Contents'
    for name in ('MacOS', 'Frameworks', 'Resources/shaders'):
        (contents / name).mkdir(parents=True, exist_ok=True)
    shutil.copy2(BUILD / 'sinking-star', contents / 'MacOS/native-game')
    library = contents / 'Frameworks/librecomp.dylib'
    shutil.copy2(BUILD / 'librecomp.dylib', library)
    math_library = contents / 'Frameworks/ucrt.dylib'
    shutil.copy2(BUILD / 'math/ucrt.dylib', math_library)
    subprocess.run(['install_name_tool', '-id', '@rpath/ucrt.dylib', str(math_library)], check=True)
    subprocess.run(['install_name_tool', '-id', '@rpath/librecomp.dylib', str(library)], check=True)
    for source in [*shaders, *(p.with_suffix('.json') for p in shaders)]:
        shutil.copy2(source, contents / 'Resources/shaders' / source.name)
    pipelines = contents / 'Resources/pipelines.json'
    shutil.copy2(BUILD / 'pipelines/reference-summary.json', pipelines)
    info = {
        'CFBundleExecutable': 'native-game', 'CFBundleIdentifier': 'local.sinking-star.native',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': APP_NAME,
        'CFBundleDisplayName': APP_NAME,
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1',
        'CFBundleVersion': VERSION, 'LSMinimumSystemVersion': '27.0',
        'LSArchitecturePriority': ['arm64'], 'NSHighResolutionCapable': True,
        'LSApplicationCategoryType': 'public.app-category.games', 'LSSupportsGameMode': True,
        'SSFPSOverlayToggle': True,
        'SSGameExecutableSHA256': exe_hash,
        'SSPipelineSHA256': sha256(pipelines),
    }
    subprocess.run(['clang++', '-arch', 'arm64', '-std=c++20', '-O2', '-fobjc-arc',
                    '-fno-exceptions', '-fno-rtti', *GRAPHICS_INCLUDES,
                    str(ROOT / 'runtime/shader_cache.mm'), str(ROOT / 'tools/recomp_pipeline_check.mm'),
                    str(D3DM_OUT / 'libd3d12-metal.a'), '-framework', 'AppKit', '-framework', 'MetalFX', '-framework', 'Metal',
                    '-framework', 'QuartzCore', '-o', str(contents / 'MacOS/prepare-pipelines')], check=True)
    identity = hashlib.sha256()
    for path in [pipelines, contents / 'MacOS/prepare-pipelines', *sorted((contents / 'Resources/shaders').iterdir())]:
        identity.update(bytes.fromhex(sha256(path)))
    info['SSPipelineSHA256'] = identity.hexdigest()
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    write_readme(app)
    install_icon(exe, app)
    bundle_game(exe, app)
    for binary in (library, math_library, contents / 'MacOS/native-game', contents / 'MacOS/prepare-pipelines'):
        assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
        subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    dmg = build_dmg(app)
    print(json.dumps({'app': str(app), 'dmg': str(dmg), 'shader_libraries': len(shaders),
                      'game_executable_sha256': info['SSGameExecutableSHA256']}))


if __name__ == '__main__':
    main()
