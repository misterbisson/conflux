#!/usr/bin/env bash
#
# Checks a pull request's title and description. Pull requests are squash
# merged, so they become the commit's subject and body, and release-please reads
# that commit to choose the next version and write the changelog.
#
#   PR_TITLE='fix(gateway): retry after a host leaves' PR_BODY='...' \
#     tools/ci/check-commit-message.sh
#
# The title is a Conventional Commit, `type(scope): description`:
#
#   feat              a minor release while conflux is below 1.0
#   fix, perf         a patch release
#   type!             breaking; below 1.0 that's a minor release too
#   anything else     no release by itself: docs, test, ci, build, refactor,
#                     style, chore, revert
#
# The description mustn't say more than meant. release-please reads a line in
# the body that's shaped like a title as another change, and a BREAKING CHANGE
# line as a breaking one. `Release-As: x.y.z` sets the next version on purpose.

set -euo pipefail

title="${PR_TITLE-}"
body="${PR_BODY-}"
failures=0
fail() {
	echo "::error::$*"
	failures=$((failures + 1))
}
note() { echo "::notice::$*"; }

types='feat|fix|perf|revert|docs|style|chore|refactor|test|build|ci'
header="^($types)(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]]"

# --- the title ------------------------------------------------------------------
if [ -z "$title" ]; then
	fail "the title is empty"
elif ! printf '%s\n' "$title" | grep -Eq "$header"; then
	fail "the title isn't a conventional commit: '$title'. Use type(scope): description, where type is one of ${types//|/, } (CLAUDE.md, Pull requests)"
else
	[ "${#title}" -le 100 ] ||
		fail "the title is ${#title} characters; keep it within 100, since GitHub adds the pull request number"
	case "$title" in
	*.) fail "the title ends with a period, and it becomes a changelog entry" ;;
	esac
fi
breaking=no
if printf '%s\n' "$title" | grep -Eq "^($types)(\([^)]*\))?!:"; then
	breaking=yes
fi

# --- the description ------------------------------------------------------------
footer=no
n=0
while IFS= read -r line || [ -n "$line" ]; do
	n=$((n + 1))
	line="${line%$'\r'}"
	if printf '%s\n' "$line" | grep -Eq "$header"; then
		fail "description line $n reads as another commit to release-please: '$line'. Reword it, or indent it"
	fi
	case "$line" in
	"BREAKING CHANGE:"* | "BREAKING-CHANGE:"*) footer=yes ;;
	"Release-As:"*)
		if printf '%s\n' "$line" | grep -Eq '^Release-As: [0-9]+\.[0-9]+\.[0-9]+$'; then
			note "description line $n sets the next version: ${line#Release-As: }"
		else
			fail "description line $n isn't 'Release-As: x.y.z': '$line'"
		fi
		;;
	esac
done <<<"$body"

if [ "$footer" = yes ] && [ "$breaking" = no ]; then
	fail "the description has a BREAKING CHANGE line and the title has no '!'. Mark the title type! if it's breaking, or reword the line"
fi
if [ "$breaking" = yes ]; then
	note "this is a breaking change, which below 1.0 releases a minor version"
fi

if [ "$failures" -gt 0 ]; then
	echo "$failures problem(s) in the commit message"
	exit 1
fi
echo "commit message ok: $title"
