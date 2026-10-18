import test from 'node:test';
import assert from 'node:assert/strict';
import {repository, prefix, selectRelease} from '../../docs/release-model.mjs';
function release(tag, arches = ['arm64', 'x64']) {
  return {tag_name:tag, prerelease:false, draft:false, assets:arches.map(arch => {
    const name = `${prefix}-${tag}-macos-${arch}.zip`;
    return {name, browser_download_url:`https://github.com/${repository}/releases/download/${tag}/${name}`};
  })};
}
test('picks the newest version, skipping drafts, prereleases and malformed tags', () => {
  const releases = [release('v0.0.2'), release('v0.0.10'), {...release('v9.0.0'), draft:true},
    {...release('v8.0.0'), prerelease:true}, release('nonsense')];
  assert.equal(selectRelease(releases, 'arm64').release.tag_name, 'v0.0.10');
});
test('a missing package never falls back to an older version', () => {
  const selected = selectRelease([release('v0.0.1'), release('v0.0.2', ['arm64'])], 'x64');
  assert.equal(selected.release.tag_name, 'v0.0.2');
  assert.equal(selected.asset, undefined);
});
test('only exact release URLs become download links', () => {
  const item = release('v0.0.1');
  item.assets[0].browser_download_url = 'https://example.com/fake.zip';
  assert.equal(selectRelease([item], 'arm64').asset, undefined);
});
test('nothing is offered without a release or for an unknown Mac', () => {
  assert.equal(selectRelease([], 'arm64'), null);
  assert.equal(selectRelease([release('v0.0.1')], 'ppc'), null);
});
