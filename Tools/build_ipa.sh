#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
build_dir="$project_dir/build"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    printf 'Usage: %s [output.ipa]\nDefault output: %s/FlickZhuyin-SideStore.ipa\n' "$0" "$build_dir"
    exit 0
fi
if (( $# > 1 )) || [[ $# == 1 && "$1" != *.ipa ]]; then
    printf 'Usage: %s [output.ipa]\n' "$0" >&2
    exit 2
fi

output="${1:-$build_dir/FlickZhuyin-SideStore.ipa}"
output_dir="$(dirname -- "$output")"
output_name="$(basename -- "$output")"

for resource in flickzhuyin.sqlite3 flickzhuyin.gram; do
    if [[ ! -s "$project_dir/Generated/$resource" ]]; then
        printf 'Missing Generated/%s. See DEVELOPMENT.md for build instructions.\n' "$resource" >&2
        exit 1
    fi
done

mkdir -p -- "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
output="$output_dir/$output_name"
if [[ -d "$output" ]]; then
    printf 'Output path is a directory: %s\n' "$output" >&2
    exit 1
fi
staging_dir="$(mktemp -d "$output_dir/.flickzhuyin-ipa.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT

derived_data="$build_dir/DerivedData"
xcodebuild \
    -project "$project_dir/FlickZhuyin.xcodeproj" \
    -scheme FlickZhuyin \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

mkdir "$staging_dir/Payload"
app="$staging_dir/Payload/FlickZhuyin.app"
keyboard="$app/PlugIns/FlickZhuyinKeyboard.appex"
ditto "$derived_data/Build/Products/Release-iphoneos/FlickZhuyin.app" "$app"

# Embed the App Group entitlements so SideStore can read them before re-signing.
codesign --force --sign - --entitlements "$project_dir/FlickZhuyinKeyboard/FlickZhuyinKeyboard.entitlements" "$keyboard"
codesign --force --sign - --entitlements "$project_dir/FlickZhuyinApp/FlickZhuyin.entitlements" "$app"
codesign --verify --deep --strict "$app"

(
    cd "$staging_dir"
    zip -q -r FlickZhuyin.ipa Payload
    unzip -tq FlickZhuyin.ipa
)

mv -f -- "$staging_dir/FlickZhuyin.ipa" "$output"
printf 'SideStore IPA: %s\n' "$output"
