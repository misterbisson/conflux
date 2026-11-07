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
	*.p8 | *.p12 | *.pem | *.key | *.cer | *.mobileprovision | *.provisionprofile)
		fail "$file: keys, certificates and provisioning profiles never go in the repository" ;;
	exportoptions*.plist)
		fail "$file: export options carry the Team ID; Xcode Cloud doesn't need them" ;;
	*.xcodeproj/*)
		fail "$file: the Xcode project is generated from project.yml, and Xcode writes the signing team into it" ;;
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

# Signing values in any tracked text file. The Team ID comes from
# App/Signing.local.xcconfig, untracked, or from Xcode Cloud's CI_TEAM_ID.
# This file is skipped: its patterns would match themselves.
not_this=':(exclude)tools/ci/check-public.sh'
while IFS= read -r hit; do
	fail "$hit: a Team ID; it goes in App/Signing.local.xcconfig, which is never committed"
done < <(git grep -nIE "DEVELOPMENT_TEAM[[:space:]]*[:=][[:space:]]*[\"']?[A-Z0-9]{10}([^A-Za-z0-9]|$)" -- . "$not_this" | cut -d: -f1,2 || true)
while IFS= read -r hit; do
	fail "$hit: a provisioning profile setting; Xcode Cloud signs automatically, with none named in the repository"
done < <(git grep -nIE "PROVISIONING_PROFILE(_SPECIFIER)?[[:space:]]*[:=][[:space:]]*[\"']?[^\"'[:space:]]" -- . "$not_this" | cut -d: -f1,2 || true)
while IFS= read -r hit; do
	fail "$hit: a private key"
done < <(git grep -nIE -- "-----BEGIN ([A-Z]+ )*PRIVATE KEY-----" -- . "$not_this" | cut -d: -f1,2 || true)

# Xcode Cloud runs ci_scripts/ by name, and only when they're executable. Their
# output is a build log: nothing that prints the environment, and never the
# Team ID's value.
while IFS= read -r -d '' script; do
	[ -f "$script" ] || continue
	mode=$(git ls-files -s -- "$script" | cut -d' ' -f1)
	[ "$mode" = 100755 ] || fail "$script: Xcode Cloud runs only executable scripts (git update-index --chmod=+x)"
	if grep -nE '^[[:space:]]*(set[[:space:]]+-[a-z]*x|set[[:space:]]+-o[[:space:]]+xtrace|env[[:space:]]*($|[|>])|printenv|export[[:space:]]+-p)' "$script" >/dev/null; then
		fail "$script: prints the environment or traces commands, which puts values in the build log"
	fi
	if grep -nE '(echo|say|printf)[^#>]*\$\{?CI_TEAM_ID' "$script" >/dev/null; then
		fail "$script: prints CI_TEAM_ID"
	fi
done < <(git ls-files -z -- 'ci_scripts/*.sh')

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
	if grep -nE 'allowProvisioningUpdates|authenticationKey' "$workflow" >/dev/null; then
		fail "$workflow: signs with the team's account; Xcode Cloud signs releases, and GitHub signs nothing"
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
