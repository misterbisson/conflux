#!/usr/bin/env bash
#
# Checks check-commit-message.sh against messages it should pass and fail.
#
#   tools/ci/test-check-commit-message.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

failures=0
expect() {
	local want="$1" title="$2" body="${3-}" got
	if PR_TITLE="$title" PR_BODY="$body" tools/ci/check-commit-message.sh >/dev/null 2>&1; then got=pass; else got=fail; fi
	if [ "$got" != "$want" ]; then
		echo "::error::expected $want, got $got: title '$title', body '$body'"
		failures=$((failures + 1))
	fi
}

nl=$'\n'

expect pass "feat: serve models over iroh"
expect pass "fix(gateway): retry after a host leaves"
expect pass "docs: correct the Xcode Cloud setup steps"
expect pass "chore(main): release 0.2.0"
expect pass "feat(api)!: drop the v0 endpoint" "BREAKING CHANGE: clients move to v1."
expect pass "ci: tag releases" "Some prose.${nl}${nl}Release-As: 0.1.0"
expect pass "fix: a thing" "- **fix:** a list item is prose${nl}  fix: an indented line is prose"
cr=$'\r'
expect pass "fix: a thing" "Windows line endings.${cr}${nl}Second line.${cr}"
expect fail "fix: a thing" "Windows line endings.${cr}${nl}feat: still a commit${cr}"

expect fail "Prepare the Mac app for Xcode Cloud"
expect fail "feature: not a type"
expect fail "Fix: types are lowercase"
expect fail "fix:missing space"
expect fail "fix(Gateway): scopes are lowercase"
expect fail "fix: ends with a period."
expect fail "fix: $(printf 'x%.0s' {1..100})"
expect fail ""
expect fail "docs: tidy" "This also does more.${nl}${nl}feat: an entry nobody meant"
expect fail "fix: a thing" "BREAKING CHANGE: without a ! in the title"
expect fail "ci: tag releases" "Release-As: soon"

if [ "$failures" -gt 0 ]; then
	echo "$failures case(s) wrong"
	exit 1
fi
echo "check-commit-message.sh passes its cases"
