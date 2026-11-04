#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["dmgbuild==1.6.7"]
# ///
"""Mount the installer and verify its layout and every bundled file against the app."""
import argparse
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

from ds_store import DSStore
from recomp_package import APP_NAME, BUILD, sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=BUILD / f'delivery/{APP_NAME}.app')
    app = parser.parse_args().app.resolve()
    dmg = app.with_suffix('.dmg')
    subprocess.run(['hdiutil', 'verify', str(dmg)], check=True, capture_output=True)
    with tempfile.TemporaryDirectory(prefix='dmg-check-', dir=BUILD) as temporary:
        mount = Path(temporary)
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)],
                       check=True, capture_output=True)
        try:
            assert os.readlink(mount / 'Applications') == '/Applications'
            installed = mount / app.name
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
            expected = {str(p.relative_to(app)): sha256(p) for p in app.rglob('*') if p.is_file()}
            actual = {str(p.relative_to(installed)): sha256(p) for p in installed.rglob('*') if p.is_file()}
            assert actual == expected, 'disk image app differs from source'
            info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
            assert info['CFBundleName'] == info['CFBundleDisplayName'] == APP_NAME
            volume = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', str(mount)]))
            assert volume['VolumeName'] == APP_NAME
            assert 'SSDefaultGameExecutable' not in info and 'SSSeedSaves' not in info
            game = installed / 'Contents/Resources/Game'
            assert sha256(game / 'sinking_star.exe') == info['SSGameExecutableSHA256']
            assert (game / 'data/levels.package').is_file()
            assert all((game / name).is_dir() for name in ('data', 'data-common', 'data-pc'))
            assert not any(p.is_symlink() for p in game.rglob('*'))
            icon = installed / 'Contents/Resources' / info['CFBundleIconFile']
            assert icon.read_bytes()[:4] == b'icns'
            for name in ('MacOS/native-game', 'MacOS/prepare-pipelines',
                         'Frameworks/librecomp.dylib', 'Frameworks/ucrt.dylib'):
                assert subprocess.check_output(['lipo', '-archs', str(installed / 'Contents' / name)],
                                               text=True).strip() == 'arm64'
            with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
                assert store[app.name]['Iloc'] == (140, 120)
                assert store['Applications']['Iloc'] == (500, 120)
                assert store['.']['icvp']['backgroundType'] == 2
                assert not store['.']['bwsp']['ShowToolbar']
                assert not store['.']['bwsp']['ShowSidebar']
            assert (mount / '.background.tiff').is_file()
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True)
    report = {'passed': True, 'app': str(app), 'dmg': str(dmg), 'dmg_sha256': sha256(dmg),
              'display_name': info['CFBundleDisplayName'], 'volume_name': volume['VolumeName'],
              'version': info['CFBundleVersion'],
              'matching_app_files': len(expected), 'arm64_binaries': 4,
              'signature': 'passed', 'original_icon_icns_sha256': sha256(app / 'Contents/Resources/GameIcon.icns'),
              'self_contained_game_content': True, 'developer_paths_in_bundle_metadata': False,
              'applications_link': '/Applications', 'finder_layout': 'app, arrow, Applications',
              'scope': 'Read-only installer mount, Finder metadata, icon, signatures and file equivalence; no gameplay.'}
    (app.parent / 'dmg-check.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
