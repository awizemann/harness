#!/usr/bin/env bash
#
# Harness release pipeline — local, manual, repeatable.
#
# Usage:
#   ./scripts/release.sh 0.1.0              # full release: build, sign, notarize,
#                                           # GitHub release, tag main
#   ./scripts/release.sh 0.1.0 --draft      # everything builds + notarizes, but the
#                                           # GitHub release is created as draft and
#                                           # main is NOT tagged. Promote manually.
#
# Release notes:
#   `releases/v<VERSION>/RELEASE_NOTES.md` MUST exist before running. The script
#   uses it as the GitHub release body. Write the notes ahead of time, commit
#   them, then run release.
#
# Prerequisites (one-time setup):
#   1. Developer ID Application cert installed in login Keychain.
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. App Store Connect API key stored for notarytool as profile "harness-notary":
#        xcrun notarytool store-credentials "harness-notary" \
#          --key ~/.private/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#   3. gh CLI authed:
#        gh auth status
#
# What it does NOT do (yet — future, when Sparkle ships for Harness):
#   - No appcast.xml push. v0.1 is "download from GitHub Releases", no auto-update.
#   - No EdDSA signature on the artifact. Sparkle expects one for trusted updates;
#     manual download doesn't need it.
#

set -euo pipefail

# ---------- arg parsing ----------
VERSION=""
DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) printf '[ERR] unknown flag: %s\n' "$arg" >&2; exit 1 ;;
    *) [[ -z "$VERSION" ]] && VERSION="$arg" || { printf '[ERR] unexpected arg: %s\n' "$arg" >&2; exit 1; } ;;
  esac
done
[[ -n "$VERSION" ]] || { printf 'usage: ./scripts/release.sh <marketing-version> [--draft]\n' >&2; exit 1; }

# ---------- config ----------
TEAM_ID="3Q6X2L86C4"
BUNDLE_ID="com.harness.app"
SCHEME="Harness"
PROJECT="Harness.xcodeproj"
NOTARY_PROFILE="harness-notary"
SIGNING_IDENTITY="Developer ID Application"
DOWNLOAD_URL_BASE="https://github.com/awizemann/harness/releases/download"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Harness.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
RELEASE_DIR="$REPO_ROOT/releases/v${VERSION}"
ZIP_NAME="Harness-v${VERSION}-Universal.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------- preflight ----------
log "Preflight checks"
require_cmd xcodebuild
require_cmd xcrun
require_cmd ditto
require_cmd gh
require_cmd xcodegen

cd "$REPO_ROOT"

# Git must be clean and on main. Allow the release dir to exist (RELEASE_NOTES.md
# pre-written) — git status abbreviates a fully-untracked dir to its trailing
# slash, so we whitelist both forms.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "must be on 'main' (currently '$BRANCH')"

DIRTY="$(git status --porcelain | grep -vE "^\?\? releases/v${VERSION}(/RELEASE_NOTES\.md)?$" || true)"
[[ -z "$DIRTY" ]] || die "git working tree must be clean (excluding releases/v${VERSION}/RELEASE_NOTES.md). Run 'git status'."

# Release notes must exist.
NOTES_PATH="$RELEASE_DIR/RELEASE_NOTES.md"
[[ -f "$NOTES_PATH" ]] || die "missing release notes at $NOTES_PATH. Write them first, commit, then re-run."

# Tag must not already exist.
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  die "tag 'v${VERSION}' already exists. Bump the version or delete the tag."
fi

# Codesign identity present.
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "no '$SIGNING_IDENTITY' identity in login Keychain. See header for setup."

# Notary profile present (no listing API; we test by attempting a help call).
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format plist >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' missing or invalid. See header for setup."

# gh authed.
gh auth status >/dev/null 2>&1 || die "'gh' is not authenticated. Run 'gh auth login'."

log "Preflight OK"

# ---------- bump MARKETING_VERSION in project.yml ----------
log "Setting project.yml MARKETING_VERSION to $VERSION"
# project.yml's `MARKETING_VERSION: "0.1.0"` line — replace inline.
python3 - "$REPO_ROOT/project.yml" "$VERSION" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
new = re.sub(r'(MARKETING_VERSION:\s*)"[^"]+"', rf'\1"{version}"', text)
if new == text:
    raise SystemExit("MARKETING_VERSION line not found in project.yml")
path.write_text(new)
PY

log "Regenerating Harness.xcodeproj"
xcodegen generate >/dev/null

# Stage the version bump (committed alongside the release notes below).
git add project.yml

# ---------- archive ----------
log "Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving (Release, universal)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  archive

# ---------- export ----------
log "Exporting (.app)"
mkdir -p "$EXPORT_DIR"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/${SCHEME}.app"
[[ -d "$APP_PATH" ]] || die "exported .app not found at $APP_PATH"

# ---------- notarize ----------
log "Zipping for notarization"
NOTARIZE_ZIP="$BUILD_DIR/Harness-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

log "Submitting to notarytool (this can take a few minutes)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

log "Stapling ticket to .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" >/dev/null

# ---------- final zip ----------
log "Packaging $ZIP_NAME"
mkdir -p "$RELEASE_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Sanity-check the Gatekeeper assessment.
log "spctl --assess (should print 'accepted')"
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'

# ---------- commit + tag ----------
log "Committing version bump + release notes"
git add "$NOTES_PATH"
git commit -m "release: v${VERSION}

$(head -1 "$NOTES_PATH" | sed 's/^# //')

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

if [[ "$DRAFT" -eq 1 ]]; then
  warn "draft mode — skipping tag + push of main"
else
  log "Tagging v${VERSION}"
  git tag -a "v${VERSION}" -m "Harness v${VERSION}"
  log "Pushing main + tag"
  git push origin main
  git push origin "v${VERSION}"
fi

# ---------- gh release ----------
RELEASE_FLAGS=(--title "Harness v${VERSION}" --notes-file "$NOTES_PATH")
if [[ "$DRAFT" -eq 1 ]]; then
  RELEASE_FLAGS+=(--draft)
fi

log "Creating GitHub release"
if [[ "$DRAFT" -eq 1 ]]; then
  # Draft releases don't need a tag yet — gh creates a placeholder.
  gh release create "v${VERSION}" "$ZIP_PATH" "${RELEASE_FLAGS[@]}" || die "gh release create failed"
else
  gh release create "v${VERSION}" "$ZIP_PATH" "${RELEASE_FLAGS[@]}" --target main \
    || die "gh release create failed"
fi

log "Done."
log "Artifact: $ZIP_PATH"
if [[ "$DRAFT" -eq 1 ]]; then
  log "Draft release created. Promote at: https://github.com/awizemann/harness/releases"
else
  log "Live: https://github.com/awizemann/harness/releases/tag/v${VERSION}"
fi
