"""Regression fixtures for Xcode catalog icons and portable IPA resources."""
from copy import deepcopy
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_appearance
import check_ipa_appearance

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = json.loads((ROOT / 'Brand/AppearanceIcons/manifest.json').read_text())
APP = 'Payload/Locus.app/'
EXTENSION = APP + 'PlugIns/LocusActivity.appex/'


def executable(sdk=27):
    # Only the Mach-O header/build-version command is used by this validator.
    return (struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0)
            + struct.pack('<6I', 0x32, 24, 2, 18 << 16, sdk << 16, 0))


def png(size):
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data)))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>2I5B', size, size, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress((b'\0' + bytes(size * 3)) * size))
            + chunk(b'IEND', b''))


def fixture(catalog=True):
    entries = {}
    files = {APP + 'Locus': executable(), EXTENSION + 'LocusActivity': executable(),
             EXTENSION + 'Info.plist': plistlib.dumps({'CFBundleExecutable': 'LocusActivity'})}
    for entry in MANIFEST:
        asset = entry['asset']
        if catalog:
            # Xcode can emit only CFBundleIconName for compiled alternate icons.
            entries[asset] = {'CFBundleIconName': asset}
        else:
            stems = []
            for points, scales in [(20, [1, 2, 3]), (29, [1, 2, 3]), (40, [1, 2, 3]), (60, [2, 3])]:
                stem = asset + '-' + str(points)
                stems.append(stem)
                for scale in scales:
                    suffix = '' if scale == 1 else '@' + str(scale) + 'x'
                    files[APP + stem + suffix + '.png'] = png(points * scale)
            entries[asset] = {'CFBundleIconFiles': stems}
    icons = {'CFBundlePrimaryIcon': entries.pop('AppIcon'), 'CFBundleAlternateIcons': entries}
    info = {'CFBundleExecutable': 'Locus', 'CFBundleIcons': icons, 'CFBundleIcons~ipad': deepcopy(icons)}
    if catalog:
        # This is a metadata fixture, not a real compiled CoreUI catalog.
        files[APP + 'Assets.car'] = b'catalog-fixture'
    return info, files


class IPAIconTests(unittest.TestCase):
    def validate(self, info, files):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Shift.ipa'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr(APP + 'Info.plist', plistlib.dumps(info))
                for name, data in files.items():
                    archive.writestr(name, data)
            return check_ipa_appearance.check(path)

    def test_catalog_icons_without_loose_filename_declarations(self):
        result = self.validate(*fixture())
        self.assertEqual(result['icon_choices'], 9)
        self.assertEqual(result['resources'], 'asset catalog')

    def test_catalog_with_primary_png_fallback_and_name_only_alternates(self):
        info, files = fixture()
        for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            info[key]['CFBundlePrimaryIcon']['CFBundleIconFiles'] = ['AppIcon60x60']
        files[APP + 'AppIcon60x60@2x.png'] = png(120)
        self.assertEqual(self.validate(info, files)['icon_choices'], 9)

    def test_catalog_does_not_allow_undeclared_icon(self):
        info, files = fixture()
        info['CFBundleIcons']['CFBundleAlternateIcons']['AppIconGlacierDark'] = {}
        with self.assertRaises(ValueError):
            self.validate(info, files)

    def test_catalog_rejects_wrong_asset_name(self):
        info, files = fixture()
        info['CFBundleIcons~ipad']['CFBundleAlternateIcons']['AppIconGlacierDark']['CFBundleIconName'] = 'WrongIcon'
        with self.assertRaises(ValueError):
            self.validate(info, files)

    def test_catalog_rejects_missing_ipad_alternate(self):
        info, files = fixture()
        del info['CFBundleIcons~ipad']['CFBundleAlternateIcons']['AppIconGlacierDark']
        with self.assertRaises(ValueError):
            self.validate(info, files)

    def test_name_only_icons_require_nonempty_catalog(self):
        for data in (None, b''):
            with self.subTest(catalog=data):
                info, files = fixture()
                if data is None:
                    del files[APP + 'Assets.car']
                else:
                    files[APP + 'Assets.car'] = data
                with self.assertRaises(ValueError):
                    self.validate(info, files)

    def test_portable_system_size_icons_still_pass(self):
        result = self.validate(*fixture(catalog=False))
        self.assertEqual(result['resources'], 'explicit system-size PNGs')

    def test_portable_icons_cannot_omit_notification_size(self):
        info, files = fixture(catalog=False)
        del files[APP + 'AppIcon-20@3x.png']
        with self.assertRaises((ValueError, KeyError)):
            self.validate(info, files)

    def test_portable_icons_cannot_have_wrong_dimensions(self):
        info, files = fixture(catalog=False)
        files[APP + 'AppIcon-20@3x.png'] = png(20)
        with self.assertRaises(ValueError):
            self.validate(info, files)

    def test_old_sdk_is_still_rejected(self):
        info, files = fixture()
        files[APP + 'Locus'] = executable(sdk=25)
        with self.assertRaisesRegex(ValueError, 'predates Liquid Glass'):
            self.validate(info, files)


class SourceIconTests(unittest.TestCase):
    def test_all_published_icon_sources_match(self):
        check_appearance.check()

    def test_filename_case_is_checked_even_on_windows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'AppIcon-dark.png').write_bytes(b'image')
            with self.assertRaisesRegex(ValueError, 'case mismatch'):
                check_appearance.read_resource(root, 'AppIcon-Dark.png')
            self.assertEqual(check_appearance.read_resource(root, 'AppIcon-dark.png'), b'image')


if __name__ == '__main__':
    unittest.main()
