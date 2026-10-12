#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_REPO="${APP_REPO:-ordishs/localcode}"
TEMPLATE="$REPO_ROOT/packaging/localcode.rb.in"

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh <version> [--publish]

Without --publish the script checks the repo and prints the steps. It changes nothing.
With --publish it does all of this:
  1. set the version in bin/localcode and package.json, then commit
  2. run test/smoke.sh
  3. tag v<version>, push main and the tag
  4. create the GitHub release
  5. download the tag tarball, compute its sha256
  6. write Formula/localcode.rb in the tap, commit, push

Environment:
  TAP_DIR   clone of ordishs/homebrew-tap, default: brew --repository ordishs/tap
  APP_REPO  GitHub repo of localcode, default: ordishs/localcode
USAGE
}

die() {
  echo "release: $1" >&2
  exit 1
}

VERSION=""
PUBLISH=false
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=true ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown flag: $arg" ;;
    *)
      [[ -z "$VERSION" ]] || die "unexpected argument: $arg"
      VERSION="$arg"
      ;;
  esac
done

[[ -n "$VERSION" ]] || { usage >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, got: $VERSION"

TAG="v$VERSION"
TARBALL_URL="https://github.com/$APP_REPO/archive/refs/tags/$TAG.tar.gz"

command -v gh >/dev/null || die "gh is required. Run: brew install gh"
command -v jq >/dev/null || die "jq is required. Run: brew install jq"
[[ -f "$TEMPLATE" ]] || die "missing $TEMPLATE"

if [[ -z "${TAP_DIR:-}" ]]; then
  command -v brew >/dev/null || die "set TAP_DIR to a clone of ordishs/homebrew-tap"
  TAP_DIR="$(brew --repository ordishs/tap)"
fi
[[ -d "$TAP_DIR/.git" ]] || die "tap not found at $TAP_DIR. Run: git clone git@github.com:ordishs/homebrew-tap.git \"$TAP_DIR\""

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "release from the main branch"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || die "tap working tree is not clean: $TAP_DIR"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"

CURRENT="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' bin/localcode)"
[[ -n "$CURRENT" ]] || die "cannot read VERSION from bin/localcode"
[[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
  || die "version $VERSION is not newer than $CURRENT"

if [[ "$PUBLISH" == false ]]; then
  echo "dry run: nothing changed"
  echo "  set version $CURRENT -> $VERSION in bin/localcode and package.json"
  echo "  run test/smoke.sh"
  echo "  tag $TAG, push main and $TAG to origin"
  echo "  create release $TAG in $APP_REPO"
  echo "  render $TEMPLATE into $TAP_DIR/Formula/localcode.rb with the tarball sha256"
  echo "  commit and push the tap"
  echo "run again with --publish to do it"
  exit 0
fi

sed -i.bak "s/^VERSION=\".*\"$/VERSION=\"$VERSION\"/" bin/localcode
rm -f bin/localcode.bak
jq --arg v "$VERSION" '.version = $v' package.json >package.json.new
mv package.json.new package.json

./test/smoke.sh

git add bin/localcode package.json
git commit --no-verify -m "Release $TAG"
git tag "$TAG"
git push origin main "$TAG"

gh release create "$TAG" --repo "$APP_REPO" --title "$TAG" --notes "Release $TAG"

SHA=""
for _ in 1 2 3 4 5 6; do
  if SHA="$(curl -fsSL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')" && [[ ${#SHA} -eq 64 ]]; then
    break
  fi
  SHA=""
  sleep 5
done
[[ -n "$SHA" ]] || die "cannot download $TARBALL_URL"

mkdir -p "$TAP_DIR/Formula"
sed -e "s|@URL@|$TARBALL_URL|" -e "s|@SHA256@|$SHA|" "$TEMPLATE" >"$TAP_DIR/Formula/localcode.rb"

git -C "$TAP_DIR" add Formula/localcode.rb
git -C "$TAP_DIR" commit --no-verify -m "localcode $VERSION"
git -C "$TAP_DIR" push

echo "published $TAG, sha256 $SHA"
echo "install: brew install ordishs/tap/localcode"
