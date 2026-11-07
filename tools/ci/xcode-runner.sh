#!/usr/bin/env bash
#
# Prints the GitHub Actions runner label for the Xcode in .xcode-version, as a
# step output:
#
#   tools/ci/xcode-runner.sh >>"$GITHUB_OUTPUT"
#
# GitHub ships each major Xcode on an `xcode-<major>` image before it reaches a
# `macos-<version>` one. If that changes, change it here; select-xcode.sh fails
# with the versions a runner has when the label is wrong.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

version="$(tr -d '[:space:]' <.xcode-version)"
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
	echo "::error file=.xcode-version::'$version' isn't a version like 27.2" >&2
	exit 1
fi
echo "runner=xcode-${version%%.*}"
