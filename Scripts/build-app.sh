#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
build_dir="${PAVLAK_BUILD_DIR:-$project_dir/.build}"
output_dir="${PAVLAK_OUTPUT_DIR:-$project_dir/Build}"
app_dir="$output_dir/Pavlek.app"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Support/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_dir/Support/Info.plist")"
archive_path="$output_dir/Pavlek-${app_version}-build${app_build}.zip"
staging_dir="$(mktemp -d /private/tmp/pavlek-app-build.XXXXXX)"
verification_dir="$(mktemp -d /private/tmp/pavlek-app-verify.XXXXXX)"
staged_app="$staging_dir/Pavlek.app"
staged_archive="$staging_dir/Pavlek-${app_version}-build${app_build}.zip"
trap 'rm -rf "$staging_dir" "$verification_dir"' EXIT

SDKROOT="$sdk_path" \
CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-module-cache" \
swift build --disable-sandbox --product Pavlek --scratch-path "$build_dir"

binary_path="$build_dir/arm64-apple-macosx/debug/Pavlek"
if [[ ! -f "$binary_path" ]]; then
    binary_path="$build_dir/debug/Pavlek"
fi

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_path" "$staged_app/Contents/MacOS/Pavlek"
cp "$project_dir/Support/Info.plist" "$staged_app/Contents/Info.plist"
for privacy_key in NSPhotoLibraryUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
    usage_description="$(/usr/libexec/PlistBuddy -c "Print :$privacy_key" "$staged_app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -z "$usage_description" ]]; then
        echo "Erro: $privacy_key ausente no bundle final." >&2
        exit 1
    fi
done
xattr -cr "$staged_app"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"
mkdir -p "$output_dir"
ditto -c -k --norsrc --keepParent "$staged_app" "$staged_archive"
ditto --norsrc "$staged_archive" "$archive_path"
ditto -x -k "$archive_path" "$verification_dir"
codesign --verify --deep --strict --verbose=2 "$verification_dir/Pavlek.app"
ditto --norsrc "$staged_app" "$app_dir"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --verbose=2 "$app_dir"
echo "$archive_path"
