#!/bin/sh
#
# Generates conflux.xcodeproj from project.yml.
#
# Xcode Cloud runs a script at exactly this path after it clones the
# repository, before it resolves packages or builds. The generated project
# isn't committed, so without this there is nothing to build. GitHub's CI runs
# it too, and so can anyone checking that a fresh clone builds:
#
#   ci_scripts/ci_post_clone.sh
#
# The repository is public and so is this script's output on GitHub. It prints
# no environment and no signing values. docs/releasing.md has the rules.
#
# It doesn't run the tests. GitHub runs them on every pull request, and this
# hook runs before Xcode Cloud sets up signing, so a test run here that builds
# the signed app would fail on the certificate, not on any test.

set -eu

say() { echo "post-clone: $*"; }
fail() {
	say "FAILED: $*"
	exit 1
}

# XcodeGen, by version and checksum: a tag can be moved, a checksum can't.
# Change both together, and keep the version the same as the one used to
# generate the project on a desk (brew upgrade xcodegen).
XCODEGEN_VERSION="2.45.4"
XCODEGEN_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

on_xcode_cloud() { [ "${CI_XCODE_CLOUD:-}" = "TRUE" ]; }

# --- Xcode Cloud builds releases, not pull requests ---------------------------
# Anyone can open a pull request on a public repository, and a pull request
# build would run its own copy of this script with the team's signing set up.
# Xcode Cloud workflows here start on tags. This refuses a pull request build
# in case one is ever configured: it can't stop a hostile pull request, which
# can edit this file, but it makes the mistake fail loudly.
if on_xcode_cloud; then
	case "${CI_START_CONDITION:-}" in
	pr_*) fail "this workflow started from a pull request; conflux builds only tags on Xcode Cloud (docs/releasing.md)" ;;
	esac
	[ -z "${CI_PULL_REQUEST_NUMBER:-}" ] ||
		fail "this workflow started from a pull request; conflux builds only tags on Xcode Cloud (docs/releasing.md)"
fi

# --- the tag is the version ---------------------------------------------------
# release-please tags vX.Y.Z and sets MARKETING_VERSION in the same release. A
# tag that disagrees was made some other way, and would ship a build numbered
# differently from its tag.
if on_xcode_cloud && [ -n "${CI_TAG:-}" ]; then
	version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9][0-9.]*)"?.*/\1/p' project.yml | sed -n 1p)"
	[ "$CI_TAG" = "v$version" ] ||
		fail "the tag is $CI_TAG and project.yml's MARKETING_VERSION is $version; release with release-please (docs/releasing.md)"
	say "releasing $CI_TAG"
fi

# --- which Xcode --------------------------------------------------------------
# Xcode Cloud uses its latest release, and GitHub's CI uses the version in
# .xcode-version. When they differ, GitHub isn't testing what ships: this says
# so, and the build goes on.
tracked="$(tr -d '[:space:]' <.xcode-version)"
running="$(xcodebuild -version | sed -n 's/^Xcode //p')"
say "Xcode $running; .xcode-version says $tracked"
if [ "$running" != "$tracked" ]; then
	say "warning: this is Xcode $running and GitHub's CI uses $tracked. Update .xcode-version to $running once GitHub's runners have it (docs/releasing.md)."
fi

# --- signing ------------------------------------------------------------------
# The Team ID never goes in the repository. On Xcode Cloud it comes from the
# build, into the untracked file App/Signing.xcconfig includes. It isn't
# printed. Elsewhere, App/Signing.local.xcconfig is left as it is.
if on_xcode_cloud; then
	team="${CI_TEAM_ID:-}"
	if [ -z "$team" ]; then
		say "warning: CI_TEAM_ID is empty, so the project has no signing team"
	elif printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$'; then
		printf 'DEVELOPMENT_TEAM = %s\n' "$team" >App/Signing.local.xcconfig
		say "wrote App/Signing.local.xcconfig from CI_TEAM_ID"
	else
		fail "CI_TEAM_ID isn't ten letters and digits; not writing it"
	fi
fi

# --- XcodeGen -----------------------------------------------------------------
tools="$(mktemp -d)"
trap 'rm -rf "$tools"' EXIT
url="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
say "fetching XcodeGen $XCODEGEN_VERSION"
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$tools/xcodegen.zip" "$url"
got="$(shasum -a 256 "$tools/xcodegen.zip" | awk '{ print $1 }')"
[ "$got" = "$XCODEGEN_SHA256" ] ||
	fail "XcodeGen checksum mismatch: expected $XCODEGEN_SHA256, got $got, from $url"
unzip -q "$tools/xcodegen.zip" -d "$tools"

say "generating conflux.xcodeproj"
"$tools/xcodegen/bin/xcodegen" generate --spec project.yml --quiet

# --- check what the build needs, by name --------------------------------------
# XcodeGen can succeed and still write a project the build can't use. Read the
# Schemes section only: the Targets section lists `conflux` too, so matching
# anywhere would pass without a scheme.
[ -d conflux.xcodeproj ] || fail "conflux.xcodeproj wasn't created"
xcodebuild -project conflux.xcodeproj -list 2>/dev/null |
	awk '/^[[:space:]]*Schemes:/ { s = 1; next } s && NF { print $1 }' |
	grep -qx conflux ||
	fail "the conflux scheme is missing"
[ -f conflux.xcodeproj/xcshareddata/xcschemes/conflux.xcscheme ] ||
	fail "the conflux scheme isn't shared, so Xcode Cloud can't see it"

say "done"
