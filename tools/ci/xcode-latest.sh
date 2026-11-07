#!/usr/bin/env bash
#
# Compares .xcode-version with Apple's latest Xcode release, which Xcode Cloud
# switches to, and says which of GitHub's runner images have it.
#
#   tools/ci/xcode-latest.sh
#
# Prints a Markdown report. In GitHub Actions it also sets the step outputs
# `latest` and `behind` (true when .xcode-version is older than the latest
# release). It reads only public pages and needs no token.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

feed=https://developer.apple.com/news/releases/rss/releases.rss
toolsets=https://api.github.com/repos/actions/runner-images/contents/images/macos/toolsets
raw=https://raw.githubusercontent.com/actions/runner-images/main/images/macos/toolsets

# Release titles look like "Xcode 27.2 (27B52)". Betas and release candidates
# have a word before the build number, so they don't match.
latest="$(curl -fsSL --retry 3 "$feed" |
	grep -oE '<title>Xcode [0-9]+(\.[0-9]+)* \([0-9A-Za-z]+\)</title>' |
	sed -n 1p | sed -E 's/<title>Xcode ([0-9.]+) .*/\1/')"
if [ -z "$latest" ]; then
	echo "::error::found no Xcode release in $feed"
	exit 1
fi
# Apple writes "Xcode 27"; xcodebuild and the runners say 27.0.
case "$latest" in *.*) ;; *) latest="$latest.0" ;; esac

tracked="$(tr -d '[:space:]' <.xcode-version)"
newest="$(printf '%s\n%s\n' "$tracked" "$latest" | sort -V | tail -n 1)"
behind=false
[ "$latest" != "$tracked" ] && [ "$newest" = "$latest" ] && behind=true

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "latest=$latest"
		echo "behind=$behind"
	} >>"$GITHUB_OUTPUT"
fi

echo "Apple's latest Xcode release is **$latest**, and \`.xcode-version\` says **$tracked**."
echo
if [ "$behind" = false ]; then
	echo "GitHub's CI builds with the Xcode that Xcode Cloud uses."
	exit 0
fi

# Runner images that list the release. These are the image definitions on
# runner-images' main branch, which roll out over a few days.
on=""
for file in $(curl -fsSL --retry 3 "$toolsets" | jq -r '.[].name | select(endswith(".json"))'); do
	if curl -fsSL --retry 3 "$raw/$file" |
		jq -e --arg v "$latest" '[.xcode.arm64.versions[]? | .link, (.symlinks[]?), (.version | split("+")[0])] | index($v)' >/dev/null; then
		label="${file#toolset-}"
		label="${label%.json}"
		case "$label" in xcode-*) ;; *) label="macos-$label" ;; esac
		on="$on \`$label\`"
	fi
done

echo "Xcode Cloud builds releases with $latest once it switches, so GitHub's CI should too:"
echo
echo "1. Set \`.xcode-version\` to \`$latest\`."
echo "2. Check that \`tools/ci/xcode-runner.sh\` names a runner image that has it."
echo "3. Fix whatever the new Xcode finds in the pull request's CI."
echo
if [ -n "$on" ]; then
	echo "Runner images that list Xcode $latest:$on."
else
	echo "No GitHub runner image lists Xcode $latest yet. Until one does, GitHub's CI is a version behind Xcode Cloud."
fi
