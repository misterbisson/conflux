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

# --- the binaries -------------------------------------------------------------
binaries=("$app/Contents/MacOS/$(value "$info" CFBundleExecutable)")
for framework in "$app"/Contents/Frameworks/*.framework; do
	[ -d "$framework" ] || continue
	binaries+=("$framework/Versions/Current/$(basename "$framework" .framework)")
done

# --- the privacy manifest -----------------------------------------------------
# App Store Connect scans an upload for the APIs on Apple's required-reason
# list, and refuses one that uses them without saying why in a privacy
# manifest (ITMS-91053, by email). Apple enforces it for iOS and the other
# device platforms, not yet for macOS; conflux declares them anyway.
#
# Each category, as what a binary imports for it: symbols, or Objective-C
# selectors, which Swift calls through objc_msgSend.
category_symbols() {
	case "$1" in
	FileTimestamp) echo '^_(f?stat|lstat|fstatat|f?getattrlist|getattrlistbulk|getattrlistat)([$]INODE64)?$|^_NSFile(Creation|Modification)Date$|^_NSURL(ContentModification|Creation)DateKey$' ;;
	SystemBootTime) echo '^_mach_absolute_time$' ;;
	DiskSpace) echo '^_f?statv?fs([$]INODE64)?$|^_NSFileSystem(Free)?Size$|^_NSURLVolume(Total|Available)Capacity' ;;
	ActiveKeyboards) echo '^$' ;;
	UserDefaults) echo '^_OBJC_CLASS_[$]_NSUserDefaults$' ;;
	esac
}
category_selectors() {
	case "$1" in
	FileTimestamp) echo '^(fileCreationDate|fileModificationDate)$' ;;
	SystemBootTime) echo '^systemUptime$' ;;
	ActiveKeyboards) echo '^activeInputModes$' ;;
	*) echo '^$' ;;
	esac
}
# declared MANIFEST: the categories it gives at least one reason for.
declared() {
	local i=0 type
	[ -f "$1" ] || return 0
	while type="$(value "$1" "NSPrivacyAccessedAPITypes:$i:NSPrivacyAccessedAPIType")" && [ -n "$type" ]; do
		[ -n "$(value "$1" "NSPrivacyAccessedAPITypes:$i:NSPrivacyAccessedAPITypeReasons:0")" ] &&
			echo "${type#NSPrivacyAccessedAPICategory}"
		i=$((i + 1))
	done
}

manifest="$app/Contents/Resources/PrivacyInfo.xcprivacy"
if [ ! -f "$manifest" ]; then
	fail "no PrivacyInfo.xcprivacy in the app's Resources"
elif ! plutil -lint -s "$manifest"; then
	fail "PrivacyInfo.xcprivacy isn't a valid property list"
else
	ok "privacy manifest"
	check "no tracking" "PrivacyInfo.xcprivacy should say NSPrivacyTracking is false" \
		same "$(value "$manifest" NSPrivacyTracking)" false
	app_declared="$(declared "$manifest")"
	for binary in "${binaries[@]}"; do
		name="$(basename "$binary")"
		# A framework may carry its own manifest, which covers its own calls.
		own="$(dirname "$(dirname "$(dirname "$binary")")")/Resources/PrivacyInfo.xcprivacy"
		[ "$binary" = "${binaries[0]}" ] && own=/dev/null
		allowed="$(printf '%s\n%s\n' "$app_declared" "$(declared "$own")")"
		nm -u "$binary" 2>/dev/null | sort -u >"$work/imports"
		strings -a "$binary" | sort -u >"$work/strings"
		for category in FileTimestamp SystemBootTime DiskSpace ActiveKeyboards UserDefaults; do
			found="$({
				grep -E "$(category_symbols "$category")" "$work/imports"
				grep -E "$(category_selectors "$category")" "$work/strings"
			} | grep . | tr '\n' ' ' || true)"
			[ -n "$found" ] || continue
			if grep -qx "$category" <<<"$allowed"; then
				ok "$name uses $category APIs, and the manifest says why"
			else
				fail "$name uses $category APIs (${found% }) that no privacy manifest declares; add the reason to App/PrivacyInfo.xcprivacy"
			fi
		done
	done
fi

# --- export compliance --------------------------------------------------------
# ITSAppUsesNonExemptEncryption is false because every use of cryptography in
# the app is the operating system's and encrypts nothing, file by file, as the
# note beside it in project.yml says. Two things would change that answer: a
# new use in the sources, and a cryptography library compiled into the app
# (iroh's QUIC and TLS, OpenSSL, BoringSSL, mbedTLS, libsodium).
grep -rlE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(CryptoKit|CommonCrypto|Security|CryptoTokenKit)\b|\bSec(Random|Key|Trust|Identity|Certificate)|\bCC(Crypt|_SHA|_MD5|Hmac)|NWProtocolTLS|sec_protocol_|\.tls\b' \
	Sources/conflux Sources/ConfluxCore | sort >"$work/uses" || true
unnamed=""
while read -r file; do
	grep -qF "# - $file:" project.yml || unnamed+=" $file"
done <"$work/uses"
check "export-compliance note names every source file that uses cryptography" \
	"these use cryptography or TLS but aren't in the export-compliance note in project.yml, so ITSAppUsesNonExemptEncryption may no longer be true:$unnamed" \
	absent "$unnamed"

bundled=""
for binary in "${binaries[@]}"; do
	# Not `strings | grep -q`: grep -q stops at the first match, strings dies
	# of SIGPIPE, and pipefail turns the match into a miss.
	if grep -qiE 'ring_core_0_|ring-0\.1[0-9]|rustls|quinn-proto|OpenSSL [0-9]|BoringSSL|mbed ?TLS|libsodium' \
		< <(strings -a "$binary"); then
		bundled+=" $(basename "$binary")"
	fi
done
check "no bundled cryptography library" \
	"bundled cryptography in:$bundled. ITSAppUsesNonExemptEncryption=NO rests on all of it being the operating system's; answer it again (see project.yml)" \
	absent "$bundled"

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
check "may connect (the mesh)" "com.apple.security.network.client is missing, so the app can't reach peers" \
	same "$(entitlement com.apple.security.network.client)" true
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
