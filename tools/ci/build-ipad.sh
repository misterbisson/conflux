#!/usr/bin/env bash
#
# Builds the iPad app, Release, for devices, unsigned. Run
# ci_scripts/ci_post_clone.sh first.
#
#   tools/ci/build-ipad.sh
#
# Devices only: the pinned llama.cpp framework has no iOS Simulator slice.
# Unsigned, because the iPad app's memory entitlements need a provisioning
# profile, which only the team's signing brings. So this checks that it
# compiles, with warnings as errors as Xcode Cloud would, and nothing runs.
# The model is tested on a real iPad (docs/running.md, "On an iPad").

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

xcodebuild build \
	-project conflux.xcodeproj \
	-scheme conflux-ipad \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-derivedDataPath build/DerivedData-ipad \
	CODE_SIGNING_ALLOWED=NO \
	-quiet

app=build/DerivedData-ipad/Build/Products/Release-iphoneos/conflux.app
[ -d "$app" ] || { echo "build-ipad: no app at $app" >&2; exit 1; }
plist="$app/Info.plist"
fail=0
expect() {
	local key="$1" want="$2" got
	got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
	if [ "$got" = "$want" ]; then
		echo "ok: $key is $want"
	else
		echo "FAIL: $key is '$got', expected '$want'" >&2
		fail=1
	fi
}
# One app with the Mac's: the same bundle ID.
expect CFBundleIdentifier com.caseybisson.conflux
expect UIDeviceFamily:0 2
expect UIFileSharingEnabled true
expect ITSAppUsesNonExemptEncryption false
expect MinimumOSVersion 18.0
expect CFBundleShortVersionString "$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)"
for file in Credits.html PrivacyInfo.xcprivacy; do
	if [ -f "$app/$file" ]; then
		echo "ok: ships $file"
	else
		echo "FAIL: no $file in the app" >&2
		fail=1
	fi
done
exit "$fail"
