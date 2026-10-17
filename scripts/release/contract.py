"""Release naming shared by packaging and publication. Stable channel only."""
import re

REPOSITORY = 'apotenza92/simple-mac-fixes'
NAME = 'Simple Mac Fixes'
PREFIX = 'Simple-Mac-Fixes'
BUNDLE_ID = 'com.apotenza.SimpleMacFixes'
ARCHITECTURES = [('arm64', 'macos-15'), ('x64', 'macos-15-intel')]


def parse_tag(tag):
    match = re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag)
    if not match:
        raise ValueError('Expected vX.Y.Z')
    major, minor, patch = map(int, match.groups())
    if minor > 999 or patch > 999:
        raise ValueError('Version components exceed build-number limits')
    return {
        'tag': tag, 'version': f'{major}.{minor}.{patch}',
        # Leaves room below each release for a beta channel if one is ever added.
        'build': str((major * 1000000 + minor * 1000 + patch) * 100000 + 90000),
        'prerelease': False,
        'channels': ['stable'],
    }


def package(tag, channel, arch):
    meta = parse_tag(tag)
    if channel not in meta['channels'] or arch not in dict(ARCHITECTURES):
        raise ValueError('Invalid channel or architecture for this tag')
    return dict(meta, channel=channel, arch=arch, name=NAME, bundle_id=BUNDLE_ID,
                asset=f'{PREFIX}-{tag}-macos-{arch}.zip')


def native_matrix(tag):
    parse_tag(tag)
    return {'include': [dict(arch=arch, runner=runner) for arch, runner in ARCHITECTURES]}


if __name__ == '__main__':
    import argparse, json
    parser = argparse.ArgumentParser()
    parser.add_argument('tag')
    parser.add_argument('--native-matrix', action='store_true')
    parser.add_argument('--channel', choices=['stable'])
    parser.add_argument('--arch', choices=[arch for arch, _ in ARCHITECTURES])
    args = parser.parse_args()
    if args.native_matrix:
        print(json.dumps(native_matrix(args.tag)))
    else:
        print(json.dumps(package(args.tag, args.channel, args.arch) if args.channel else parse_tag(args.tag)))
