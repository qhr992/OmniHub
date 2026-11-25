#!/bin/bash
# Points the Homebrew cask (qhr992/homebrew-tap, Casks/omnihub.rb) at an
# OmniHub release. The tap's main only takes pull requests, so the change
# goes on a branch (cask/omnihub-<version>), a pull request is opened and
# squash-merged, and the branch is deleted:
#   Tools/update-cask.sh [version] [--if-released] [--wait] [--dry-run]
#
# version        default: the version of build/OmniHub.app
# --if-released  a release that is not on GitHub yet is not an error: the
#                cask is left alone (Tools/package.sh runs it this way)
# --wait         keep trying for up to 10 minutes while the dmg is not there:
#                a file just uploaded can take a while to be served everywhere
#                (the release step runs it this way)
# --dry-run      show the change to the cask, commit and push nothing
#
# The cask only ever points at a dmg that is on GitHub: the release's dmg
# is downloaded and hashed, and when dist/ holds the same version it must
# be that very file. The tap is found at ../homebrew-tap next to this
# project, or wherever OMNIHUB_TAP says. The GitHub token (for the pull
# request) comes from OMNIHUB_GITHUB_TOKEN, else tmp/.token; it is never
# printed or put on a command line.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="qhr992/OmniHub"
TAP_REPO="qhr992/homebrew-tap"
TAP="${OMNIHUB_TAP:-$(cd .. && pwd)/homebrew-tap}"
TOKEN_FILE="$PWD/tmp/.token"
CASK="Casks/omnihub.rb"

version="" if_released=0 dry_run=0 wait=0
for arg in "$@"; do
  case "$arg" in
    --if-released) if_released=1 ;;
    --dry-run) dry_run=1 ;;
    --wait) wait=1 ;;
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
fetch() { curl -sSL -o "$tmp/$dmg" -w '%{http_code}' "https://github.com/$REPO/releases/download/v$version/$dmg" || true; }
code="$(fetch)"
if (( wait )); then
  deadline=$(( $(date +%s) + 600 ))
  while [[ "$code" != 200 ]] && (( $(date +%s) < deadline )); do
    say "$dmg not served yet (HTTP ${code:-none}); trying again in 15 s"
    sleep 15
    code="$(fetch)"
  done
fi
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

# The token as an Authorization header in a private file (curl -H @file).
auth="$tmp/auth"
if (( ! dry_run )); then
  ( umask 077
    if [[ -n "${OMNIHUB_GITHUB_TOKEN:-}" ]]; then printf 'Authorization: Bearer %s\n' "$OMNIHUB_GITHUB_TOKEN"
    elif [[ -s "$TOKEN_FILE" ]]; then printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$TOKEN_FILE")"
    fi > "$auth" )
  [[ -s "$auth" ]] || { echo "cask: no GitHub token (OMNIHUB_GITHUB_TOKEN or tmp/.token); cask not updated" >&2; exit 1; }
fi

# api METHOD PATH [JSON]: the response body in $tmp/response, the status echoed.
api() {
  local args=(-sS -o "$tmp/response" -w '%{http_code}' -X "$1" -H @"$auth"
              -H "Accept: application/vnd.github+json")
  if (( $# > 2 )); then args+=(-H "Content-Type: application/json" --data "$3"); fi
  curl "${args[@]}" "https://api.github.com/repos/$TAP_REPO$2" || true
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$tmp/response" "$1"; }

cd "$TAP"
if (( ! dry_run )); then
  [[ "$(git branch --show-current)" == "main" ]] || { echo "cask: $TAP is not on main" >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "cask: $TAP has uncommitted changes" >&2; exit 1; }
  git pull -q --ff-only
  [[ -z "$(git rev-list origin/main..main)" ]] \
    || { echo "cask: $TAP's main has commits that are not on GitHub; cask not updated" >&2; exit 1; }
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
branch="cask/omnihub-$version"
# A branch left by an earlier run is reused when it holds this very cask.
if git fetch -q origin "refs/heads/$branch" 2>/dev/null; then
  if ! git show "FETCH_HEAD:$CASK" | cmp -s - "$CASK"; then
    git checkout -q -- "$CASK"
    echo "cask: $branch on GitHub holds a different cask; cask not updated" >&2
    exit 1
  fi
  git checkout -q -- "$CASK"
  say "reusing $branch"
else
  git checkout -q -b "$branch"
  git commit -q -m "omnihub $version" -- "$CASK"
  git push -q origin "$branch" 2> "$tmp/push" || { cat "$tmp/push" >&2; exit 1; }
  git checkout -q main
  git branch -q -D "$branch"
fi

# Its pull request: the open one, else a new one.
code="$(api GET "/pulls?state=open&head=${TAP_REPO%%/*}:$branch")"
[[ "$code" == 200 ]] || { echo "cask: could not look up pull requests (HTTP $code)" >&2; exit 1; }
number="$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p[0]["number"] if p else "")' "$tmp/response")"
if [[ -z "$number" ]]; then
  body="OmniHub $version: https://github.com/$REPO/releases/tag/v$version (SHA-256 $remote_sha)"
  code="$(api POST /pulls "{\"title\": \"omnihub $version\", \"head\": \"$branch\", \"base\": \"main\", \"body\": \"$body\"}")"
  [[ "$code" == 201 ]] || { echo "cask: could not open a pull request for $branch (HTTP $code: $(field message))" >&2; exit 1; }
  number="$(field number)"
fi
url="https://github.com/$TAP_REPO/pull/$number"
code="$(api PUT "/pulls/$number/merge" "{\"merge_method\": \"squash\", \"commit_title\": \"omnihub $version (#$number)\"}")"
[[ "$code" == 200 ]] || { echo "cask: $url is open but could not be merged (HTTP $code: $(field message))" >&2; exit 1; }
api DELETE "/git/refs/heads/$branch" >/dev/null
git pull -q --ff-only
say "omnihub $version ($remote_sha) merged into $TAP_REPO main: $url"
