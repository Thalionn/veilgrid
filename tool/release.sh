#!/usr/bin/env bash
# Build a signed release APK and publish it to GitHub Releases, which is how
# Grid updates are distributed (no Play Store).
#
#   tool/release.sh            # build + stage assets, print the publish command
#   tool/release.sh --publish  # build + publish to GitHub Releases
#
# Version comes from pubspec.yaml (`version: X.Y.Z+N`). Bump it before
# releasing; buildNumber N must increase or clients won't see the update.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

VERSION=$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+).*/\1/p' pubspec.yaml | head -1)
BUILD=$(sed -nE 's/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+).*/\1/p' pubspec.yaml | head -1)
if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  echo "error: pubspec.yaml version must look like 'X.Y.Z+N'" >&2
  exit 1
fi

if ! grep -q '^storeFile=' android/local.properties 2>/dev/null; then
  echo "error: no release signing configured in android/local.properties." >&2
  echo "       Run the release-key setup (storeFile/keyAlias/passwords) first." >&2
  exit 1
fi

ORIGIN=$(git remote get-url origin)
REPO=$(printf '%s' "$ORIGIN" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')
if [ -z "$REPO" ] || [ "$REPO" = "$ORIGIN" ]; then
  echo "error: could not parse the GitHub repo from origin ($ORIGIN)" >&2
  exit 1
fi

TAG="v$VERSION"
DIST="build/dist"
APK="$DIST/grid-$VERSION.apk"

echo "==> Building Grid $VERSION ($BUILD) for $REPO"
flutter build apk --release

mkdir -p "$DIST"
cp build/app/outputs/flutter-apk/app-release.apk "$APK"

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$PREV_TAG" ]; then
  git log --pretty=format:'- %s' "$PREV_TAG..HEAD" > "$DIST/notes.md"
else
  git log --pretty=format:'- %s' -n 15 > "$DIST/notes.md"
fi
if [ ! -s "$DIST/notes.md" ]; then
  printf 'Initial release.' > "$DIST/notes.md"
fi

python3 - "$VERSION" "$BUILD" "$REPO" "$TAG" "$DIST" <<'PY'
import json, sys
version, build, repo, tag, dist = sys.argv[1:6]
notes = open(f'{dist}/notes.md').read().strip()
data = {
    "version": version,
    "buildNumber": int(build),
    "apk": f"https://github.com/{repo}/releases/download/{tag}/grid-{version}.apk",
    "page": f"https://github.com/{repo}/releases/tag/{tag}",
    "notes": notes,
}
with open(f'{dist}/latest.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY

echo
echo "==> Staged:"
ls -lh "$APK" "$DIST/latest.json" | sed 's/^/    /'
echo
echo "==> Release notes:"
sed 's/^/    /' "$DIST/notes.md"
echo
echo "==> latest.json:"
sed 's/^/    /' "$DIST/latest.json"
echo

if [ "$PUBLISH" != "1" ]; then
  echo "Not published. Publish with:"
  echo "    tool/release.sh --publish"
  echo "or manually:"
  echo "    gh release create $TAG \"$APK\" \"$DIST/latest.json\" --title \"Grid $VERSION\" --notes-file \"$DIST/notes.md\""
  exit 0
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: release $TAG already exists (bump the version)." >&2
  exit 1
fi

echo "==> Publishing $TAG to $REPO"
gh release create "$TAG" "$APK" "$DIST/latest.json" \
  --title "Grid $VERSION" \
  --notes-file "$DIST/notes.md"

echo
echo "Published. Existing installs will see it on their next update check."
