#!/usr/bin/env bash
#
# Checks tracked files for what a public repository must not contain. These
# are the rules in CLAUDE.md that a script can enforce. Run it before pushing:
#
#   tools/ci/check-public.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

failures=0
fail() {
	# The ::error:: prefix makes GitHub annotate the file. Locally it reads fine.
	echo "::error::$*"
	failures=$((failures + 1))
}

max_bytes=$((2 * 1024 * 1024))

while IFS= read -r -d '' file; do
	[ -f "$file" ] || continue # deleted in the working tree
	lower=$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')

	case "$lower" in
	*.gguf | *.safetensors | *.mlmodel | *.mlpackage/* | *.onnx | *.pt | *.pth | *.ckpt)
		fail "$file: model weights are fetched, never committed" ;;
	*.local.xcconfig)
		fail "$file: local signing settings stay untracked" ;;
	*.p12 | *.pem | *.key | *.cer | *.mobileprovision | *.provisionprofile)
		fail "$file: keys, certificates and provisioning profiles never go in the repository" ;;
	*.heic | *.heif | *.tif | *.tiff | *.dng | *.cr2 | *.cr3 | *.nef | *.arw)
		fail "$file: camera formats carry metadata; commit a generated, stripped JPEG or PNG" ;;
	esac

	size=$(wc -c <"$file" | tr -d ' ')
	if [ "$size" -gt "$max_bytes" ]; then
		fail "$file: $size bytes; files over 2 MB don't belong in this repository"
	fi

	case "$lower" in
	*.jpg | *.jpeg | *.png | *.webp)
		if LC_ALL=C grep -qE 'Exif|eXIf|x:xmpmeta' "$file"; then
			fail "$file: carries EXIF or XMP metadata; strip it before committing"
		fi ;;
	esac
done < <(git ls-files -z)

for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
	[ -f "$workflow" ] || continue

	grep -qE '^permissions:' "$workflow" ||
		fail "$workflow: needs a top-level permissions block (contents: read)"
	if grep -n 'pull_request_target' "$workflow" >/dev/null; then
		fail "$workflow: pull_request_target runs with write access on code from forks"
	fi
	if grep -n 'self-hosted' "$workflow" >/dev/null; then
		fail "$workflow: no self-hosted runners on a public repository"
	fi
	if grep -nE 'secrets\.' "$workflow" | grep -v 'secrets\.GITHUB_TOKEN' >/dev/null; then
		fail "$workflow: uses secrets; see CLAUDE.md before adding any, and update this check with it"
	fi

	while IFS= read -r line; do
		ref=$(printf '%s' "${line#*uses:}" | sed -E 's/#.*//; s/[[:space:]"'\'']//g')
		case "$ref" in ./* | docker://*) continue ;; esac
		if ! printf '%s' "$ref" | grep -qE '@[0-9a-f]{40}$'; then
			fail "$workflow: '$ref' must be pinned to a full commit SHA, with the version in a comment"
		fi
	done < <(grep -E '^[[:space:]]*(-[[:space:]]*)?uses:' "$workflow" || true)
done

if [ "$failures" -gt 0 ]; then
	echo "$failures problem(s) found"
	exit 1
fi
echo "public-repository checks passed"
