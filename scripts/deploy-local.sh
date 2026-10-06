#!/bin/bash
set -euo pipefail

# Build and install a signed development copy without touching upstream macshot.
script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
  script_dir="$(cd -P "$(dirname "$script_path")" && pwd)"
  link_target="$(readlink "$script_path")"
  if [[ "$link_target" == /* ]]; then
    script_path="$link_target"
  else
    script_path="$script_dir/$link_target"
  fi
done
repo_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
build_dir="$repo_dir/build/local-dev"
app_name="Macshot Pro Dev"
scheme_name="macshot Dev"
bundle_id="com.drbaker.macshot.dev"
product_path="$build_dir/Build/Products/Release/$app_name.app"
signed_dir="$build_dir/signed"
app_path="$signed_dir/$app_name.app"
install_path="/Applications/$app_name.app"
legacy_install_path="/Applications/macshot Dev.app"
build_log="$build_dir/build.log"
build_only=false

if [[ "${1:-}" == "--build-only" && $# -eq 1 ]]; then
  build_only=true
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--build-only]" >&2
  exit 2
fi

identity="${MACSHOT_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
  echo "No Developer ID Application signing identity found. Set MACSHOT_SIGNING_IDENTITY to a stable signing identity." >&2
  exit 1
fi

mkdir -p "$build_dir"
echo "Building $app_name (log: $build_log)"
if ! xcodebuild \
  -project "$repo_dir/macshot.xcodeproj" \
  -scheme "$scheme_name" \
  -configuration Release \
  -derivedDataPath "$build_dir" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$(uname -m)" \
  CURRENT_PROJECT_VERSION="$(date -u +%s)" \
  build > "$build_log" 2>&1; then
  tail -80 "$build_log" >&2
  exit 1
fi

if [[ ! -d "$product_path" ]]; then
  echo "Build succeeded but $product_path is missing" >&2
  exit 1
fi

# Keep Xcode's unsigned product intact for the next incremental build.
mkdir -p "$signed_dir"
signed_stage_dir="$(mktemp -d "$signed_dir/.macshot-dev.XXXXXX")"
trap 'rm -rf "$signed_stage_dir"' EXIT
ditto "$product_path" "$signed_stage_dir/$app_name.app"
rm -rf "$app_path"
mv "$signed_stage_dir/$app_name.app" "$app_path"
rmdir "$signed_stage_dir"
trap - EXIT

# The local variant never starts Sparkle. Remove its upstream update metadata as
# another guard against replacing a development build with an upstream release.
python3 - "$app_path/Contents/Info.plist" "$bundle_id" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
plist = plistlib.loads(path.read_bytes())
if plist.get("CFBundleIdentifier") != sys.argv[2]:
    raise SystemExit(f"Unexpected bundle ID: {plist.get('CFBundleIdentifier')}")
for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableInstallerLauncherService"):
    plist.pop(key, None)
plist["SUEnableAutomaticChecks"] = False
path.write_bytes(plistlib.dumps(plist))
PY

sign() {
  codesign --force --options runtime --timestamp=none --sign "$identity" "$1"
}

# Sign Sparkle's nested services without the main app's sandbox entitlements.
while IFS= read -r -d '' item; do sign "$item"; done < <(find "$app_path/Contents" -name '*.xpc' -print0)
while IFS= read -r -d '' item; do sign "$item"; done < <(find "$app_path/Contents" -name '*.app' -print0)
autoupdate="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
if [[ -f "$autoupdate" ]]; then sign "$autoupdate"; fi
while IFS= read -r -d '' item; do sign "$item"; done < <(find "$app_path/Contents" -name '*.dylib' -print0)
while IFS= read -r -d '' item; do sign "$item"; done < <(find "$app_path/Contents" -name '*.framework' -print0)
codesign --force --options runtime --timestamp=none --sign "$identity" \
  --entitlements "$repo_dir/macshot/macshot.entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"

if $build_only; then
  echo "Signed build: $app_path"
  exit 0
fi

dev_is_running() {
  pgrep -x "$app_name" >/dev/null || pgrep -x 'macshot Dev' >/dev/null
}

if dev_is_running; then
  osascript -e "tell application id \"$bundle_id\" to quit"
  for ((attempt=0; attempt<30; attempt++)); do
    if ! dev_is_running; then break; fi
    sleep 1
  done
  if dev_is_running; then
    echo "$app_name did not quit. Close it and rerun this command." >&2
    exit 1
  fi
fi

stage_dir="$(mktemp -d /Applications/.macshot-dev.XXXXXX)"
install_verified=false
previous_saved=false
legacy_saved=false
new_installed=false
restore_previous() {
  if ! $install_verified; then
    if $new_installed; then
      rm -rf "$install_path"
    fi
    if $previous_saved; then
      mv "$stage_dir/previous.app" "$install_path"
    fi
    if $legacy_saved; then
      mv "$stage_dir/legacy.app" "$legacy_install_path"
    fi
  fi
  rm -rf "$stage_dir"
}
trap restore_previous EXIT
ditto "$app_path" "$stage_dir/new.app"
codesign --verify --deep --strict "$stage_dir/new.app"
if [[ -e "$install_path" ]]; then
  mv "$install_path" "$stage_dir/previous.app"
  previous_saved=true
fi
if [[ -e "$legacy_install_path" ]]; then
  legacy_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_install_path/Contents/Info.plist")"
  if [[ "$legacy_bundle_id" != "$bundle_id" ]]; then
    echo "Unexpected legacy app at $legacy_install_path; leaving it in place." >&2
    exit 1
  fi
  mv "$legacy_install_path" "$stage_dir/legacy.app"
  legacy_saved=true
fi
mv "$stage_dir/new.app" "$install_path"
new_installed=true
codesign --verify --deep --strict "$install_path"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_path/Contents/Info.plist")" == "$bundle_id" ]]
open -a "$install_path"
for ((attempt=0; attempt<10; attempt++)); do
  if pgrep -x "$app_name" >/dev/null; then break; fi
  sleep 1
done
if ! pgrep -x "$app_name" >/dev/null; then
  echo "Installed $install_path, but the app did not remain running. Check Console for launch errors." >&2
  exit 1
fi
install_verified=true
rm -rf "$stage_dir/previous.app" "$stage_dir/legacy.app"
trap - EXIT
rm -rf "$stage_dir"
echo "Installed and launched: $install_path"
echo "Bundle ID: $bundle_id"
echo "Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$install_path/Contents/Info.plist")"
