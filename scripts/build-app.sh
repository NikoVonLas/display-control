#!/bin/zsh

set -euo pipefail

readonly script_dir="${0:A:h}"
readonly project_dir="${script_dir:h}"
readonly build_root="${ACER_BUILD_ROOT:-${project_dir}/.build-release}"
readonly app_path="${project_dir}/dist/Acer Display Control.app"
readonly contents_path="${app_path}/Contents"

cd "$project_dir"

readonly sparkle_dir="$(./scripts/prepare-sparkle.sh)"
export CLANG_MODULE_CACHE_PATH="${build_root}/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
args=(--configuration release --build-system native --disable-sandbox --arch arm64
      --scratch-path "$build_root" -Xswiftc -DACER_UPDATES
      -Xswiftc -file-prefix-map -Xswiftc "$project_dir=."
      -Xcc "-ffile-prefix-map=$project_dir=."
      -Xswiftc -F -Xswiftc "$sparkle_dir" -Xlinker -F -Xlinker "$sparkle_dir"
      -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
swift build "${args[@]}"
readonly bin_path="$(swift build "${args[@]}" --show-bin-path)"

if [[ -d "$app_path" ]]; then
    /bin/rm -R "$app_path"
fi

/bin/mkdir -p "$contents_path/MacOS" "$contents_path/Frameworks" "$contents_path/Resources/bin" "${project_dir}/dist"
/usr/bin/install -m 0755 "$bin_path/AcerDisplayControl" "$contents_path/MacOS/AcerDisplayControl"
/usr/bin/install -m 0755 "$bin_path/acerctl" "$contents_path/Resources/bin/acerctl"
/usr/bin/install -m 0755 "$bin_path/acerctl" "${project_dir}/dist/acerctl"
/usr/bin/install -m 0644 "${project_dir}/Packaging/Info.plist" "$contents_path/Info.plist"
/usr/bin/install -m 0644 "${project_dir}/ThirdParty/m1ddc-LICENSE.txt" "$contents_path/Resources/m1ddc-LICENSE.txt"

/usr/bin/ditto --norsrc --noextattr "$sparkle_dir/Sparkle.framework" "$contents_path/Frameworks/Sparkle.framework"
/usr/bin/install -m 0644 "$sparkle_dir/LICENSE" "$contents_path/Resources/Sparkle-LICENSE.txt"
/usr/bin/strip -S "$contents_path/MacOS/AcerDisplayControl" "$contents_path/Resources/bin/acerctl"

# Accessibility grants are tied to the code signing requirement of the app.
# Prefer a unique local Apple Development identity for repeatable local builds.
identity="${ACER_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ {count++; hash=$2} END {if (count==1) print hash}')"
fi
if [[ -z "$identity" ]]; then
    echo "Сборка с временной подписью. Для сохранения разрешений задайте ACER_SIGN_IDENTITY." >&2
    identity="-"
fi
/usr/bin/codesign --force --sign "$identity" "$contents_path/Resources/bin/acerctl"
/usr/bin/codesign --force --sign "$identity" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo "Готово: $app_path"
echo "CLI: ${project_dir}/dist/acerctl"
