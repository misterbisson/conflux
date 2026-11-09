#!/usr/bin/env bash
#
# Fetches the starter model the app ships, into App/StarterModel, where the
# Mac and iPad targets copy it into the app. ci_scripts/ci_post_clone.sh runs
# it, on Xcode Cloud and on a desk:
#
#   tools/ci/fetch-starter-model.sh
#
# The starter model is there so a first request works before anyone has
# chosen a model. Weights are fetched, never committed: App/StarterModel is
# ignored, and tools/ci/check-public.sh refuses weights in the repository.
#
# SmolVLM-256M-Instruct, by Hugging Face, Apache 2.0
# (huggingface.co/HuggingFaceTB/SmolVLM-256M-Instruct), as GGUF from
# ggml-org/SmolVLM-256M-Instruct-GGUF: the Q8_0 model and its Q8_0 vision
# projector, about 280 MB together. Pinned by repository revision and
# checksum. tools/ci/check-app.sh and tools/ci/build-ipad.sh check the apps
# hold these files, and App/Credits.html its licence.
#
# Moving the pin: change the revision and both checksums together, run the
# self-check against the new files, and name the new files in
# Sources/ConfluxCore/StarterModel.swift if they're renamed.

set -euo pipefail

repository=ggml-org/SmolVLM-256M-Instruct-GGUF
revision=b9e4379657e1450d04d02eec8e345667265b0a00
files=(
	"SmolVLM-256M-Instruct-Q8_0.gguf 2a31195d3769c0b0fd0a4906201666108834848db768af11de1d2cef7cd35e65"
	"mmproj-SmolVLM-256M-Instruct-Q8_0.gguf 7e943f7c53f0382a6fc41b6ee0c2def63ba4fded9ab8ed039cc9e2ab905e0edd"
)

dir="$(cd "$(dirname "$0")/../.." && pwd)/App/StarterModel"
mkdir -p "$dir"

for entry in "${files[@]}"; do
	read -r name sha256 <<<"$entry"
	path="$dir/$name"
	if [ -f "$path" ] && echo "$sha256  $path" | shasum -a 256 -c --status; then
		continue
	fi
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$path.part" \
		"https://huggingface.co/$repository/resolve/$revision/$name"
	if ! echo "$sha256  $path.part" | shasum -a 256 -c --status; then
		rm -f "$path.part"
		echo "fetch-starter-model: checksum mismatch for $name" >&2
		exit 1
	fi
	mv "$path.part" "$path"
done
# Nothing else goes into the app: a stale or partial file from an earlier pin
# would ship too.
for path in "$dir"/*; do
	name="$(basename "$path")"
	keep=no
	for entry in "${files[@]}"; do
		[ "${entry%% *}" = "$name" ] && keep=yes
	done
	[ "$keep" = yes ] || rm -rf "$path"
done
echo "fetch-starter-model: $repository at ${revision:0:12} in App/StarterModel"
