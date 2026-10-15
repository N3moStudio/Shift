#!/usr/bin/env python3
"""Check icon names, appearance variants and resources before an iOS build."""
from pathlib import Path
import json
import struct

ROOT = Path(__file__).resolve().parents[1]

def check():
    entries = json.loads((ROOT / 'Brand/AppearanceIcons/manifest.json').read_text(encoding='utf-8'))
    assert len(entries) == 9 and len({e['asset'] for e in entries}) == 9
    assert entries[0]['asset'] == 'AppIcon'
    settings = (ROOT / 'project.yml').read_text(encoding='utf-8')
    source = (ROOT / 'Shared/ShiftAppearance.swift').read_text(encoding='utf-8')
    for entry in entries:
        assert entry['design'].lower() in source
        if entry['asset'] != 'AppIcon':
            assert entry['asset'] in settings, entry['asset']
        directory = ROOT / 'Locus/Resources/Assets.xcassets' / (entry['asset'] + '.appiconset')
        images = json.loads((directory / 'Contents.json').read_text(encoding='utf-8'))['images']
        assert len(images) == 3
        assert [i.get('appearances', [{}])[0].get('value', 'any') for i in images] == ['any','dark','tinted']
        for image in images:
            data = (directory / image['filename']).read_bytes()
            assert data[:8] == b'\x89PNG\r\n\x1a\n'
            width,height,depth,color = struct.unpack_from('>IIBB',data,16)
            assert (width,height) == (1024,1024)
            assert depth == 8 and color in (0,2), 'App icons must have no alpha channel'
        preview = ROOT / 'Locus/Resources/IconPreviews' / (entry['preview'] + '.png')
        assert preview.is_file()
    assert 'Permission to use' in (ROOT / 'Brand/AppearanceIcons/LICENSE-Lucide.txt').read_text(encoding='utf-8-sig')
    print('Verified 9 icon choices, 27 native appearance images, previews and license.')

if __name__ == '__main__':
    check()
