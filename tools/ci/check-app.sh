#!/usr/bin/env bash
#
# Checks an archive of the Mac app for what App Store Connect requires.
#
#   tools/ci/check-app.sh build/conflux.xcarchive
#
# App Store Connect reports most of these by email, after Xcode Cloud has
# uploaded the build and logged success. Checking the archive on every pull
# request finds them before a release is tagged.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

archive="${1:?usage: check-app.sh <archive>}"
failures=0
fail() {
	echo "::error::$*"
	failures=$((failures + 1))
}
ok() { echo "ok: $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- the archive holds one app --------------------------------------------------
# An archive with anything else in Products is a generic archive, which Xcode
# Cloud can't distribute.
apps="$(find "$archive/Products" -name '*.app' -type d -prune)"
if [ "$(printf '%s\n' "$apps" | grep -c .)" != 1 ] || [ "$apps" != "$archive/Products/Applications/conflux.app" ]; then
	echo "::error::$archive should hold exactly Products/Applications/conflux.app; it holds: $(find "$archive/Products" -mindepth 2 -maxdepth 2 | tr '\n' ' ')"
	exit 1
fi
others="$(find "$archive/Products" -mindepth 1 -maxdepth 1 ! -name Applications)"
[ -z "$others" ] || fail "the archive's Products holds more than the app, so it's a generic archive: $others"
app="$apps"
info="$app/Contents/Info.plist"

value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
setting() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"#[:space:]]+)\"?.*/\\1/p" project.yml | sed -n 1p; }
# check PASSED FAILED COMMAND...: says which, by whether the command succeeds.
check() {
	local passed="$1" failed="$2"
	shift 2
	if "$@"; then ok "$passed"; else fail "$failed"; fi
}
same() { [ -n "$1" ] && [ "$1" = "$2" ]; }
present() { [ -n "$1" ]; }
absent() { [ -z "$1" ]; }

# --- Info.plist ---------------------------------------------------------------
expected="$(setting MARKETING_VERSION)"
got="$(value "$info" CFBundleShortVersionString)"
check "version $got, from MARKETING_VERSION" \
	"CFBundleShortVersionString is '$got', and project.yml's MARKETING_VERSION is '$expected'" \
	same "$got" "$expected"

check "build number set" "CFBundleVersion is missing" present "$(value "$info" CFBundleVersion)"

expected="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
got="$(value "$info" CFBundleIdentifier)"
check "bundle ID $got" "CFBundleIdentifier is '$got', expected '$expected'" same "$got" "$expected"

# Missing, it holds every TestFlight build at the export-compliance question.
check "export compliance answered" "ITSAppUsesNonExemptEncryption should be false" \
	same "$(value "$info" ITSAppUsesNonExemptEncryption)" false

got="$(value "$info" LSApplicationCategoryType)"
check "category $got" "LSApplicationCategoryType is missing; App Store Connect requires it for a Mac app" \
	present "$got"

# --- the icon -----------------------------------------------------------------
# ITMS-90236: a Mac app needs an ICNS icon with a 512pt @2x image.
icon="$(value "$info" CFBundleIconFile)"
icns="$app/Contents/Resources/${icon%.icns}.icns"
if [ -z "$icon" ] || [ ! -f "$icns" ]; then
	fail "no icon: CFBundleIconFile is '$icon'"
elif ! iconutil -c iconset -o "$work/icon.iconset" "$icns" 2>/dev/null; then
	fail "$icns isn't a readable ICNS file"
elif [ ! -f "$work/icon.iconset/icon_512x512@2x.png" ]; then
	fail "the icon has no 512pt @2x image (ITMS-90236)"
else
	ok "icon has a 512pt @2x image"
fi

# --- signing and entitlements -------------------------------------------------
verified=yes
codesign --verify --deep --strict "$app" 2>"$work/verify.log" || verified=no
check "signature verifies, frameworks included" "codesign --verify failed: $(tr '\n' ' ' <"$work/verify.log")" \
	same "$verified" yes

codesign -d --verbose=2 "$app" >"$work/signature.txt" 2>&1 || true
check "hardened runtime" "the app isn't signed with the hardened runtime" \
	grep -q 'flags=.*runtime' "$work/signature.txt"

codesign -d --entitlements - --xml "$app" >"$work/entitlements.plist" 2>/dev/null || true
entitlement() { value "$work/entitlements.plist" "$1"; }
check "sandboxed" "the App Sandbox entitlement is missing; App Store Connect refuses unsandboxed Mac apps" \
	same "$(entitlement com.apple.security.app-sandbox)" true
check "may listen (the gateway)" "com.apple.security.network.server is missing, so the gateway can't listen" \
	same "$(entitlement com.apple.security.network.server)" true
check "no get-task-allow" "the Release build claims get-task-allow, which App Store Connect refuses" \
	absent "$(entitlement com.apple.security.get-task-allow)"

# --- embedded frameworks --------------------------------------------------------
for framework in "$app"/Contents/Frameworks/*.framework; do
	[ -d "$framework" ] || continue
	name="$(basename "$framework")"
	plist="$framework/Resources/Info.plist"
	[ -f "$plist" ] || plist="$framework/Versions/Current/Resources/Info.plist"
	if [ -n "$(value "$plist" CFBundleShortVersionString)" ] && [ -n "$(value "$plist" CFBundleVersion)" ]; then
		ok "$name has a version"
	else
		fail "$name has no CFBundleShortVersionString or CFBundleVersion; App Store Connect refuses it"
	fi
done

if [ "$failures" -gt 0 ]; then
	echo "$failures problem(s) in $app"
	exit 1
fi
echo "the app archive is ready for App Store Connect, as far as this checks"
