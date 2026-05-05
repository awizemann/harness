#!/usr/bin/env bash
#
# Harness landing-site helper — builds the marketing landing page from
# site/landing/ and (on `publish`) commits + pushes to gh-pages.
#
# Usage:
#   ./scripts/site.sh check              # validate that all required files exist + secret-scan source
#   ./scripts/site.sh build              # render to .gh-pages-worktree/ root (with token substitution)
#   ./scripts/site.sh preview [PORT]     # build + serve on localhost:PORT (default 8000)
#   ./scripts/site.sh serve   [PORT]     # serve .gh-pages-worktree/ without rebuilding (default 8000)
#   ./scripts/site.sh publish            # check + build + secret-scan + commit + push gh-pages
#   ./scripts/site.sh --help             # this help
#
# Path discipline. This script ONLY touches the files listed in OWNED_ROOT_FILES
# below, plus the top-level assets/ directory on gh-pages. Other publishers
# (when added) must stay on disjoint paths.
#
# Bootstrap (one-time): a .gh-pages-worktree/ clone of the gh-pages branch.
#     git fetch origin gh-pages
#     git worktree add .gh-pages-worktree gh-pages
#
# Token substitution. index.html and sitemap.xml.tmpl are run through a
# minimal {{TOKEN}} replacement at build time:
#   {{VERSION}}   — current Harness version (read from project.yml MARKETING_VERSION)
#   {{LASTMOD}}   — today's date in YYYY-MM-DD (UTC)

set -euo pipefail

# ---------- config ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHPAGES_DIR="$REPO_ROOT/.gh-pages-worktree"
SRC_DIR="$REPO_ROOT/site/landing"
PROJECT_YML="$REPO_ROOT/project.yml"
PY="${PYTHON:-python3}"

# Files this script owns on gh-pages root. Anything else stays untouched.
OWNED_ROOT_FILES=(
  index.html
  styles.css
  app.js
  llms.txt
  robots.txt
  sitemap.xml
  manifest.webmanifest
  favicon.png
  apple-touch-icon.png
)

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

need_src() {
  [[ -d "$SRC_DIR" ]] || die "missing $SRC_DIR"
  for f in index.html styles.css app.js llms.txt robots.txt sitemap.xml.tmpl manifest.webmanifest favicon.png apple-touch-icon.png; do
    [[ -e "$SRC_DIR/$f" ]] || die "missing required source file: $SRC_DIR/$f"
  done
  [[ -d "$SRC_DIR/assets" ]] || die "missing $SRC_DIR/assets/"
}

need_ghpages() {
  [[ -e "$GHPAGES_DIR/.git" ]] || die "no gh-pages worktree at $GHPAGES_DIR
  Run: git worktree add .gh-pages-worktree gh-pages"
}

# ---------- token resolvers ----------

# Pull MARKETING_VERSION from project.yml. xcodegen owns this; it's the source
# of truth for the in-development version.
resolve_version() {
  if [[ -f "$PROJECT_YML" ]]; then
    "$PY" -c '
import re, sys
src = open("'"$PROJECT_YML"'", "r", encoding="utf-8").read()
m = re.search(r"MARKETING_VERSION:\s*\"?([0-9][0-9.A-Za-z\-]*)\"?", src)
print(m.group(1) if m else "unreleased")
'
  else
    echo "unreleased"
  fi
}

# Apply {{TOKEN}} substitution: substitute_tokens VERSION LASTMOD SRC_FILE DEST_FILE
substitute_tokens() {
  local version="$1"
  local lastmod="$2"
  local src_file="$3"
  local dest_file="$4"
  VERSION="$version" LASTMOD="$lastmod" \
    SRC="$src_file" DEST="$dest_file" \
    "$PY" -c '
import os
with open(os.environ["SRC"], "r", encoding="utf-8") as fh:
    text = fh.read()
text = text.replace("{{VERSION}}", os.environ["VERSION"])
text = text.replace("{{LASTMOD}}", os.environ["LASTMOD"])
with open(os.environ["DEST"], "w", encoding="utf-8") as fh:
    fh.write(text)
'
}

# ---------- secret-scan (mirrors scripts/wiki.sh) ----------
hard_regex='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|BEGIN OPENSSH PRIVATE KEY)'

scan_hard_source() {
  local hits
  hits="$(grep -rInE --exclude-dir=.git --include='*.html' --include='*.css' --include='*.js' --include='*.txt' --include='*.xml' --include='*.json' --include='*.tmpl' --include='*.webmanifest' "$hard_regex" "$SRC_DIR" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "hard-pattern secret match in source — refusing to build."
  fi
}

scan_hard_rendered() {
  local hits=""
  for f in "${OWNED_ROOT_FILES[@]}"; do
    [[ -f "$GHPAGES_DIR/$f" ]] || continue
    case "$f" in
      *.png|*.ico|*.jpg|*.jpeg|*.webp) continue ;;
    esac
    local h
    h="$(grep -InE "$hard_regex" "$GHPAGES_DIR/$f" 2>/dev/null || true)"
    [[ -n "$h" ]] && hits="$hits$h"$'\n'
  done
  if [[ -d "$GHPAGES_DIR/assets" ]]; then
    local h
    h="$(grep -rInE --include='*.html' --include='*.css' --include='*.js' --include='*.txt' --include='*.xml' --include='*.json' --include='*.tmpl' "$hard_regex" "$GHPAGES_DIR/assets" 2>/dev/null || true)"
    [[ -n "$h" ]] && hits="$hits$h"$'\n'
  fi
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "hard-pattern secret match in rendered site — refusing to publish."
  fi
}

# ---------- commands ----------

cmd_check() {
  need_src
  scan_hard_source
  log "Source files OK ($(ls -1 "$SRC_DIR" | wc -l | tr -d ' ') entries; assets/: $(find "$SRC_DIR/assets" -type f | wc -l | tr -d ' ') files)"
}

cmd_build() {
  need_src
  need_ghpages
  scan_hard_source

  local version lastmod
  version="$(resolve_version)"
  lastmod="$(date -u +%Y-%m-%d)"

  log "Building (version=$version, lastmod=$lastmod)"

  for f in styles.css app.js llms.txt robots.txt manifest.webmanifest favicon.png apple-touch-icon.png; do
    cp "$SRC_DIR/$f" "$GHPAGES_DIR/$f"
  done

  substitute_tokens "$version" "$lastmod" "$SRC_DIR/index.html"        "$GHPAGES_DIR/index.html"
  substitute_tokens "$version" "$lastmod" "$SRC_DIR/sitemap.xml.tmpl"  "$GHPAGES_DIR/sitemap.xml"

  rm -rf "$GHPAGES_DIR/assets"
  cp -R "$SRC_DIR/assets" "$GHPAGES_DIR/assets"

  log "Built into $GHPAGES_DIR/"
}

cmd_preview() {
  cmd_build
  local port="${1:-8000}"
  log "Open: http://localhost:$port/"
  cmd_serve "$port"
}

cmd_serve() {
  need_ghpages
  local port="${1:-8000}"
  log "Serving $GHPAGES_DIR on http://localhost:$port/"
  (cd "$GHPAGES_DIR" && "$PY" -m http.server "$port")
}

cmd_publish() {
  need_src
  need_ghpages

  log "Validating source"
  scan_hard_source

  log "Building"
  cmd_build

  log "Secret-scanning rendered site"
  scan_hard_rendered

  log "Staging + committing gh-pages"
  (cd "$GHPAGES_DIR" && git add "${OWNED_ROOT_FILES[@]}" assets/)
  if (cd "$GHPAGES_DIR" && git diff --cached --quiet); then
    log "No changes to publish."
    return 0
  fi
  local msg
  msg="site: rebuild landing page at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (cd "$GHPAGES_DIR" && git commit -m "$msg")
  log "Pushing gh-pages"
  (cd "$GHPAGES_DIR" && git push origin gh-pages)
  log "Published. Verify at https://awizemann.github.io/harness/"
}

cmd_help() {
  sed -n '1,28p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- dispatch ----------
sub="${1:-help}"
shift || true
case "$sub" in
  check)    cmd_check   "$@" ;;
  build)    cmd_build   "$@" ;;
  preview)  cmd_preview "$@" ;;
  serve)    cmd_serve   "$@" ;;
  publish)  cmd_publish "$@" ;;
  help|--help|-h) cmd_help ;;
  *) die "unknown command: $sub  (try --help)" ;;
esac
