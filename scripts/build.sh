#!/usr/bin/env bash
#
# Build, test, and package the DeepSeek Harness iOS client.
#
# The protocol layer (DSHKit) has no iOS-only dependency, so it builds and
# self-tests on macOS with only the command line tools installed — no Xcode
# required. The SwiftUI app and the .ipa need Xcode; this script detects that
# and skips cleanly instead of failing halfway.
#
# Usage:
#   ./scripts/build.sh              build DSHKit and run the offline self-test
#   ./scripts/build.sh --live URL   also run live checks against a dsh web host
#   ./scripts/build.sh --ios        generate the project and build the app
#   ./scripts/build.sh --archive    archive a Release build (needs a team)
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
MODE="kit"
LIVE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) MODE="live"; LIVE_URL="${2:-}"; shift 2 ;;
    --ios) MODE="ios"; shift ;;
    --archive) MODE="archive"; shift ;;
    --host) LIVE_URL="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
have_xcode() { xcodebuild -version >/dev/null 2>&1; }

bold "1/4  Build DSHKit"
swift build || exit 1

bold "2/4  Offline self-test (protocol, envelopes, timeline folding)"
if [[ -n "$LIVE_URL" ]]; then
  DSH_LIVE_URL="$LIVE_URL" swift run dshkit-selftest || exit 1
else
  swift run dshkit-selftest || exit 1
fi

if [[ "$MODE" == "kit" || "$MODE" == "live" ]]; then
  bold "Done"
  cat <<'EOF'
Protocol layer verified.

To run the app:
  1. On your computer:      dsh web
  2. Generate the project:  xcodegen generate
  3. Open DeepSeekHarness.xcodeproj, pick an iOS 17+ simulator or device,
     and run. Paste the URL printed by `dsh web` into the connect screen.

Live re-verification against a running host:
  DSH_LIVE_URL="$(dsh web prints this)" ./scripts/build.sh --live
EOF
  exit 0
fi

bold "3/4  Generate the Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required for the iOS app: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate || exit 1

if ! have_xcode; then
  echo
  echo "Xcode is not installed (xcode-select points at the command line tools)."
  echo "The project is generated and the protocol layer is verified, but the app"
  echo "cannot be compiled here. Install Xcode, then re-run: $0 --ios"
  xcode-select -p
  exit 0
fi

if [[ "$MODE" == "archive" ]]; then
  bold "4/4  Archive (Release)"
  xcodebuild -project DeepSeekHarness.xcodeproj \
             -scheme DeepSeekHarness \
             -configuration Release \
             -destination 'generic/platform=iOS' \
             -archivePath "$ROOT/build/DeepSeekHarness.xcarchive" \
             archive
else
  bold "4/4  Build the iOS app for the simulator"
  xcodebuild -project DeepSeekHarness.xcodeproj \
             -scheme DeepSeekHarness \
             -configuration Debug \
             -destination 'generic/platform=iOS Simulator' \
             build
fi
