#!/usr/bin/env python3
"""Sign the exact release archives for Sparkle and write the feeds and Homebrew cask.

Usage: SPARKLE_PRIVATE_ED_KEY=... prepare_publication.py TAG ASSETS_DIR OUTPUT_DIR
Writes OUTPUT_DIR/appcasts/stable-{arm64,x64}.xml and OUTPUT_DIR/Casks/simple-mac-fixes.rb.
"""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from contract import ARCHITECTURES, NAME, REPOSITORY, package, parse_tag

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
CASK_TOKEN = 'simple-mac-fixes'
MINIMUM_MACOS = '14.4'


def bundled_public_key():
    script = Path(__file__).resolve().parents[1] / 'build-app.sh'
    for line in script.read_text().splitlines():
        if 'sparkle_public_key=' in line:
            return line.split(':-', 1)[1].rstrip('}"')
    raise ValueError('No Sparkle public key in build-app.sh')


def appcast(tag, item, url, length, signature, notes):
    meta = parse_tag(tag)
    rss = ET.Element('rss', version='2.0')
    feed = ET.SubElement(rss, 'channel')
    ET.SubElement(feed, 'title').text = NAME
    release = ET.SubElement(feed, 'item')
    ET.SubElement(release, 'title').text = tag
    ET.SubElement(release, f'{{{NS}}}version').text = meta['build']
    ET.SubElement(release, f'{{{NS}}}shortVersionString').text = meta['version']
    ET.SubElement(release, f'{{{NS}}}minimumSystemVersion').text = MINIMUM_MACOS
    ET.SubElement(release, 'description', {f'{{{NS}}}format': 'plain-text'}).text = notes
    ET.SubElement(release, 'enclosure', {
        'url': url, 'length': str(length), 'type': 'application/octet-stream',
        f'{{{NS}}}edSignature': base64.b64encode(signature).decode(),
    })
    ET.indent(rss)
    return rss


def cask(tag, digests):
    sections = []
    for arch, _ in ARCHITECTURES:
        asset = package(tag, 'stable', arch)['asset'].replace(tag, 'v#{version}')
        sections.append(f'''  on_{"arm" if arch == "arm64" else "intel"} do
    sha256 "{digests[arch]}"

    url "https://github.com/{REPOSITORY}/releases/download/v#{{version}}/{asset}"
  end''')
    bundle_id = package(tag, 'stable', 'arm64')['bundle_id']
    return f'''cask "{CASK_TOKEN}" do
  version "{parse_tag(tag)['version']}"

{chr(10).join(sections)}

  name "{NAME}"
  desc "Fixes for behaviours that annoy people coming from Windows"
  homepage "https://github.com/{REPOSITORY}"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "{NAME}.app"

  zap trash: [
    "~/Library/Caches/{bundle_id}",
    "~/Library/HTTPStorages/{bundle_id}",
    "~/Library/Preferences/{bundle_id}.plist",
  ]
end
'''


def prepare(tag, assets, output, private_key):
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_key.strip(), validate=True))
    public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    if public != base64.b64decode(bundled_public_key()):
        raise ValueError('Signing key does not match the public key built into the app')
    notes = (Path('release-notes') / (tag + '.md')).read_text()
    (output / 'appcasts').mkdir(parents=True)
    (output / 'Casks').mkdir(parents=True)
    digests = {}
    for arch, _ in ARCHITECTURES:
        item = package(tag, 'stable', arch)
        data = (assets / item['asset']).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if (assets / (item['asset'] + '.sha256')).read_text().split() != [digest, item['asset']]:
            raise ValueError('Package checksum mismatch: ' + item['asset'])
        digests[arch] = digest
        signature = key.sign(data)
        key.public_key().verify(signature, data)
        url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{item['asset']}"
        ET.ElementTree(appcast(tag, item, url, len(data), signature, notes)).write(
            output / 'appcasts' / f'stable-{arch}.xml', encoding='utf-8', xml_declaration=True)
    (output / 'Casks' / f'{CASK_TOKEN}.rb').write_text(cask(tag, digests))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('tag')
    parser.add_argument('assets', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.tag, args.assets, args.output, os.environ['SPARKLE_PRIVATE_ED_KEY'])
