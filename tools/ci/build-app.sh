#!/usr/bin/env bash
#
# Archives the Mac app the way Xcode Cloud does, Release, but signed ad hoc
# instead of with the team's certificate, then checks the result with
# check-app.sh. Run ci_scripts/ci_post_clone.sh first.
#
#   tools/ci/build-app.sh
#
# Ad hoc signing still embeds the entitlements, so the archive runs in the App
# Sandbox like the TestFlight build and check-app.sh can read them. No team,
# certificate or profile is involved.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

archive=build/conflux.xcarchive
rm -rf "$archive"

xcodebuild archive \
	-project conflux.xcodeproj \
	-scheme conflux \
	-configuration Release \
	-destination 'generic/platform=macOS' \
	-archivePath "$archive" \
	-derivedDataPath build/DerivedData \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_IDENTITY=- \
	DEVELOPMENT_TEAM= \
	-quiet

tools/ci/check-app.sh "$archive"

# --- run it, in the sandbox ---------------------------------------------------
# The archive itself won't launch: under the hardened runtime, library
# validation refuses a framework that doesn't share the app's Team ID, and ad
# hoc signatures have none. Xcode Cloud signs both with the team, so this is a
# property of the ad hoc build only. A copy re-signed without the hardened
# runtime, under its own bundle ID so its container is separate from the real
# app's, shows the app starts, loads llama.framework and runs in the sandbox.
smoke=build/smoke
id=com.caseybisson.conflux.smoke
rm -rf "$smoke"
mkdir -p "$smoke"
cp -R "$archive/Products/Applications/conflux.app" "$smoke/"
app="$smoke/conflux.app"
codesign -d --entitlements - --xml "$archive/Products/Applications/conflux.app" >"$smoke/entitlements.plist" 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Frameworks/llama.framework"
codesign --force --sign - --entitlements "$smoke/entitlements.plist" "$app"

outside="$HOME/Library/Application Support/conflux/token"
[ -e "$outside" ] && was_outside=yes || was_outside=no
# The token is a secret, even this throwaway one: measured, never printed.
length="$("$app/Contents/MacOS/conflux" token | tr -d '\n' | wc -c | tr -d ' ')"
if [ "$length" -lt 32 ]; then
	echo "::error::the sandboxed app didn't print a token"
	exit 1
fi
if [ ! -d "$HOME/Library/Containers/$id" ]; then
	echo "::error::the app ran without a sandbox container, so it isn't sandboxed"
	exit 1
fi
if [ "$was_outside" = no ] && [ -e "$outside" ]; then
	echo "::error::the sandboxed app wrote its token outside its container"
	exit 1
fi
echo "ok: runs in the sandbox, with llama.framework loaded and its files in its container"
