#!/usr/bin/env bash
#
# Writes apple-iroh's dependency metadata, for make-notices.py, at the tag
# Package.swift pins, once per macOS target:
#
#   tools/notices/iroh-metadata.sh DIR
#
# leaves DIR/aarch64-apple-darwin.json and DIR/x86_64-apple-darwin.json. Needs
# cargo. `cargo metadata` downloads the crates to read their manifests and
# licence files, and compiles and runs nothing.
#
# apple-iroh patches two crates, netdev and netwatch, to name tvOS, from files
# its patch-crates.sh puts in place. The patches change no licence, so this
# drops the [patch.crates-io] table and reads the crates as published.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

dir="${1:?usage: iroh-metadata.sh DIR}"
tag="$(sed -nE 's#.*apple-iroh/releases/download/(v[0-9.]+)/.*#\1#p' Package.swift | head -1)"
[ -n "$tag" ] || { echo "no apple-iroh release in Package.swift" >&2; exit 1; }
command -v cargo >/dev/null || { echo "needs cargo (https://rustup.rs)" >&2; exit 1; }

mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 --branch "$tag" https://github.com/misterbisson/apple-iroh.git "$work/apple-iroh"
cd "$work/apple-iroh"
sed -i '' '/^\[patch\.crates-io\]/,/^netwatch = /d' Cargo.toml
for target in aarch64-apple-darwin x86_64-apple-darwin; do
	cargo metadata --format-version 1 --filter-platform "$target" >"$dir/$target.json"
done
echo "apple-iroh $tag metadata in $dir"
