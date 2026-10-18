export const repository = 'apotenza92/simple-mac-fixes';
export const prefix = 'Simple-Mac-Fixes';
export function version(tag) {
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(tag || '');
  return match ? match.slice(1, 4).map(Number) : null;
}
export function compare(a, b) {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
}
export function selectRelease(releases, arch) {
  if (!['arm64', 'x64'].includes(arch)) return null;
  const candidates = releases.filter(release => version(release.tag_name) && !release.draft && !release.prerelease)
    .sort((a, b) => compare(version(b.tag_name), version(a.tag_name)));
  // Never silently serve an older package when the newest lacks one.
  const release = candidates[0];
  if (!release) return null;
  const name = `${prefix}-${release.tag_name}-macos-${arch}.zip`;
  const expectedURL = `https://github.com/${repository}/releases/download/${release.tag_name}/${name}`;
  const asset = (release.assets || []).find(asset => asset.name === name && asset.browser_download_url === expectedURL);
  return { release, asset };
}
