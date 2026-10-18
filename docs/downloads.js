import {repository, selectRelease} from './release-model.mjs';
const params = new URLSearchParams(location.search);
// Browsers report "Intel" on every Mac, so Apple silicon is the default and Intel is chosen explicitly.
let arch = params.get('arch') === 'x64' ? 'x64' : 'arm64';
let releases = [], state = 'loading';
const appearance = matchMedia('(prefers-color-scheme: dark)');
appearance.addEventListener('change', () => render());
const byId = id => document.getElementById(id);
function render() {
  document.querySelectorAll('[data-arch]').forEach(button => button.setAttribute('aria-pressed', button.dataset.arch === arch));
  byId('app-icon').src = `assets/icon-stable-${appearance.matches ? 'dark' : 'light'}.svg`;
  const selected = selectRelease(releases, arch);
  const link = byId('download-link'), notes = byId('release-notes');
  link.href = `https://github.com/${repository}/releases`;
  link.textContent = 'Browse releases ↗';
  notes.hidden = true;
  if (state === 'loading') byId('release-status').textContent = 'Checking for the latest version…';
  else if (state === 'error') byId('release-status').textContent = 'Couldn’t check for the latest version. You can download it from GitHub.';
  else if (!selected) byId('release-status').textContent = 'No version has been released yet.';
  else if (!selected.asset) byId('release-status').textContent = `${selected.release.tag_name} isn’t available for this Mac yet.`;
  else {
    byId('release-status').textContent = `${selected.release.tag_name} · macOS 14.4 or later`;
    link.href = selected.asset.browser_download_url;
    link.textContent = `Download for ${arch === 'arm64' ? 'Apple silicon' : 'Intel'} ↓`;
    notes.href = `https://github.com/${repository}/releases/tag/${selected.release.tag_name}`;
    notes.hidden = false;
  }
}
document.querySelectorAll('[data-arch]').forEach(button => button.addEventListener('click', () => {
  arch = button.dataset.arch;
  const url = new URL(location.href);
  url.searchParams.set('arch', arch);
  history.replaceState(null, '', url);
  render();
}));
byId('copy-brew').addEventListener('click', async event => {
  await navigator.clipboard.writeText(byId('brew-command').textContent);
  event.currentTarget.textContent = 'Copied';
  setTimeout(() => { byId('copy-brew').textContent = 'Copy'; }, 1500);
});
render();
try {
  for (let page = 1; ; page++) {
    const response = await fetch(`https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}`, {headers:{Accept:'application/vnd.github+json'}, signal:AbortSignal.timeout(10000)});
    if (!response.ok) throw new Error('Release lookup failed');
    const batch = await response.json();
    if (!Array.isArray(batch)) throw new Error('Invalid release response');
    releases.push(...batch);
    if (batch.length < 100) break;
  }
  state = 'ready';
} catch { state = 'error'; releases = []; }
render();
