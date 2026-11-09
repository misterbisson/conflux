#!/usr/bin/env bash
#
# Lints the GitHub workflows with a pinned actionlint, verified against the
# checksum its release publishes. On machines without a pinned binary, uses an
# installed actionlint if there is one.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

version=1.7.12
sha256_linux_amd64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
	if command -v actionlint >/dev/null; then exec actionlint; fi
	echo "no pinned actionlint for this platform; install actionlint to lint locally" >&2
	exit 0
fi

asset="actionlint_${version}_linux_amd64.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/$asset" "https://github.com/rhysd/actionlint/releases/download/v${version}/${asset}"
echo "$sha256_linux_amd64  $work/$asset" | sha256sum -c --quiet -
tar -xzf "$work/$asset" -C "$work" actionlint
"$work/actionlint" -color
