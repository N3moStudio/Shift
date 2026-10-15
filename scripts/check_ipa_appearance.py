#!/usr/bin/env python3
"""Prevent old-SDK UI compatibility and missing portable system icon resources."""
from pathlib import Path
import argparse
import json
import plistlib
import struct
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def linked_sdk(data):
    require(len(data) >= 32 and struct.unpack_from('<I', data)[0] == 0xFEEDFACF,
            'Expected a thin 64-bit iOS executable')
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        require(offset + 8 <= len(data), 'Truncated Mach-O header')
        command, size = struct.unpack_from('<II', data, offset)
        require(size >= 8 and offset + size <= len(data), 'Invalid Mach-O command')
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, 'Truncated build version')
            platform, minimum, sdk = struct.unpack_from('<III', data, offset + 8)
            require(platform == 2, 'Expected an iOS device build')
            require(sdk >> 16 >= 26, 'Linked SDK predates Liquid Glass; check the portable linker configuration')
            require(minimum <= sdk, 'Minimum OS exceeds the SDK')
            return '.'.join(str(v) for v in (sdk >> 16, (sdk >> 8) & 255, sdk & 255))
        offset += size
    raise ValueError('Missing linked SDK metadata')


def check(path):
    manifest = json.loads((Path(__file__).resolve().parents[1] / 'Brand/AppearanceIcons/manifest.json').read_text(encoding='utf-8'))
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, 'Damaged IPA')
        names = set(archive.namelist())
        apps = [name for name in names if name.startswith('Payload/') and name.count('/') == 2 and name.endswith('.app/Info.plist')]
        require(len(apps) == 1, 'Expected one app')
        app = apps[0].removesuffix('Info.plist')
        sdks = {}
        for info_path in [apps[0], app + 'PlugIns/LocusActivity.appex/Info.plist']:
            info = plistlib.loads(archive.read(info_path))
            require(not info.get('UIDesignRequiresCompatibility', False), 'Old UI compatibility is enabled')
            binary = info_path.removesuffix('Info.plist') + info['CFBundleExecutable']
            sdks[info['CFBundleExecutable']] = linked_sdk(archive.read(binary))
        info = plistlib.loads(archive.read(app + 'Info.plist'))
        has_catalog = app + 'Assets.car' in names and archive.getinfo(app + 'Assets.car').file_size > 0
        for key in ['CFBundleIcons', 'CFBundleIcons~ipad']:
            entries = info.get(key, {})
            require(set(entries.get('CFBundleAlternateIcons', {})) == {e['asset'] for e in manifest[1:]}, f'Incomplete alternate icons: {key}')
            for entry in manifest:
                icon = entries.get('CFBundlePrimaryIcon', {}) if entry == manifest[0] else entries['CFBundleAlternateIcons'][entry['asset']]
                label = f"{key}/{entry['asset']}"
                if has_catalog:
                    # actool may emit a catalog name without loose PNG filenames,
                    # especially for alternate icons. Require the correct asset
                    # reference, not the portable builder's CFBundleIconFiles.
                    require(icon.get('CFBundleIconName') == entry['asset'],
                            'Missing or incorrect asset catalog icon declaration: ' + label)
                    continue  # Source renditions are checked by check_appearance.py.
                require(bool(icon.get('CFBundleIconFiles')), 'Missing icon file declaration: ' + label)
                for points, scales in [(20, [1, 2, 3]), (29, [1, 2, 3]), (40, [1, 2, 3]), (60, [2, 3])]:
                    stem = entry['asset'] + '-' + str(points)
                    require(stem in icon['CFBundleIconFiles'], 'Missing system icon declaration: ' + stem)
                    for scale in scales:
                        suffix = '' if scale == 1 else '@' + str(scale) + 'x'
                        image = archive.read(app + stem + suffix + '.png')
                        require(image[:8] == b'\x89PNG\r\n\x1a\n', 'Not a PNG icon')
                        width, height, depth, color = struct.unpack_from('>IIBB', image, 16)
                        require((width, height) == (points * scale, points * scale), 'Incorrect system icon size')
                        require(depth == 8 and color in (0, 2), 'Icon must be opaque')
        return {'linked_sdks': sdks, 'icon_choices': len(manifest), 'resources': 'asset catalog' if has_catalog else 'explicit system-size PNGs'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.ipa), indent=2))
