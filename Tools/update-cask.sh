#!/bin/bash
# Points the Homebrew cask (qhr992/homebrew-tap, Casks/omnihub.rb) at an
# OmniHub release, then commits and pushes the tap:
#   Tools/update-cask.sh [version] [--if-released] [--dry-run]
#
# version        default: the version of build/OmniHub.app
# --if-released  a release that is not on GitHub yet is not an error: the
#                cask is left alone (Tools/package.sh runs it this way)
# --dry-run      show the change to the cask, commit and push nothing
#
# The cask only ever points at a dmg that is on GitHub: the release's dmg
# is downloaded and hashed, and when dist/ holds the same version it must
# be that very file. The tap is found at ../homebrew-tap next to this
# project, or wherever OMNIHUB_TAP says.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="qhr992/OmniHub"
TAP="${OMNIHUB_TAP:-$(cd .. && pwd)/homebrew-tap}"
CASK="Casks/omnihub.rb"

version="" if_released=0 dry_run=0
for arg in "$@"; do
  case "$arg" in
    --if-released) if_released=1 ;;
    --dry-run) dry_run=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) version="${arg#v}" ;;
  esac
done
if [[ -z "$version" ]]; then
  version="$(defaults read "$PWD/build/OmniHub.app/Contents/Info.plist" CFBundleShortVersionString)"
fi
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "not a version: '$version'" >&2; exit 2; }

say() { echo "cask: $*"; }

# Leaves the cask alone, as an error unless --if-released.
skip() {
  say "$1"
  if (( if_released )); then exit 0; else exit 1; fi
}

[[ -f "$TAP/$CASK" ]] || skip "no tap at $TAP (set OMNIHUB_TAP); cask not updated"

# The release's dmg, downloaded (no API: its anonymous quota runs out), and its SHA-256.
dmg="OmniHub-$version.dmg"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
code="$(curl -sSL -o "$tmp/$dmg" -w '%{http_code}' "https://github.com/$REPO/releases/download/v$version/$dmg" || true)"
case "$code" in
  200) ;;
  404) skip "v$version has no $dmg on GitHub yet; cask not updated. Run Tools/update-cask.sh $version once it is released." ;;
  *) skip "could not download $dmg from GitHub (HTTP ${code:-none}); cask not updated" ;;
esac
remote_sha="$(shasum -a 256 "$tmp/$dmg" | cut -d' ' -f1)"

# A local build of the same version must be the file that was released.
if [[ -f "dist/$dmg" ]]; then
  local_sha="$(shasum -a 256 "dist/$dmg" | cut -d' ' -f1)"
  if [[ "$local_sha" != "$remote_sha" ]]; then
    echo "cask: dist/$dmg ($local_sha) is not the dmg released as v$version ($remote_sha); cask not updated" >&2
    exit 1
  fi
fi

cd "$TAP"
if (( ! dry_run )); then
  [[ "$(git branch --show-current)" == "main" ]] || { echo "cask: $TAP is not on main" >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "cask: $TAP has uncommitted changes" >&2; exit 1; }
  git pull -q --ff-only
fi
sed -i '' -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$remote_sha\"/" "$CASK"
if git diff --quiet -- "$CASK"; then
  say "already omnihub $version ($remote_sha)"
  exit 0
fi
if (( dry_run )); then
  git --no-pager diff -- "$CASK"
  git checkout -q -- "$CASK"
  say "dry run: would set omnihub $version ($remote_sha)"
  exit 0
fi
git commit -q -m "omnihub $version" -- "$CASK"
git push -q
say "omnihub $version ($remote_sha) pushed to $(git remote get-url origin)"
