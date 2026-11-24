#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
cache="$root/.build-sparkle"
mkdir -p "$cache"
work=$(mktemp -d "$cache/staging.XXXXXX")
trap 'rm -rf "$work"' EXIT
sha=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
bundle="$cache/$sha"
if [[ ! -d "$bundle" ]]; then
    archive=${SPARKLE_ARCHIVE:-"$work/Sparkle.tar.xz"}
    if [[ -z ${SPARKLE_ARCHIVE:-} ]]; then
        curl --fail --location --silent --show-error --retry 3 \
            https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$archive"
    fi
    [[ "$(shasum -a 256 < "$archive" | cut -d' ' -f1)" == "$sha" ]] || { echo 'Invalid Sparkle archive checksum' >&2; exit 1; }
    mkdir "$work/tools"
    tar -xf "$archive" -C "$work/tools"
    python3 -c 'import errno, os, sys
try: os.rename(*sys.argv[1:])
except OSError as e:
    if e.errno not in (errno.ENOTEMPTY, errno.EEXIST): raise' "$work/tools" "$bundle"
fi
print -r -- "$bundle"
