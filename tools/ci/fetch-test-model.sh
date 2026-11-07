#!/usr/bin/env bash
# Fetches the tiny model the in-process runtime's tests load, and prints its
# path. Weights are fetched, never committed.
#
# stories15M (Q4_0, 19 MB) from llama.cpp's own test models
# (huggingface.co/ggml-org/models), converted from karpathy/tinyllamas,
# which is MIT licensed. Pinned by repository revision and checksum.
set -euo pipefail

revision=499bc8821c6b12b4e53c5bffcb21ec206f212d81
file=tinyllamas/stories15M-q4_0.gguf
sha256=66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739

dir="$(cd "$(dirname "$0")/../.." && pwd)/.build/test-models"
path="$dir/$(basename "$file")"
mkdir -p "$dir"

if [ ! -f "$path" ] || ! echo "$sha256  $path" | shasum -a 256 -c --status; then
  curl -fsSL --retry 3 -o "$path.part" "https://huggingface.co/ggml-org/models/resolve/$revision/$file"
  echo "$sha256  $path.part" | shasum -a 256 -c --status || { echo "checksum mismatch for $file" >&2; exit 1; }
  mv "$path.part" "$path"
fi
echo "$path"
