#!/bin/bash
set -euo pipefail

# Prepare signed release artifacts. Notarization and publication are separate steps.
usage() {
  cat <<'USAGE'
Usage: scripts/prepare-release.sh --version VERSION --build-number NUMBER \
  --sparkle-tools DIRECTORY --signing-identity 'Developer ID Application: NAME (TEAM)' \
  [--sparkle-account ACCOUNT]

Builds normal and offline universal apps for macOS 13, signs them using the
specified identity, and packages compressed HFS+ disk images. Sparkle's existing
Keychain key is read by account, without creating or exporting a private key.
Prepare from a clean checkout. Ignored build output is allowed.

Output: build/release/v<VERSION>-<NUMBER>/
USAGE
}
fail() { echo "Release preparation: $*" >&2; exit 1; }

version=""
build_number=""
sparkle_tools=""
signing_identity=""
sparkle_account="macshot-pro"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version|--build-number|--sparkle-tools|--signing-identity|--sparkle-account)
      [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"
      case "$1" in
        --version) version="$2" ;;
        --build-number) build_number="$2" ;;
        --sparkle-tools) sparkle_tools="$2" ;;
        --signing-identity) signing_identity="$2" ;;
        --sparkle-account) sparkle_account="$2" ;;
      esac
      shift 2 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || fail "--version must be a version such as 0.1.0 or 0.1.0-beta.1"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "--build-number must be a positive integer"
[[ -n "$sparkle_tools" && -n "$signing_identity" ]] || fail "--sparkle-tools and --signing-identity are required"
[[ "$(uname -s)" == Darwin ]] || fail "run this script on macOS with Xcode installed"
for tool in python3 git xcodebuild xcrun security codesign ditto hdiutil; do
  command -v "$tool" >/dev/null || fail "required tool is missing: $tool"
done
[[ -x "$sparkle_tools/generate_keys" ]] || fail "--sparkle-tools must contain executable generate_keys"
sparkle_tools="$(cd "$sparkle_tools" && pwd -P)"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
release_root="$repo_dir/build/release"
products_root="$repo_dir/build/release-products"
output_dir="$release_root/v$version-$build_number"
require_clean_checkout() {
  if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    fail "tracked or staged changes exist; commit the intended source before preparing a release"
  fi
  local untracked_files
  untracked_files="$(git -C "$repo_dir" ls-files --others --exclude-standard)" || fail "could not check for untracked files"
  [[ -z "$untracked_files" ]] || fail "untracked files exist; commit or remove them before preparing a release"
}
require_clean_checkout
head_sha="$(git -C "$repo_dir" rev-parse HEAD)"

# Resolve the full identity to one certificate, so codesign cannot choose a partial match.
certificate_sha="$(python3 - "$signing_identity" <<'PY'
import re
import subprocess
import sys

identity = sys.argv[1]
if not re.fullmatch(r"Developer ID Application: .+ \([A-Z0-9]{10}\)", identity):
    raise SystemExit("Supply the full Developer ID Application identity, including its team ID")
result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], check=True, capture_output=True, text=True)
matches = [sha for sha, name in re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "([^"]+)"', result.stdout, re.MULTILINE) if name == identity]
if len(matches) != 1:
    raise SystemExit(f"Expected one valid certificate for {identity!r}; found {len(matches)}")
print(matches[0])
PY
)"
if ! public_key="$("$sparkle_tools/generate_keys" --account "$sparkle_account" -p)"; then
  fail "could not read the existing Sparkle public key for account '$sparkle_account' from Keychain"
fi
python3 - "$public_key" <<'PY'
import base64
import binascii
import sys

try:
    key = base64.b64decode(sys.argv[1], validate=True)
except (binascii.Error, ValueError):
    raise SystemExit("The Sparkle public key must be base64 encoded")
if len(key) != 32 or base64.b64encode(key).decode() != sys.argv[1]:
    raise SystemExit("The Sparkle public key must be a canonical 32-byte Ed25519 public key")
PY

mkdir -p "$release_root" "$products_root"
[[ ! -L "$output_dir" ]] || fail "refusing to replace a symlink at $output_dir"
if [[ -e "$output_dir" ]]; then
  python3 - "$output_dir/manifest.json" "$version" "$build_number" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    manifest = json.loads(path.read_text())
except (OSError, ValueError):
    raise SystemExit(f"Refusing to replace a directory without a release manifest: {path.parent}")
if (manifest.get("generatedBy"), manifest.get("version"), manifest.get("buildNumber")) != ("scripts/prepare-release.sh", sys.argv[2], sys.argv[3]):
    raise SystemExit(f"Refusing to replace an unrelated release directory: {path.parent}")
PY
fi
lock_dir="$products_root/.prepare-release.lock"
mkdir "$lock_dir" 2>/dev/null || fail "another preparation may be active; check $lock_dir before removing a stale lock"
stage_dir=""
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$stage_dir" ]]; then
    if [[ -e "$stage_dir/previous" && ! -e "$output_dir" ]]; then
      mv "$stage_dir/previous" "$output_dir" || echo "Restore the previous release from $stage_dir/previous" >&2
    fi
    # Keep the previous output if restoring it failed.
    [[ ! -e "$stage_dir/previous" || -e "$output_dir" ]] && rm -rf "$stage_dir"
  fi
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "$$" > "$lock_dir/pid"
stage_dir="$(mktemp -d "$release_root/.prepare-v$version-$build_number.XXXXXX")"
mkdir "$stage_dir/artifacts"

build_variant() {
  local variant="$1" name="$2" bundle_id="$3" feed="$4"
  local derived="$products_root/$variant"
  local log="$derived/build.log"
  local conditions='$(inherited)'
  [[ "$variant" != offline ]] || conditions='$(inherited) OFFLINE'
  mkdir -p "$derived"
  local args=(
    -project "$repo_dir/macshot.xcodeproj" -scheme macshot -configuration Release
    -destination 'generic/platform=macOS' -derivedDataPath "$derived"
    -clonedSourcePackagesDirPath "$products_root/packages"
    -onlyUsePackageVersionsFromResolvedFile
    CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=13.0
    "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build_number"
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions"
    "MACSHOT_PRODUCT_NAME=$name" "MACSHOT_BUNDLE_IDENTIFIER=$bundle_id"
    "INFOPLIST_KEY_CFBundleDisplayName=$name" "INFOPLIST_KEY_CFBundleName=$name"
    "MACSHOT_UPDATE_FEED_URL=$feed"
  )
  echo "Building $name. Log: $log"
  if ! xcodebuild "${args[@]}" -resolvePackageDependencies > "$log" 2>&1; then
    tail -80 "$log" >&2
    fail "package resolution failed for $name; see $log"
  fi
  if ! xcodebuild "${args[@]}" build >> "$log" 2>&1; then
    tail -80 "$log" >&2
    fail "build failed for $name; see $log"
  fi
  local product="$derived/Build/Products/Release/$name.app"
  [[ -d "$product" ]] || fail "build succeeded but the app is missing: $product"
  # Patch and sign a copy, preserving Xcode's unsigned product for incremental builds.
  ditto "$product" "$stage_dir/artifacts/$name.app"
}
build_variant normal 'Macshot Pro' com.drbaker.macshot.pro https://raw.githubusercontent.com/dr-baker/macshot/main/appcast.xml
build_variant offline 'Macshot Pro Offline' com.drbaker.macshot.pro.offline https://raw.githubusercontent.com/dr-baker/macshot/main/appcast-offline.xml
[[ "$(git -C "$repo_dir" rev-parse HEAD)" == "$head_sha" ]] || fail "HEAD changed during the build; rerun preparation from the intended commit"
require_clean_checkout

python3 - "$repo_dir" "$stage_dir" "$output_dir" "$version" "$build_number" "$public_key" "$signing_identity" "$certificate_sha" "$head_sha" <<'PY'
import copy
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

repo, stage, output = map(Path, sys.argv[1:4])
version, build, public_key, identity, certificate_sha, head_sha = sys.argv[4:]
artifacts = stage / "artifacts"
team_id = identity.rsplit("(", 1)[1][:-1]
lookup = "com.apple.security.temporary-exception.mach-lookup.global-name"
notices = [repo / "LICENSE", repo / "NOTICE.md", *[repo / "ThirdPartyLicenses" / name for name in (
    "PermissionFlow-LICENSE", "Sparkle-LICENSE", "Swift-WebP-LICENSE", "libwebp-LICENSE",
)]]
variants = (
    ("normal", "Macshot Pro", "com.drbaker.macshot.pro", "appcast.xml", "Macshot-Pro.dmg"),
    ("offline", "Macshot Pro Offline", "com.drbaker.macshot.pro.offline", "appcast-offline.xml", "Macshot-Pro-Offline.dmg"),
)

def run(args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True)
    if result.returncode:
        raise SystemExit(f"{args[0]} failed for {args[-1]}:\n{result.stderr.decode(errors='replace')}")
    return result

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def sign(path, entitlements=None, runtime=True):
    print(f"Signing {path.relative_to(stage)}", flush=True)
    args = ["codesign", "--force", "--timestamp", "--sign", certificate_sha]
    if runtime:
        args += ["--options", "runtime"]
    if entitlements:
        args += ["--entitlements", entitlements]
    run([*args, path])

def signed_entitlements(path):
    data = run(["codesign", "--display", "--entitlements", "-", "--xml", path]).stdout
    return plistlib.loads(data) if data.strip() else {}

def verify_identity(path, runtime=True):
    details = run(["codesign", "--display", "--verbose=4", path]).stderr.decode()
    require(f"Authority={identity}\n" in details, f"Unexpected signing identity: {path}")
    require(f"TeamIdentifier={team_id}\n" in details, f"Unexpected signing team: {path}")
    require(re.search(r"^Timestamp=.+", details, re.MULTILINE), f"Missing secure timestamp: {path}")
    if runtime:
        require(re.search(r"flags=.*\([^\n]*\bruntime\b", details), f"Missing Hardened Runtime: {path}")
        require(not signed_entitlements(path).get("com.apple.security.get-task-allow", False), f"Debug entitlement in release: {path}")

def universal_executable(path):
    archs = run(["xcrun", "lipo", "-archs", path]).stdout.decode().split()
    require(set(archs) == {"arm64", "x86_64"}, f"Expected arm64 and x86_64 executable, got {archs}: {path}")
    for arch in archs:
        details = run(["xcrun", "vtool", "-arch", arch, "-show-build", path]).stdout.decode()
        minimum = re.findall(r"^\s*minos\s+([0-9.]+)\s*$", details, re.MULTILINE)
        require(minimum == ["13.0"], f"Expected macOS 13.0 Mach-O target for {arch}: {path}")
    return sorted(archs)

normal_entitlements = plistlib.loads((repo / "macshot/macshot.entitlements").read_bytes())
normal_lookups = ["com.apple.axserver", "com.drbaker.macshot.pro-spks", "com.drbaker.macshot.pro-spki"]
require(sorted(normal_entitlements.get(lookup, [])) == sorted(normal_lookups), "Normal entitlements must contain exactly the fork's Sparkle services and Accessibility lookup")
require("com.apple.axserver" in normal_entitlements.get("com.apple.security.temporary-exception.mach-lookup.local-name", []), "Missing local Accessibility lookup")
require(normal_entitlements.get("com.apple.security.app-sandbox") is True, "The release app must retain its sandbox")
require(not normal_entitlements.get("com.apple.security.get-task-allow", False), "Source entitlements permit debugging")
manifest_artifacts = []
for variant, name, bundle_id, feed_name, dmg_name in variants:
    app = artifacts / f"{name}.app"
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    expected = {
        "CFBundleIdentifier": bundle_id, "CFBundleDisplayName": name,
        "CFBundleName": name, "CFBundleExecutable": name,
        "LSMinimumSystemVersion": "13.0", "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }
    for key, value in expected.items():
        require(info.get(key) == value, f"{name}: expected {key}={value!r}, got {info.get(key)!r}")
    for source in notices:
        bundled = app / "Contents/Resources" / source.name
        require(bundled.is_file() and bundled.read_bytes() == source.read_bytes(), f"Missing or changed license notice: {bundled}")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    archs = universal_executable(executable)
    feed_url = f"https://raw.githubusercontent.com/dr-baker/macshot/main/{feed_name}"
    info.update(SUPublicEDKey=public_key, SUFeedURL=feed_url, SUEnableAutomaticChecks=True)
    if variant == "offline":
        info["CFBundleURLTypes"] = [item for item in info.get("CFBundleURLTypes", [])
            if item.get("CFBundleURLName") != "Google OAuth" and not any(
                scheme.startswith("com.googleusercontent.apps.") for scheme in item.get("CFBundleURLSchemes", []))]
    info_path.write_bytes(plistlib.dumps(info))
    entitlements = copy.deepcopy(normal_entitlements)
    entitlements[lookup] = [name.replace("com.drbaker.macshot.pro", bundle_id, 1) if name != "com.apple.axserver" else name for name in normal_lookups]
    entitlement_path = artifacts / f"{variant}.entitlements"
    entitlement_path.write_bytes(plistlib.dumps(entitlements))

    contents = app / "Contents"
    def nested(pattern):
        return sorted((path for path in contents.rglob(pattern) if not path.is_symlink()), key=lambda path: (-len(path.parts), str(path)))
    xpcs, helpers, dylibs, frameworks = [nested(pattern) for pattern in ("*.xpc", "*.app", "*.dylib", "*.framework")]
    sparkle = contents / "Frameworks/Sparkle.framework"
    autoupdate = sparkle / "Versions/B/Autoupdate"
    require(sparkle.is_dir() and autoupdate.is_file(), f"Missing Sparkle framework or Autoupdate: {app}")
    require({"Installer.xpc", "Downloader.xpc"}.issubset({path.name for path in xpcs}), f"Missing Sparkle XPC services: {app}")
    require("Updater.app" in {path.name for path in helpers}, f"Missing Sparkle updater helper: {app}")
    # Sparkle services and helpers receive no app sandbox entitlements.
    targets = [*xpcs, *helpers, autoupdate, *dylibs, *frameworks]
    for path in targets:
        sign(path)
    sign(app, entitlement_path)
    run(["codesign", "--verify", "--deep", "--strict", app])
    for path in [*targets, app]:
        verify_identity(path)
    require(signed_entitlements(app) == entitlements, f"Signed app entitlements differ from the release entitlements: {app}")
    for path in xpcs:
        require("com.apple.security.app-sandbox" not in signed_entitlements(path), f"Sparkle XPC has sandbox entitlements: {path}")

    disk_root = stage / f"dmg-{variant}"
    disk_root.mkdir()
    run(["ditto", app, disk_root / app.name])
    (disk_root / "Applications").symlink_to("/Applications")
    for source in [repo / "README.md", *notices[:2]]:
        shutil.copy2(source, disk_root / source.name)
    shutil.copytree(repo / "ThirdPartyLicenses", disk_root / "ThirdPartyLicenses")
    dmg = artifacts / dmg_name
    print(f"Packaging {dmg_name}", flush=True)
    run(["hdiutil", "create", "-quiet", "-volname", name, "-srcfolder", disk_root,
         "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", dmg])
    sign(dmg, runtime=False)
    run(["codesign", "--verify", "--strict", dmg])
    verify_identity(dmg, runtime=False)
    run(["hdiutil", "verify", "-quiet", dmg])
    manifest_artifacts.append({
        "variant": variant, "productName": name, "bundleIdentifier": bundle_id,
        "app": str(output / app.name), "executable": str(output / app.name / executable.relative_to(app)),
        "dmg": str(output / dmg.name), "sha256": hashlib.sha256(dmg.read_bytes()).hexdigest(),
        "size": dmg.stat().st_size, "architectures": archs, "feedURL": feed_url,
        "entitlementsFile": str(output / entitlement_path.name), "entitlements": entitlements,
    })

(artifacts / "sparkle-public-key.txt").write_text(public_key + "\n")
manifest = {
    "schemaVersion": 1, "generatedBy": "scripts/prepare-release.sh", "phase": "prepared",
    "version": version, "buildNumber": build, "headSha": head_sha,
    "signingIdentity": identity, "signingCertificateSHA1": certificate_sha,
    "sparklePublicKey": public_key, "minimumSystemVersion": "13.0",
    "artifacts": manifest_artifacts,
    "notices": {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest() for path in notices},
}
(artifacts / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

[[ "$(git -C "$repo_dir" rev-parse HEAD)" == "$head_sha" ]] || fail "HEAD changed during signing or packaging; rerun preparation from the intended commit"
require_clean_checkout
# Publish the completed set locally, restoring the earlier set if the rename fails.
if [[ -e "$output_dir" ]]; then mv "$output_dir" "$stage_dir/previous"; fi
mv "$stage_dir/artifacts" "$output_dir"
echo "Prepared release: $output_dir"
echo "Notarize and staple both DMGs before creating Sparkle signatures or publishing."
