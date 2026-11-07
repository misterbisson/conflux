#!/usr/bin/env bash
#
# Selects the Xcode in .xcode-version for the rest of a GitHub Actions job.
#
# Xcode Cloud builds releases with its latest Xcode release, and isn't pinned.
# .xcode-version records which one that is, so GitHub's CI builds and tests
# with the same Xcode. docs/releasing.md says how it's kept current.
#
#   tools/ci/select-xcode.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

version="$(tr -d '[:space:]' <.xcode-version)"
app="/Applications/Xcode_${version}.app"

if [ ! -d "$app" ]; then
	have="$(find /Applications -maxdepth 1 -name 'Xcode_*.app' | sed 's|.*/Xcode_||; s|\.app$||' | sort -V | tr '\n' ' ')"
	echo "::error file=.xcode-version::Xcode $version isn't on this runner, which has: $have. tools/ci/xcode-runner.sh chooses the runner."
	exit 1
fi

developer="$app/Contents/Developer"
actual="$(DEVELOPER_DIR="$developer" xcodebuild -version | sed -n 's/^Xcode //p')"
if [ "$actual" != "$version" ]; then
	echo "::error file=.xcode-version::$app is Xcode $actual, not $version"
	exit 1
fi

if [ -n "${GITHUB_ENV:-}" ]; then
	echo "DEVELOPER_DIR=$developer" >>"$GITHUB_ENV"
fi
echo "Xcode $actual at $app"
