#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_dir}/scripts/xcode-env.sh"
swift test --package-path "${repo_dir}"
"${repo_dir}/scripts/build-app.sh"
codesign --verify --deep --strict "${repo_dir}/build/Simple Mac Fixes Dev.app"
plutil -lint "${repo_dir}/build/Simple Mac Fixes Dev.app/Contents/Info.plist"
