#!/usr/bin/env python3
"""Verify app, extension and widgets share Shift's independent install identity."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
APP_ID = 'com.n3mostudio.shift'
GROUP = 'group.' + APP_ID


def check():
    project = (ROOT / 'project.yml').read_text(encoding='utf-8')
    ids = re.findall(r'PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)', project)
    assert ids == [APP_ID, APP_ID + '.activity'], 'App and extension bundle IDs must match Shift'
    for path in ['Locus/Resources/Locus.entitlements', 'LocusActivity/LocusActivity.entitlements']:
        entitlements = plistlib.loads((ROOT / path).read_bytes())
        assert entitlements.get('com.apple.security.application-groups') == [GROUP], path
    widget_source = (ROOT / 'Shared/WidgetLibrary.swift').read_text(encoding='utf-8')
    assert f'static let group = "{GROUP}"' in widget_source, 'Widget group does not match signing entitlements'
    info = plistlib.loads((ROOT / 'Locus/Resources/Info.plist').read_bytes())
    schemes = [scheme for item in info['CFBundleURLTypes'] for scheme in item['CFBundleURLSchemes']]
    assert schemes == ['shift'], 'Shift must not claim the upstream locus URL scheme'
    print('Verified independent Shift app, extension, URL scheme and widget group.')


if __name__ == '__main__':
    check()
