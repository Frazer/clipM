#!/usr/bin/env bash
# Build a Sparkle-ready ClipMenu.dmg + appcast.xml for GitHub Releases.
#
# Usage:
#   ./scripts/release-dmg.sh                 # build + DMG + appcast (notarize if creds present)
#   ./scripts/release-dmg.sh --skip-notarize # local packaging without notarization
#   ./scripts/release-dmg.sh --publish       # also create/upload a GitHub release (requires gh)
#
# Expected secrets / env (for notarize + CI):
#   SPARKLE_PRIVATE_KEY   EdDSA private key string (or file at secrets/sparkle_eddsa_private.key)
#   APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID  for notarytool
#   Or APPLE_API_KEY / APPLE_API_ISSUER / APPLE_API_KEY_PATH
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --publish) PUBLISH=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

TEAM_ID="${APPLE_TEAM_ID:-97988GNC59}"
BUNDLE_ID="app.eetr.ClipMenu"
SCHEME="ClipMenu"
CONFIG="Release"
REPO="${GITHUB_REPOSITORY:-Frazer/ClipMenu}"

OUT="$ROOT/release"
STAGE="$OUT/stage"
DMG_ROOT="$OUT/dmg-root"
INBOX="$OUT/sparkle-inbox"
mkdir -p "$OUT" "$STAGE" "$DMG_ROOT" "$INBOX"

version_plist_key() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/project.yml" 2>/dev/null || true
}

# Prefer MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml via xcodebuild later.
MARKETING_VERSION="$(python3 - <<'PY'
import re
from pathlib import Path
text = Path("project.yml").read_text()
# First ClipMenu target marketing version
m = re.search(r"PRODUCT_NAME: ClipMenu\n.*?MARKETING_VERSION: \"([^\"]+)\"", text, re.S)
print(m.group(1) if m else "1.0.0")
PY
)"
BUILD_NUMBER="$(python3 - <<'PY'
import re
from pathlib import Path
text = Path("project.yml").read_text()
m = re.search(r"PRODUCT_NAME: ClipMenu\n.*?CURRENT_PROJECT_VERSION: \"([^\"]+)\"", text, re.S)
print(m.group(1) if m else "1")
PY
)"

TAG="${RELEASE_TAG:-v${MARKETING_VERSION}}"
DMG_NAME="ClipMenu-${MARKETING_VERSION}.dmg"
DMG_PATH="$OUT/$DMG_NAME"

echo "==> Version ${MARKETING_VERSION} (${BUILD_NUMBER})  tag=${TAG}"

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi
xcodegen generate

find_sparkle_bin() {
  local name="$1"
  local found
  found="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/artifacts/sparkle/Sparkle/bin/'"$name" -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi
  return 1
}

ensure_sparkle_tools() {
  if find_sparkle_bin generate_appcast >/dev/null && find_sparkle_bin sign_update >/dev/null; then
    SPARKLE_BIN_DIR="$(dirname "$(find_sparkle_bin generate_appcast)")"
    return 0
  fi
  echo "==> Downloading Sparkle tools…"
  local tmp zip
  tmp="$(mktemp -d)"
  zip="$tmp/Sparkle.tar.xz"
  curl -fsSL -o "$zip" "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz"
  tar -xJf "$zip" -C "$tmp"
  SPARKLE_BIN_DIR="$(find "$tmp" -type d -name bin | head -1)"
  export PATH="$SPARKLE_BIN_DIR:$PATH"
}

ensure_sparkle_tools
export PATH="${SPARKLE_BIN_DIR}:${PATH}"
echo "==> Sparkle tools: $SPARKLE_BIN_DIR"

IDENTITY=""
if security find-identity -v -p codesigning | grep -q 'Developer ID Application'; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  echo "==> Using signing identity: $IDENTITY"
else
  echo "ERROR: No 'Developer ID Application' certificate found." >&2
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application" >&2
  echo "Then re-run this script. (Apple Development certs are not enough for public DMG distribution.)" >&2
  exit 1
fi

echo "==> Building ${SCHEME} ${CONFIG}…"
DERIVED="$OUT/DerivedData"
rm -rf "$DERIVED"
xcodebuild \
  -project ClipMenu.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

APP_SRC="$(find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name 'ClipMenu.app' -print -quit)"
if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "ClipMenu.app not found in build products" >&2
  exit 1
fi

# Verify Sparkle public key made it into Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_SRC/Contents/Info.plist" >/dev/null

rm -rf "$STAGE/ClipMenu.app"
ditto "$APP_SRC" "$STAGE/ClipMenu.app"

echo "==> codesign verify…"
codesign --verify --deep --strict --verbose=2 "$STAGE/ClipMenu.app"
codesign -dv --verbose=2 "$STAGE/ClipMenu.app" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier' || true

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "==> Notarizing app (zip)…"
  APP_ZIP="$OUT/ClipMenu-app.zip"
  ditto -c -k --keepParent "$STAGE/ClipMenu.app" "$APP_ZIP"
  if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$APP_ZIP" \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY" \
      --issuer "$APPLE_API_ISSUER" \
      --wait
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$APP_ZIP" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$TEAM_ID" \
      --wait
  else
    echo "ERROR: Notarization credentials missing. Pass --skip-notarize for a local unpackaged test," >&2
    echo "or set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD (+ APPLE_TEAM_ID), or App Store Connect API key env vars." >&2
    exit 1
  fi
  xcrun stapler staple "$STAGE/ClipMenu.app"
  spctl --assess --type execute -vv "$STAGE/ClipMenu.app" || true
else
  echo "==> Skipping notarization (--skip-notarize)"
fi

echo "==> Creating DMG $DMG_NAME…"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$STAGE/ClipMenu.app" "$DMG_ROOT/ClipMenu.app"
ln -sf /Applications "$DMG_ROOT/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "ClipMenu" \
  -srcfolder "$DMG_ROOT" \
  -ov -format UDZO \
  "$DMG_PATH"

# Sign the DMG with Developer ID as well (Gatekeeper)
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "==> Notarizing DMG…"
  if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY" \
      --issuer "$APPLE_API_ISSUER" \
      --wait
  else
    xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$TEAM_ID" \
      --wait
  fi
  xcrun stapler staple "$DMG_PATH"
fi

echo "==> Generating Sparkle appcast…"
rm -rf "$INBOX"
mkdir -p "$INBOX"
cp "$DMG_PATH" "$INBOX/"

KEY_FILE=""
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  KEY_FILE="$(mktemp)"
  printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
  trap 'rm -f "$KEY_FILE"' EXIT
elif [[ -f "$ROOT/secrets/sparkle_eddsa_private.key" ]]; then
  KEY_FILE="$ROOT/secrets/sparkle_eddsa_private.key"
else
  echo "ERROR: Sparkle private key not found." >&2
  echo "Expected secrets/sparkle_eddsa_private.key or SPARKLE_PRIVATE_KEY env." >&2
  exit 1
fi

DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"
generate_appcast \
  --account clipmenu \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/${REPO}" \
  --maximum-deltas 0 \
  "$INBOX"

cp "$INBOX/appcast.xml" "$OUT/appcast.xml"
ls -la "$OUT"

echo
echo "Artifacts:"
echo "  $DMG_PATH"
echo "  $OUT/appcast.xml"
echo
echo "Upload both as GitHub Release assets for tag ${TAG}."
echo "Sparkle feed URL: https://github.com/${REPO}/releases/latest/download/appcast.xml"

if [[ "$PUBLISH" -eq 1 ]]; then
  if ! command -v gh >/dev/null; then
    echo "gh CLI required for --publish" >&2
    exit 1
  fi
  echo "==> Publishing GitHub release ${TAG}…"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG_PATH" "$OUT/appcast.xml" --clobber
  else
    gh release create "$TAG" "$DMG_PATH" "$OUT/appcast.xml" \
      --title "ClipMenu ${MARKETING_VERSION}" \
      --notes "ClipMenu ${MARKETING_VERSION} (build ${BUILD_NUMBER}).

Direct-download build with Sparkle updates. Open the DMG and drag ClipMenu to Applications."
  fi
  echo "Published: https://github.com/${REPO}/releases/tag/${TAG}"
fi
