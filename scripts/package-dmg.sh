#!/usr/bin/env bash
#
# Builds Face ID in Release and wraps it in a DMG.
#
# Signing is deliberately explicit. The project ships with no DEVELOPMENT_TEAM, and
# its `keychain-access-groups` entitlement needs a real team identifier — so an
# unsigned or ad-hoc bundle is fine to *inspect* but cannot store the session key,
# which means it cannot get through first-run setup.
#
#   ./scripts/package-dmg.sh                     # unsigned DMG (inspection only)
#   TEAM_ID=ABCDE12345 ./scripts/package-dmg.sh  # signed with your team
#
# Notarization is out of scope here: it needs an Apple ID / app-specific password and
# a Developer ID certificate. The app is unsandboxed and calls a private SkyLight API
# to draw on the lock screen, so App Store distribution is not an option either way —
# see README.md → "Distribution".
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="Face ID.xcodeproj"
SCHEME="Face ID"
APP_NAME="Face ID"
DERIVED="build/DerivedData"
DIST="build/dist"
APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"

TEAM_ID="${TEAM_ID:-}"
SANDBOX_FIX="${SANDBOX_FIX:-1}"

# Read the version out of the project so the DMG name can't drift from the bundle's.
VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PROJECT/project.pbxproj" | sed 's/.*= *//; s/;//; s/ //g')"
BUILD_NUMBER="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | sed 's/.*= *//; s/;//; s/ //g')"
DMG_PATH="$DIST/$APP_NAME $VERSION.dmg"

echo "==> Face ID $VERSION ($BUILD_NUMBER)"

# --- Build ------------------------------------------------------------------

# Unsigned by default. Hardened Runtime stays ON in Release either way; it is what
# the app is expected to ship with, and an unsigned bundle simply won't launch.
SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
if [[ -n "$TEAM_ID" ]]; then
  echo "==> Signing with development team $TEAM_ID"
  SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic)
else
  echo "==> No TEAM_ID given — building unsigned."
  echo "    This DMG is for local inspection only: without a team the app cannot"
  echo "    hold its Keychain access group, so it will fail during setup."
fi

# Only needed on a host that can't apply sandbox-exec — see the Makefile header.
SANDBOX_ARGS=()
if [[ "$SANDBOX_FIX" == "1" ]]; then
  SANDBOX_ARGS=(ENABLE_USER_SCRIPT_SANDBOXING=NO OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox")
fi

rm -rf "$DERIVED"
# `${arr[@]+"${arr[@]}"}` rather than `"${arr[@]}"`: macOS still ships bash 3.2,
# where expanding an empty array under `set -u` is an unbound-variable error.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"} \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected the built app at $APP_PATH" >&2
  exit 1
fi

# --- Sign -------------------------------------------------------------------

# Without a team there is still a reason to sign, and it isn't cosmetic: an
# unsigned bundle has no code identity for TCC to record, so an Accessibility
# grant either never applies or is silently invalidated — the app shows
# "not granted" while the switch in System Settings is on. Ad-hoc signing gives
# TCC a cdhash to pin the grant to. It does **not** survive a rebuild (the cdhash
# changes), so `TEAM_ID=...` remains the answer for ongoing development.
#
# Inside-out, because a bundle seals its contents: Sparkle's nested executables and
# XPC services must carry their signatures before the framework is sealed, and the
# framework before the app. Signing the app alone leaves Sparkle's contents
# unsealed and `codesign --verify --deep` fails.
if [[ -z "$TEAM_ID" ]]; then
  echo "==> Signing ad-hoc (inside-out)"

  # Entitlements are generated, not taken from `FaceID/FaceID.entitlements`:
  #
  #  • `disable-library-validation` is **required** here. Release sets
  #    ENABLE_HARDENED_RUNTIME=YES, and that only takes effect once the app is
  #    actually signed. Hardened Runtime enforces library validation, which demands
  #    that the process and every non-platform library it loads share a Team ID.
  #    Ad-hoc signatures have none, and Sparkle's differs from ours, so dyld refuses
  #    to map it and the app dies at launch with:
  #      "mapping process and mapped file (non-platform) have different Team IDs"
  #    (An unsigned bundle never hit this: with no signature, no runtime is enforced.)
  #  • `camera` is kept for parity with the project's own entitlements file.
  #  • `keychain-access-groups` is deliberately **omitted**: it needs a real team
  #    prefix (the file uses `$(AppIdentifierPrefix)`, which nothing expands here),
  #    and the app never sets an access group anyway — `KeychainManager` keys off
  #    `kSecAttrService` alone. Omitting it also keeps Keychain behaviour identical
  #    to the unsigned build that previously worked.
  ENT_PLIST="$(mktemp -t faceid-adhoc-entitlements).plist"
  cat > "$ENT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
</dict>
</plist>
PLIST
  trap 'rm -f "$ENT_PLIST"' EXIT

  FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$FW" ]]; then
    # Executables get the same entitlements as the app, so each of them can also load
    # Sparkle without tripping library validation in its own process.
    for nested in "$FW/Versions/B/Updater.app" "$FW/Versions/B/XPCServices/"*.xpc; do
      [[ -e "$nested" ]] || continue
      codesign --force --sign - --options runtime --entitlements "$ENT_PLIST" \
        --preserve-metadata=identifier "$nested" 2>/dev/null || true
    done
    codesign --force --sign - --options runtime "$FW" 2>/dev/null || true
  fi

  codesign --force --sign - --options runtime --entitlements "$ENT_PLIST" "$APP_PATH"
fi

# --- Verify -----------------------------------------------------------------

echo "==> Verifying bundle"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier"      "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict "$APP_PATH" 2>/dev/null \
  && echo "    signature: verified" \
  || echo "    signature: unsigned (expected without TEAM_ID)"

# --- Stage & wrap -----------------------------------------------------------

echo "==> Building $DMG_PATH"
mkdir -p "$DIST"
rm -f "$DMG_PATH"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_PATH" "$STAGE/"
# The usual drag-to-install target.
ln -s /Applications "$STAGE/Applications"

# `hdiutil create` prints a deprecation notice on the current beta in favour of
# `diskutil image create`, but the replacement is newer than this project's macOS 15
# deployment floor — keeping hdiutil is what lets one script serve both.
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null 2>&1

echo "==> Done"
ls -lh "$DMG_PATH"
