#!/usr/bin/env bash
#
# Fetches llama.cpp's licence files, at the build Package.swift pins, into a
# directory for make-notices.py:
#
#   tools/notices/fetch-llama-licenses.sh DIR
#
# Reads them from GitHub's raw file host. Nothing is built or run.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

dir="${1:?usage: fetch-llama-licenses.sh DIR}"
build="$(sed -nE 's#.*llama\.cpp/releases/download/(b[0-9]+)/.*#\1#p' Package.swift | head -1)"
[ -n "$build" ] || { echo "no llama.cpp build in Package.swift" >&2; exit 1; }
mkdir -p "$dir"
for file in LICENSE licenses/LICENSE-jsonhpp vendor/stb/stb_image.h vendor/miniaudio/miniaudio.h; do
	curl -fsSL "https://raw.githubusercontent.com/ggml-org/llama.cpp/$build/$file" -o "$dir/$(basename "$file")"
done
echo "llama.cpp $build licences in $dir"
