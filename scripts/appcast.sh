#!/usr/bin/env bash
#
# Sparkle appcast publisher.
#
# Signs a release zip with the EdDSA key, (re)generates appcast.xml, and
# publishes it to the gh-pages branch — served at
# https://awizemann.github.io/harness/appcast.xml (the app's SUFeedURL).
#
# Called by scripts/release.sh AFTER the GitHub release is created (the
# appcast's enclosure URL points at the release asset, which must exist).
# Also runnable standalone for recovery:  ./scripts/appcast.sh 0.6.0
#
# Prereq: the Sparkle EdDSA PRIVATE key in your login Keychain — run the
# bundled `generate_keys` tool once. generate_appcast reads it automatically.
#
# Path discipline: this only writes appcast.xml on gh-pages, a path disjoint
# from scripts/site.sh's OWNED_ROOT_FILES, so the two publishers never collide.
#
set -euo pipefail

VERSION="${1:?usage: appcast.sh <marketing-version>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_REPO="awizemann/harness"
PROJECT="$REPO_ROOT/Harness.xcodeproj"
SCHEME="Harness"
BUILD_DIR="$REPO_ROOT/build"
DD="$BUILD_DIR/DerivedData"
RELEASE_DIR="$REPO_ROOT/releases/v${VERSION}"
ZIP_NAME="Harness-v${VERSION}-Universal.zip"
DOWNLOAD_PREFIX="https://github.com/${GH_REPO}/releases/download/v${VERSION}/"
GHPAGES_DIR="$REPO_ROOT/.gh-pages-worktree"

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$RELEASE_DIR/$ZIP_NAME" ]] || die "missing release zip: $RELEASE_DIR/$ZIP_NAME (run release.sh first)"

# ---------- resolve Sparkle's bundled tools ----------
SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  log "Resolving Sparkle package tools"
  xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DD" >/dev/null
fi
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || die "generate_appcast not found under $SPARKLE_BIN"

# ---------- key present? ----------
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 \
  || die "no Sparkle EdDSA key in your login Keychain.
  Generate it once:  $SPARKLE_BIN/generate_keys
  then paste the printed public key into Harness/Resources/Info.plist (SUPublicEDKey)."

# ---------- sign + build the appcast ----------
# generate_appcast scans RELEASE_DIR, signs each archive with the Keychain
# EdDSA key, reads the version from inside the .app, and writes appcast.xml.
# --download-url-prefix makes enclosures point at this version's GitHub asset.
#
# By design the feed is SINGLE-ITEM (one zip per release dir → only the latest
# version is listed). That is correct for delivery: Sparkle offers the newest
# qualifying item to a host on ANY older version (full-package replacement, no
# sequential upgrade path). The tradeoff is no deltas / no version history in
# the feed — intentional; don't "fix" it by accident.
log "Generating + signing appcast.xml"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR" \
  || die "generate_appcast failed"
[[ -f "$RELEASE_DIR/appcast.xml" ]] || die "appcast.xml was not produced"

# ---------- publish to gh-pages ----------
log "Publishing appcast.xml to gh-pages"
git -C "$REPO_ROOT" fetch origin gh-pages || die "fetch origin gh-pages failed (network?) — release is live; re-run ./scripts/appcast.sh ${VERSION} when back online."
if [[ -d "$GHPAGES_DIR" ]]; then
  # Reuse the existing worktree (it may be shared with scripts/site.sh).
  # Refuse to proceed on uncommitted changes (e.g. a `site.sh build`/`preview`
  # left index.html dirty) — otherwise the pull below can abort mid-publish.
  git -C "$GHPAGES_DIR" diff --quiet && git -C "$GHPAGES_DIR" diff --cached --quiet \
    || die "uncommitted changes in $GHPAGES_DIR (left by scripts/site.sh?) — commit or discard them, then re-run ./scripts/appcast.sh ${VERSION}."
  git -C "$GHPAGES_DIR" checkout gh-pages
  git -C "$GHPAGES_DIR" pull --ff-only origin gh-pages \
    || die "gh-pages worktree diverged. Reconcile it: git -C $GHPAGES_DIR reset --hard origin/gh-pages — then re-run ./scripts/appcast.sh ${VERSION}."
else
  # Base the new worktree on the REMOTE tip, not a possibly-stale local
  # gh-pages branch (a plain `worktree add gh-pages` checks out the local ref,
  # which on a cold machine can be behind origin and push a stale rewind).
  git -C "$REPO_ROOT" worktree add -B gh-pages "$GHPAGES_DIR" origin/gh-pages
fi

cp "$RELEASE_DIR/appcast.xml" "$GHPAGES_DIR/appcast.xml"
git -C "$GHPAGES_DIR" add appcast.xml
if git -C "$GHPAGES_DIR" diff --cached --quiet; then
  log "appcast.xml unchanged — nothing to publish"
else
  git -C "$GHPAGES_DIR" commit -m "appcast: Harness v${VERSION}"
  git -C "$GHPAGES_DIR" push origin gh-pages
fi

log "Done. appcast live at https://awizemann.github.io/harness/appcast.xml"
