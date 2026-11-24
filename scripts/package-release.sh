#!/bin/zsh
# Package the public app and sign both Sparkle artifacts with the project Keychain item.
set -euo pipefail
cd "${0:A:h:h}"
plist=Packaging/Info.plist
version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
build=$(plutil -extract CFBundleVersion raw -o - "$plist")
account=$(plutil -extract CFBundleIdentifier raw -o - "$plist")
feed_url=$(plutil -extract SUFeedURL raw -o - "$plist")
tools=$(./scripts/prepare-sparkle.sh)
key=$("$tools/bin/generate_keys" --account "$account" -p)
[[ "$key" == "$(plutil -extract SUPublicEDKey raw -o - "$plist")" ]] || { echo 'Sparkle key mismatch' >&2; exit 1; }
ACER_SIGN_IDENTITY=- ./scripts/build-app.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/image" "$work/feed"
ditto --norsrc --noextattr 'dist/Display Control.app' "$work/image/Display Control.app"
ln -s /Applications "$work/image/Applications"
name="Display-Control-$version.dmg"
dmg="$work/feed/$name"
feed="$work/feed/appcast.xml"
hdiutil create -fs HFS+ -volname 'Display Control' -srcfolder "$work/image" -format UDZO "$dmg"
hdiutil verify "$dmg"
prefix="${feed_url%/latest/download/appcast.xml}/download/v$version/"
"$tools/bin/generate_appcast" --account "$account" --maximum-deltas 0 --download-url-prefix "$prefix" "$work/feed"
signature=$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$feed")
[[ "$(xmllint --xpath 'string(//enclosure/@url)' "$feed")" == "$prefix$name" ]]
[[ "$(xmllint --xpath 'string(//item/*[local-name()="version"])' "$feed")" == "$build" ]]
"$tools/bin/sign_update" --account "$account" --verify "$feed"
"$tools/bin/sign_update" --account "$account" --verify "$dmg" "$signature"
mkdir -p "dist/v$version"
cp "$dmg" "$feed" "dist/v$version/"
