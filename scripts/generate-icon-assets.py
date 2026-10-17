#!/usr/bin/env python3
"""Generate the switch artwork and native appearance-aware Icon Composer documents."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]

# Track and knob share one geometry with the 18-point menu glyph in AppIdentity.swift.
TRACK = dict(x=172, y=322, width=680, height=380, rx=190)
KNOB = dict(cx=662, cy=512, r=150)

COLORS = {
    ('stable', False): ('#5ad46b', '#1f9e3c'),
    ('stable', True): ('#74e383', '#2bb24b'),
    ('beta', False): ('#a77bf3', '#6535b7'),
    ('beta', True): ('#c3a2ff', '#8754e6'),
}


def artwork(channel, dark):
    top, bottom = COLORS[(channel, dark)]
    t, k = TRACK, KNOB
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<title>Simple Mac Fixes — {channel}, {'dark' if dark else 'light'}</title>
<desc>A switch in the on position on a transparent canvas. The menu icon uses the same geometry as an outline.</desc>
<defs>
  <linearGradient id="track" x1="0" y1="0" x2="0" y2="1"><stop stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>
  <linearGradient id="knob" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#ffffff"/><stop offset="1" stop-color="#e9edf0"/></linearGradient>
</defs>
<!-- A single full-bleed transparent canvas; macOS supplies the background and mask. -->
<rect x="{t['x']}" y="{t['y']}" width="{t['width']}" height="{t['height']}" rx="{t['rx']}" fill="url(#track)"/>
<circle cx="{k['cx']}" cy="{k['cy']}" r="{k['r']}" fill="url(#knob)"/>
</svg>
'''


def main():
    for channel in ['stable', 'beta']:
        name = 'AppIconBeta' if channel == 'beta' else 'AppIcon'
        package = ROOT / 'Resources' / f'{name}.icon'
        assets = package / 'Assets'
        assets.mkdir(parents=True, exist_ok=True)
        for dark in [False, True]:
            svg = artwork(channel, dark)
            (assets / ('artwork-dark.svg' if dark else 'artwork.svg')).write_text(svg)
            # Web preview keeps standard Mac icon padding; the native compiler supplies its own mask.
            tile = '#1e1e1e' if dark else '#ffffff'
            web = svg.replace('<defs>', '<defs><clipPath id="tile-mask"><rect x="100" y="100" width="824" height="824" rx="184"/></clipPath>', 1)
            marker = '<!-- A single full-bleed'
            web = web.replace(marker, f'<g clip-path="url(#tile-mask)"><rect x="100" y="100" width="824" height="824" fill="{tile}"/>'
                              '<g transform="translate(100 100) scale(.8046875)">\n' + marker, 1).replace('</svg>', '</g></g></svg>')
            docs = ROOT / 'docs' / 'assets'
            docs.mkdir(parents=True, exist_ok=True)
            (docs / f'icon-{channel}-{"dark" if dark else "light"}.svg').write_text(web)
        manifest = {
            'fill-specializations': [{'value': 'system-light'}, {'appearance': 'dark', 'value': 'system-dark'}],
            'groups': [{
                'layers': [{
                    'fill-specializations': [{'value': 'none'}, {'appearance': 'dark', 'value': 'none'}],
                    'image-name-specializations': [{'value': 'artwork.svg'}, {'appearance': 'dark', 'value': 'artwork-dark.svg'}],
                    'name': 'Switch',
                }],
                'shadow': {'kind': 'neutral', 'opacity': 0},
                'translucency': {'enabled': False, 'value': 0},
            }],
            'supported-platforms': {'squares': 'shared'},
        }
        (package / 'icon.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
