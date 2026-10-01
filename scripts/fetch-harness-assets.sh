#!/usr/bin/env bash
#
# Fetch the built worker-preview assets and place them where the app bundles them.
#
# The assets are the harness itself: the Web Worker bundle, the packed VFS image,
# and the UI. They come from a build of the upstream repository; this script only
# retrieves them, so the app repository stays small and the harness stays
# reproducible from its own source.
#
# Usage:
#   ./scripts/fetch-harness-assets.sh                    # from the published build
#   ./scripts/fetch-harness-assets.sh --from-dir DIR     # from a local dist/
#   ./scripts/fetch-harness-assets.sh --from-zip FILE    # from a downloaded zip
#
# Default source is the GitHub Pages deployment of the pinned preview build.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="Apps/DeepSeekHarnessStandalone/Resources/HarnessAssets"
BASE_URL="${HARNESS_ASSETS_URL:-https://hicongcn.github.io/deepseek-harness}"
SOURCE_KIND="remote"
SOURCE_VALUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-dir) SOURCE_KIND="dir"; SOURCE_VALUE="${2:-}"; shift 2 ;;
    --from-zip) SOURCE_KIND="zip"; SOURCE_VALUE="${2:-}"; shift 2 ;;
    --url) BASE_URL="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "==> preparing $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

case "$SOURCE_KIND" in
  dir)
    if [[ ! -d "$SOURCE_VALUE" ]]; then
      echo "not a directory: $SOURCE_VALUE" >&2
      exit 1
    fi
    echo "==> copying from $SOURCE_VALUE"
    cp -R "$SOURCE_VALUE"/. "$DEST"/
    ;;

  zip)
    if [[ ! -f "$SOURCE_VALUE" ]]; then
      echo "not a file: $SOURCE_VALUE" >&2
      exit 1
    fi
    echo "==> extracting $SOURCE_VALUE"
    unzip -q "$SOURCE_VALUE" -d "$DEST"
    ;;

  remote)
    # The page is served from a subpath, so every asset URL is relative; the
    # same relative layout is what the bundled copy must reproduce.
    echo "==> downloading the page and its manifests"
    for file in index.html preview.html manifest.webmanifest favicon.svg favicon-dark.svg; do
      curl -fsSL "$BASE_URL/$file" -o "$DEST/$file" || echo "   (skipped $file)"
    done

    echo "==> downloading the preview surface"
    mkdir -p "$DEST/preview"
    # Names are content-hashed, so discover them from the served files rather
    # than pinning a hash that changes on every upstream build.
    BOOTSTRAP=$(grep -oE 'preview/bootstrap-[A-Za-z0-9_-]+\.js' "$DEST/preview.html" | head -1 || true)
    if [[ -z "${BOOTSTRAP:-}" ]]; then
      echo "   ERROR: preview.html references no bootstrap module" >&2
      exit 1
    fi
    echo "    $BOOTSTRAP"
    curl -fsSL "$BASE_URL/$BOOTSTRAP" -o "$DEST/$BOOTSTRAP"

    # The worker is referenced from inside the bootstrap module, not the HTML, so
    # it can only be discovered after that module is downloaded.
    WORKER=$(grep -oE 'worker-[A-Za-z0-9_-]+\.js' "$DEST/$BOOTSTRAP" | head -1 || true)
    if [[ -z "${WORKER:-}" ]]; then
      echo "   ERROR: the bootstrap module references no worker bundle" >&2
      exit 1
    fi
    WORKER="preview/$WORKER"
    echo "    $WORKER"
    curl -fsSL "$BASE_URL/$WORKER" -o "$DEST/$WORKER"

    for asset in preview/vfs-image.tar.gz preview/fixtures.json; do
      echo "    $asset"
      curl -fsSL "$BASE_URL/$asset" -o "$DEST/$asset"
    done

    # The fixtures manifest names overlay archives that supply the sample
    # workspace. They are not referenced from any page, so they must be read out
    # of the manifest; skipping them leaves the showcase source broken.
    OVERLAY_COUNT=$(python3 - "$DEST/preview/fixtures.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    manifest = json.load(handle)
paths = []
for fixture in manifest.get('fixtures', []):
    paths.extend(fixture.get('overlays', []))
print('\n'.join(paths))
PY
)
    while read -r overlay; do
      [[ -z "$overlay" ]] && continue
      mkdir -p "$DEST/preview/$(dirname "$overlay")"
      echo "    preview/$overlay"
      curl -fsSL "$BASE_URL/preview/$overlay" -o "$DEST/preview/$overlay"
    done <<< "$OVERLAY_COUNT"

    echo "==> downloading the UI assets"
    mkdir -p "$DEST/assets"
    # Asset names are hashed too, so read them out of the pages and out of the
    # bootstrap module, which pulls in the shell entry.
    grep -ohE '(assets|preview)/[A-Za-z0-9._-]+\.(js|css)' \
      "$DEST/preview.html" "$DEST/index.html" "$DEST/$BOOTSTRAP" 2>/dev/null \
      | sort -u > /tmp/dsh-assets-list.txt
    while read -r asset; do
      [[ -z "$asset" ]] && continue
      mkdir -p "$DEST/$(dirname "$asset")"
      echo "    $asset"
      curl -fsSL "$BASE_URL/$asset" -o "$DEST/$asset"
    done < /tmp/dsh-assets-list.txt
    ;;
esac

# The page must open the harness entry, not the plain web shell, since the shell
# expects a Node host and would render nothing useful.
if [[ -f "$DEST/preview.html" ]]; then
  cp "$DEST/preview.html" "$DEST/index.html"
fi

echo
echo "==> verifying the essential artifacts"
fail=0

check() {
  local label="$1"; shift
  if eval "$@" >/dev/null 2>&1; then
    printf '    OK    %s\n' "$label"
  else
    printf '    MISS  %s\n' "$label"
    fail=1
  fi
}

check "index.html" "[[ -f \"\$DEST/index.html\" ]]"
check "preview.html" "[[ -f \"\$DEST/preview.html\" ]]"
check "preview/bootstrap-*.js" "ls \"\$DEST\"/preview/bootstrap-*.js"
check "preview/worker-*.js" "ls \"\$DEST\"/preview/worker-*.js"
check "preview/vfs-image.tar.gz" "[[ -f \"\$DEST/preview/vfs-image.tar.gz\" ]]"
check "preview/fixtures.json" "[[ -f \"\$DEST/preview/fixtures.json\" ]]"
check "assets/index-*.js" "ls \"\$DEST\"/assets/index-*.js"

# Every overlay the manifest promises must be present, otherwise the showcase
# source fails at boot with a fetch error.
if [[ -f "$DEST/preview/fixtures.json" ]]; then
  while read -r overlay; do
    [[ -z "$overlay" ]] && continue
    check "preview/$overlay" "[[ -f \"\$DEST/preview/$overlay\" ]]"
  done < <(python3 - "$DEST/preview/fixtures.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    manifest = json.load(handle)
for fixture in manifest.get('fixtures', []):
    for overlay in fixture.get('overlays', []):
        print(overlay)
PY
)
fi

echo
# The page's own entry points reference the harness by relative path; a missing
# worker or image is a silent boot failure on device, so fail the build here.
echo "    total: $(du -sh "$DEST" | cut -f1)"
if [[ "$fail" -ne 0 ]]; then
  echo "==> FAILED: required assets are missing" >&2
  exit 1
fi
echo "==> done"
