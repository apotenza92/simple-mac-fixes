import unittest
from contract import parse_tag, package, native_matrix

class ReleaseContractTests(unittest.TestCase):
    def test_native_jobs_cover_all_required_packages_once(self):
        for tag in ['v0.1.4', 'v0.1.4-beta.1']:
            jobs = native_matrix(tag)['include']
            self.assertEqual(len(jobs), 2)
            self.assertEqual({job['arch'] for job in jobs}, {'arm64', 'x64'})
            assets = [package(tag, channel, job['arch'])['asset']
                      for job in jobs for channel in parse_tag(tag)['channels']]
            self.assertEqual(len(assets), len(set(assets)))
            self.assertEqual(len(assets), 4 if '-beta.' not in tag else 2)

    def test_beta_never_produces_stable(self):
        self.assertEqual(parse_tag('v0.1.0-beta.1')['channels'], ['beta'])
        with self.assertRaises(ValueError):
            package('v0.1.0-beta.1', 'stable', 'arm64')

    def test_stable_advances_both_tracks(self):
        self.assertEqual(parse_tag('v0.1.0')['channels'], ['stable', 'beta'])
        self.assertGreater(int(parse_tag('v0.1.0')['build']), int(parse_tag('v0.1.0-beta.89999')['build']))

    def test_distinct_identity_and_asset(self):
        stable = package('v0.1.0', 'stable', 'arm64')
        beta = package('v0.1.0', 'beta', 'arm64')
        self.assertNotEqual(stable['bundle_id'], beta['bundle_id'])
        self.assertNotEqual(stable['asset'], beta['asset'])
        self.assertEqual(stable['bundle_id'], 'com.apotenza.SimpleMacFixes')

    def test_invalid_versions(self):
        for tag in ['1.0.0', 'v1.0.0-rc.1', 'v1.0.0-beta.0', 'v01.0.0', 'v1.1000.0', 'v1.0.0-beta.90000']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)

if __name__ == '__main__':
    unittest.main()
