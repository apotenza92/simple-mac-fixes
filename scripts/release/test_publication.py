import base64
import hashlib
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
import prepare_publication as publication
from contract import package


class PublicationTests(unittest.TestCase):
    def test_feeds_and_cask_match_the_exact_archives(self):
        key = Ed25519PrivateKey.generate()
        private = base64.b64encode(key.private_bytes_raw()).decode()
        public = base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            assets = root / 'dist'
            assets.mkdir()
            (root / 'release-notes').mkdir()
            (root / 'release-notes' / 'v0.0.1.md').write_text('First release.\n')
            digests = {}
            for arch in ['arm64', 'x64']:
                asset = package('v0.0.1', 'stable', arch)['asset']
                (assets / asset).write_bytes(arch.encode() * 100)
                digests[arch] = hashlib.sha256((assets / asset).read_bytes()).hexdigest()
                (assets / (asset + '.sha256')).write_text(f'{digests[arch]}  {asset}\n')
            cwd = os.getcwd()
            os.chdir(root)
            try:
                with mock.patch.object(publication, 'bundled_public_key', return_value=public):
                    publication.prepare('v0.0.1', assets, root / 'out', private, commit='a' * 40, run_id='7', run_attempt='2')
            finally:
                os.chdir(cwd)
            for arch in ['arm64', 'x64']:
                feed = ET.parse(root / 'out' / 'appcasts' / f'stable-{arch}.xml')
                enclosure = feed.find('.//enclosure')
                self.assertIn(f'macos-{arch}.zip', enclosure.get('url'))
                signature = base64.b64decode(enclosure.get(f'{{{publication.NS}}}edSignature'))
                key.public_key().verify(signature, (assets / package('v0.0.1', 'stable', arch)['asset']).read_bytes())
            cask = (root / 'out' / 'Casks' / 'simple-mac-fixes.rb').read_text()
            self.assertIn('version "0.0.1"', cask)
            self.assertIn(digests['arm64'], cask)
            self.assertIn(digests['x64'], cask)
            self.assertIn('app "Simple Mac Fixes.app"', cask)
            with tarfile.open(root / 'out' / 'homebrew-publication.tar.gz') as bundle:
                self.assertEqual(sorted(bundle.getnames()), ['Casks/simple-mac-fixes.rb', 'SHA256SUMS', 'manifest.json'])
                manifest = json.load(bundle.extractfile('manifest.json'))
                self.assertEqual(bundle.extractfile('Casks/simple-mac-fixes.rb').read().decode(), cask)
                sums = bundle.extractfile('SHA256SUMS').read().decode()
            self.assertEqual(manifest['product'], 'simple-mac-fixes')
            self.assertEqual((manifest['channel'], manifest['casks']), ('stable', ['simple-mac-fixes.rb']))
            self.assertEqual(manifest['release_commit'], 'a' * 40)
            self.assertEqual(manifest['native_validation']['workflow_run_attempt'], 2)
            self.assertEqual({a['architecture']: a['sha256'] for a in manifest['artifacts']}, digests)
            self.assertIn(hashlib.sha256(cask.encode()).hexdigest() + '  Casks/simple-mac-fixes.rb', sums)

    def test_rejects_a_key_that_does_not_match_the_app(self):
        other = base64.b64encode(Ed25519PrivateKey.generate().private_bytes_raw()).decode()
        with tempfile.TemporaryDirectory() as root, self.assertRaises(ValueError):
            publication.prepare('v0.0.1', Path(root), Path(root) / 'out', other)

    def test_build_script_carries_the_public_key(self):
        self.assertEqual(len(base64.b64decode(publication.bundled_public_key())), 32)


if __name__ == '__main__':
    unittest.main()
