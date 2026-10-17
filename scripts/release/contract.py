"""Release naming shared by packaging and the download manifest."""
import re

REPOSITORY = 'apotenza92/simple-mac-fixes'
NAME = 'Simple Mac Fixes'
PREFIX = 'Simple-Mac-Fixes'


def parse_tag(tag):
    match = re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.([1-9]\d*))?', tag)
    if not match:
        raise ValueError('Expected vX.Y.Z or vX.Y.Z-beta.N')
    major, minor, patch = map(int, match.groups()[:3])
    beta = int(match[4]) if match[4] else None
    if minor > 999 or patch > 999 or (beta is not None and beta > 89999):
        raise ValueError('Version components exceed build-number limits')
    return {
        'tag': tag, 'version': f'{major}.{minor}.{patch}',
        'build': str((major * 1000000 + minor * 1000 + patch) * 100000 + (beta or 90000)),
        'prerelease': beta is not None,
        'channels': ['beta'] if beta else ['stable', 'beta'],
    }


def package(tag, channel, arch):
    meta = parse_tag(tag)
    if channel not in meta['channels'] or arch not in ('arm64', 'x64'):
        raise ValueError('Invalid channel or architecture for this tag')
    suffix = ' Beta' if channel == 'beta' else ''
    return dict(meta, channel=channel, arch=arch, name=NAME + suffix,
                bundle_id='com.apotenza.SimpleMacFixes' + ('.beta' if suffix else ''),
                asset=f'{PREFIX}{"-Beta" if suffix else ""}-{tag}-macos-{arch}.zip')


def native_matrix(tag):
    parse_tag(tag)
    return {'include': [dict(arch=arch, runner=runner) for arch, runner in
                        [('arm64', 'macos-15'), ('x64', 'macos-15-intel')]]}


if __name__ == '__main__':
    import argparse, json
    parser = argparse.ArgumentParser()
    parser.add_argument('tag')
    parser.add_argument('--matrix', action='store_true')
    parser.add_argument('--native-matrix', action='store_true')
    parser.add_argument('--channel', choices=['stable', 'beta'])
    parser.add_argument('--arch', choices=['arm64', 'x64'])
    args = parser.parse_args()
    if args.native_matrix:
        print(json.dumps(native_matrix(args.tag)))
    elif args.matrix:
        print(json.dumps({'include': [dict(package(args.tag, channel, arch), runner=runner)
            for channel in parse_tag(args.tag)['channels']
            for arch, runner in [('arm64', 'macos-15'), ('x64', 'macos-15-intel')]]}))
    else:
        print(json.dumps(package(args.tag, args.channel, args.arch) if args.channel else parse_tag(args.tag)))
