import unittest
from contract import parse_tag, package, native_matrix


class ReleaseContractTests(unittest.TestCase):
    def test_native_jobs_cover_each_architecture_once(self):
        jobs = native_matrix('v0.0.1')['include']
        self.assertEqual([job['arch'] for job in jobs], ['arm64', 'x64'])
        assets = {package('v0.0.1', 'stable', job['arch'])['asset'] for job in jobs}
        self.assertEqual(assets, {'Simple-Mac-Fixes-v0.0.1-macos-arm64.zip', 'Simple-Mac-Fixes-v0.0.1-macos-x64.zip'})

    def test_stable_only(self):
        self.assertEqual(parse_tag('v0.0.1')['channels'], ['stable'])
        self.assertEqual(package('v0.0.1', 'stable', 'arm64')['bundle_id'], 'com.apotenza.SimpleMacFixes')
        with self.assertRaises(ValueError):
            package('v0.0.1', 'beta', 'arm64')

    def test_build_numbers_increase(self):
        builds = [int(parse_tag(t)['build']) for t in ['v0.0.1', 'v0.0.2', 'v0.1.0', 'v1.0.0']]
        self.assertEqual(builds, sorted(builds))
        self.assertEqual(parse_tag('v0.0.1')['build'], '190000')

    def test_invalid_versions(self):
        for tag in ['1.0.0', 'v1.0.0-beta.1', 'v1.0.0-rc.1', 'v01.0.0', 'v1.1000.0']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)


if __name__ == '__main__':
    unittest.main()
