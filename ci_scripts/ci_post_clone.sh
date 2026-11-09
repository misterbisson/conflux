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
# build, into the untracked file App/Signing.xcconfig includes. Elsewhere,
# App/Signing.local.xcconfig is left as it is.
#
# Apple documents CI_TEAM_ID as the ten-character Team ID, but the first build
# (v0.1.0) had something else in it. Anything that isn't a Team ID isn't
# written: the archive then signs with whatever team Xcode Cloud's own signing
# settings give it. The value is never printed, only its shape, so the log can
# say what it was without saying what it is.
shape() {
	printf '%s characters' "${#1}"
	case "$1" in *[A-Z]*) printf ', capitals' ;; esac
	case "$1" in *[a-z]*) printf ', lowercase' ;; esac
	case "$1" in *[0-9]*) printf ', digits' ;; esac
	case "$1" in *-*) printf ', hyphens' ;; esac
	case "$1" in *[!A-Za-z0-9-]*) printf ', and other characters' ;; esac
}
if on_xcode_cloud; then
	team="${CI_TEAM_ID:-}"
	team="$(printf '%s' "$team" | tr -d '[:space:]')"
	if [ -z "$team" ]; then
		say "warning: CI_TEAM_ID is empty; leaving the team to Xcode Cloud"
	elif printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$'; then
		printf 'DEVELOPMENT_TEAM = %s\n' "$team" >App/Signing.local.xcconfig
		say "wrote App/Signing.local.xcconfig from CI_TEAM_ID"
	else
		say "warning: CI_TEAM_ID isn't a Team ID ($(shape "$team")); leaving the team to Xcode Cloud"
	fi
fi

# --- the starter model --------------------------------------------------------
# The app ships one small model, so a first request works before anyone has
# chosen one. It's fetched, pinned by revision and checksum, never committed,
# and the project copies App/StarterModel into both apps.
say "fetching the starter model"
tools/ci/fetch-starter-model.sh ||
	fail "couldn't fetch the starter model (tools/ci/fetch-starter-model.sh)"

# --- XcodeGen -----------------------------------------------------------------
tools="$(mktemp -d)"
trap 'rm -rf "$tools"' EXIT
url="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
say "fetching XcodeGen $XCODEGEN_VERSION"
# GitHub's release downloads go down for minutes at a time: v0.4.1's first
# build got six 504s in 35 seconds and failed both actions, and the same URL
# worked ten minutes later. So retry for up to ten minutes, with curl's own
# backoff, doubling from a second, rather than a few seconds apart.
curl -fsSL --connect-timeout 30 --retry 12 --retry-all-errors --retry-max-time 600 \
	-o "$tools/xcodegen.zip" "$url" ||
	fail "couldn't fetch XcodeGen from $url after ten minutes of retrying. If GitHub is down (www.githubstatus.com), rebuild once it's back."
got="$(shasum -a 256 "$tools/xcodegen.zip" | awk '{ print $1 }')"
[ "$got" = "$XCODEGEN_SHA256" ] ||
	fail "XcodeGen checksum mismatch: expected $XCODEGEN_SHA256, got $got, from $url"
unzip -q "$tools/xcodegen.zip" -d "$tools"

say "generating conflux.xcodeproj"
"$tools/xcodegen/bin/xcodegen" generate --spec project.yml --quiet

# --- check what the build needs, by name --------------------------------------
# XcodeGen can succeed and still write a project the build can't use. Read the
# Schemes section only: the Targets section lists `conflux` too, so matching
# anywhere would pass without a scheme. `conflux` is the Mac app's scheme and
# `conflux-ipad` the iPad app's, and Xcode Cloud's workflow archives each.
[ -d conflux.xcodeproj ] || fail "conflux.xcodeproj wasn't created"
schemes="$(xcodebuild -project conflux.xcodeproj -list 2>/dev/null |
	awk '/^[[:space:]]*Schemes:/ { s = 1; next } s && NF { print $1 }')"
for scheme in conflux conflux-ipad; do
	printf '%s\n' "$schemes" | grep -qx "$scheme" ||
		fail "the $scheme scheme is missing"
	[ -f "conflux.xcodeproj/xcshareddata/xcschemes/$scheme.xcscheme" ] ||
		fail "the $scheme scheme isn't shared, so Xcode Cloud can't see it"
done

# --- the workflow's scheme fits its platform ----------------------------------
# Each scheme builds one target for one platform. An iOS archive action given
# the Mac app's scheme fails after this hook, with a list of every simulator
# Xcode Cloud has and "Unable to find a destination matching the provided
# destination specifier: { generic:1, platform:iOS }", which doesn't say the
# scheme is the problem. This does. Neither value is a secret.
if on_xcode_cloud && [ -n "${CI_XCODE_SCHEME:-}" ] && [ -n "${CI_PRODUCT_PLATFORM:-}" ]; then
	case "$CI_PRODUCT_PLATFORM" in
	macOS) want=conflux ;;
	iOS | iPadOS) want=conflux-ipad ;;
	*) want="" ;;
	esac
	if [ -n "$want" ] && [ "$CI_XCODE_SCHEME" != "$want" ]; then
		fail "this $CI_PRODUCT_PLATFORM action builds the $CI_XCODE_SCHEME scheme; set the workflow's $CI_PRODUCT_PLATFORM action to the $want scheme (docs/releasing.md)"
	fi
	say "archiving the $CI_XCODE_SCHEME scheme for $CI_PRODUCT_PLATFORM"
fi

say "done"
