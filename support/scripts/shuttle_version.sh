#!/usr/bin/env bash
# Shuttle's version number, computed from git (used by auto-update):
#   version = date of the latest commit (in the committer's time zone), e.g. 2026.11.16
#             (no zero padding: pubspec / semver reject 2026.01.05)
#   build   = number of commits on HEAD + 100, which only ever grows. The app and Android both use it to compare
#             versions (Android's versionCode must never decrease). The +100 keeps builds above those released
#             before the source was published (up to 2289), when Shuttle's own history was squashed into one
#             commit on top of LocalSend's.
# Passed to Flutter at build time: flutter build … --build-name=$version --build-number=$build
# (the 1.18.2+64 in pubspec stays unchanged).
#
# Usage:
#   bash support/scripts/shuttle_version.sh                 # prints two lines, version=… and build=…
#   bash support/scripts/shuttle_version.sh >> "$GITHUB_OUTPUT"
#   eval "$(bash support/scripts/shuttle_version.sh)"       # sets $version and $build
# In CI the checkout needs fetch-depth: 0; otherwise the commit count would be wrong, so this script fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "shuttle_version.sh: shallow clone, so the commit count is wrong; in CI, set fetch-depth: 0 on checkout" >&2
  exit 1
fi

build=$(( $(git rev-list --count HEAD) + 100 ))
read -r y m d < <(git log -1 --format=%cd --date=format:'%Y %m %d')
echo "version=$((10#$y)).$((10#$m)).$((10#$d))"
echo "build=$build"
