#!/usr/bin/env bash
# Local SwiftPM-only release build: assembles and signs an app bundle without Xcode, installs it
# at a fixed path and points the CLI link at the SwiftPM release binary. See docs/local-build.md.
# This is not the upstream release pipeline (build-release.sh).
set -e # Exit if one of commands exit with non-zero exit code
set -u # Treat unset variables and parameters other than the special parameters ‘@’ or ‘*’ as an error
set -o pipefail # Any command failed in the pipe fails the whole pipe

script_path="${BASH_SOURCE[0]}"
[[ "$script_path" == /* ]] || script_path="$PWD/$script_path"
repo_root="$(CDPATH= cd -P -- "$(dirname -- "$script_path")" && pwd -P)"
cd "$repo_root"
source ./script/setup.sh

app_path="$HOME/Applications/AeroSpace.app"
cli_link="$HOME/.local/bin/aerospace"
release_dir="$repo_root/.build/local-release"
bundle_id="bobko.aerospace"
codesign_hint="aerospace-codesign-certificate"
codesign_identity="$codesign_hint"
fail() {
    echo "$*" > /dev/stderr
    exit 1
}
while test $# -gt 0; do
    case $1 in
        --codesign-identity) test $# -ge 2 || fail "--codesign-identity needs a value"; codesign_identity="$2"; shift 2 ;;
        *) fail "Unknown option $1" ;;
    esac
done

if [[ "$repo_root" == *[[:space:]]* || ",${TMPDIR:-}," == *",${repo_root%/}/,"* ]]; then
    fail "Repo path '$repo_root' breaks generate.sh globs or SwiftPM (TMPDIR). Move the repo."
fi
for file in resources/AeroSpace.entitlements docs/config-examples/default-config.toml \
    resources/Assets.xcassets/AppIcon.appiconset/icon.png; do
    test -f "$file" || fail "Missing build resource: $file"
done
if [[ -e "$cli_link" || -L "$cli_link" ]]; then
    test -L "$cli_link" || fail "$cli_link is not a symlink. Refusing to replace it."
fi

# CFBundle version comes from the latest tag. MARKETING_VERSION in xcode/project.yml is the
# XCODEGEN_AEROSPACE_VERSION template variable, so it cannot be read as a literal.
build_version="$(git describe --tags --abbrev=0 2> /dev/null | sed -E 's/^v//; s/-.*//' || true)"
[[ "$build_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || build_version="0.0.0-SNAPSHOT"

# --- code signing identity -------------------------------------------------
# `find-identity -v` reports a self-signed certificate as untrusted, so only the codesigning
# policy is consulted. A name shared by several certificates must be narrowed by SHA-1.
code_sign_fingerprint() {
    local name="$1" matches
    matches="$(security find-identity -p codesigning 2> /dev/null \
        | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) *"(.*)"$/\1\t\2/p' \
        | awk -F'\t' -v name="$name" '$2 == name')"
    test -n "$matches" || { echo "No code signing certificate named '$name' is installed." > /dev/stderr; return 1; }
    if test "$(grep -c . <<< "$matches")" -gt 1; then
        echo "Several code signing certificates are named '$name'. Pick one with --codesign-identity <SHA-1>:" > /dev/stderr
        sed -E 's/\t/ /; s/^/    /' <<< "$matches" > /dev/stderr
        return 1
    fi
    cut -f1 <<< "$matches"
}
if [[ "$codesign_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    codesign_identity="$(tr 'a-f' 'A-F' <<< "$codesign_identity")"
    [[ "$(security find-identity -p codesigning 2> /dev/null || true)" == *"$codesign_identity"* ]] \
        || fail "No code signing certificate with SHA-1 $codesign_identity is installed."
elif ! codesign_identity="$(code_sign_fingerprint "$codesign_identity")"; then
    echo "Create it once in Keychain Access (Certificate Assistant > Create a Certificate, Self Signed Root," > /dev/stderr
    echo "Code Signing, name '$codesign_hint'; see docs/local-build.md), or pass --codesign-identity <SHA-1>." > /dev/stderr
    exit 1
fi
echo "Signing with certificate $codesign_identity"

# --- generated sources -----------------------------------------------------
# Build metadata only: restored byte for byte on exit, including on failure. --ignore-cmd-help
# keeps the command help alone, which is edited by hand.
generated_files=(
    Sources/Common/versionGenerated.swift
    Sources/Common/gitHashGenerated.swift
    Sources/Cli/subcommandDescriptionsGenerated.swift
)
backup_dir="$release_dir/generated-backup"
mkdir -p .build "$release_dir"
rm -rf "$backup_dir"
mkdir "$backup_dir"
for file in "${generated_files[@]}"; do
    if test -f "$file"; then
        cp -p "$file" "$backup_dir/${file//\//__}"
    fi
done
stage=""
cleanup() {
    set +e
    local file backup
    # Only exact backup bytes come back, so a pre-existing working-tree edit survives
    for file in "${generated_files[@]}"; do
        backup="$backup_dir/${file//\//__}"
        if test -f "$backup"; then
            cmp -s "$backup" "$file" || cp -p "$backup" "$file"
        else
            rm -f "$file"
        fi
    done
    rm -rf "$backup_dir"
    # Interrupted mid-swap: put the previous install back before dropping staging
    if [[ "$stage" == "$HOME/Applications/.AeroSpace.app.stage."* && -d "$stage" ]]; then
        if [[ ! -e "$app_path" && -e "$stage/old" ]]; then
            mv "$stage/old" "$app_path" || true
        fi
        if [[ ! -e "$stage/old" || -e "$app_path" ]]; then
            rm -rf "$stage"
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- generate and build ----------------------------------------------------
./generate.sh --ignore-xcodeproj --ignore-cmd-help --build-version "$build_version" --generate-git-hash \
    > "$release_dir/generate.log" 2>&1 || {
    cat "$release_dir/generate.log" > /dev/stderr
    fail "generate.sh failed. Full log: $release_dir/generate.log"
}
swift build -c release -Xswiftc -warnings-as-errors > "$release_dir/swift-build.log" 2>&1 || {
    cat "$release_dir/swift-build.log" > /dev/stderr
    fail "swift build failed. Full log: $release_dir/swift-build.log"
}
bin_path="$(swift build -c release --show-bin-path | tail -1)"
cli_bin="$bin_path/aerospace"
app_bin="$bin_path/AeroSpaceApp"
test -x "$cli_bin" && test -x "$app_bin" || fail "SwiftPM did not produce the release products"
echo "Built $build_version from $(git describe --tags --always 2> /dev/null || echo unknown)"

# --- assemble and sign -----------------------------------------------------
# The bundle is assembled beside its target so the final swap is a rename on one filesystem.
require_user_dir() {
    local dir="$1"
    if test -L "$dir"; then
        fail "$dir is a symlink. Refusing to use it."
    fi
    if ! test -d "$dir"; then
        mkdir -p "$dir"
        test -L "$dir" && fail "$dir is a symlink. Refusing to use it."
    fi
    test "$(stat -f %u "$dir")" = "$(id -u)" || fail "$dir is not owned by the current user"
}
require_user_dir "$HOME/Applications"
require_user_dir "$HOME/.local"
require_user_dir "$HOME/.local/bin"

stage="$(mktemp -d "$HOME/Applications/.AeroSpace.app.stage.XXXXXX")"
app="$stage/AeroSpace.app"
iconset="$stage/AppIcon.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
cp "$app_bin" "$app/Contents/MacOS/AeroSpace"
strip -rSTx "$app/Contents/MacOS/AeroSpace"
cp docs/config-examples/default-config.toml "$app/Contents/Resources/default-config.toml"
icon_source="resources/Assets.xcassets/AppIcon.appiconset/icon.png"
for frame in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        test "$scale" -eq 1 || suffix="@2x"
        sips -z $((frame * scale)) $((frame * scale)) "$icon_source" \
            --out "$iconset/icon_${frame}x${frame}${suffix}.png" > /dev/null
    done
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

# Mirrors GENERATE_INFOPLIST_FILE from xcode/project.yml (Release config)
plist() {
    plutil -create xml1 "$1"
    plutil -insert "CFBundleDisplayName" -string "AeroSpace" "$1"
    plutil -insert "CFBundleExecutable" -string "AeroSpace" "$1"
    plutil -insert "CFBundleIconFile" -string "AppIcon" "$1"
    plutil -insert "CFBundleIdentifier" -string "$bundle_id" "$1"
    plutil -insert "CFBundleName" -string "AeroSpace" "$1"
    plutil -insert "CFBundlePackageType" -string "APPL" "$1"
    plutil -insert "CFBundleShortVersionString" -string "$build_version" "$1"
    plutil -insert "CFBundleVersion" -string "$build_version" "$1"
    plutil -insert "LSMinimumSystemVersion" -string "13.0" "$1"
    plutil -insert "LSUIElement" -bool true "$1"
    plutil -insert "NSHighResolutionCapable" -bool true "$1"
}
plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
test "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" == "$build_version" \
    || fail "Info.plist version mismatch"

# Sign the bundle once, with the identifier and the entitlements, because signing a nested
# executable separately makes bundle signing drop them again. No --deep, no hardened runtime:
# a self-signed local build has no notarization to pair it with.
codesign -f -s "$codesign_identity" --identifier "$bundle_id" \
    --entitlements resources/AeroSpace.entitlements "$app"
cli_artifact="$release_dir/aerospace"
cp "$cli_bin" "$cli_artifact"
codesign -f -s "$codesign_identity" "$cli_artifact"

# macOS keys TCC grants on the designated requirement, which must pin the certificate leaf; a
# cdhash-only requirement changes on every rebuild. codesign prints it on stderr.
designated_requirement() {
    codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}
codesign --verify --strict --verbose=2 "$app" > /dev/null 2>&1 || fail "App signature verification failed"
codesign --verify --strict --verbose=2 "$cli_artifact" > /dev/null 2>&1 || fail "CLI signature verification failed"
new_req="$(designated_requirement "$app")"
[[ "$new_req" == *"identifier \"$bundle_id\""* ]] || fail "App requirement is not bound to $bundle_id: $new_req"
check_certificate_leaf() {
    [[ "$(designated_requirement "$1")" == *'certificate leaf = H"'* ]] \
        || fail "$1 requirement is not pinned to the certificate leaf"
}
check_certificate_leaf "$app"
check_certificate_leaf "$cli_artifact"
codesign -d --entitlements - --xml "$app" 2> /dev/null | grep --fixed-string -q "com.apple.security.app-sandbox" \
    || fail "App signature lost the entitlements"

# --- install ---------------------------------------------------------------
# Replace only the known previous install, and only if it is the same app with the same identity.
# Anything else at that path is refused rather than deleted.
if [[ -e "$app_path" || -L "$app_path" ]]; then
    if test -L "$app_path"; then
        fail "$app_path is a symlink. Refusing to replace it."
    fi
    test -d "$app_path" || fail "$app_path is not an app bundle. Refusing to touch it."
    test "$(stat -f %u "$app_path")" = "$(id -u)" || fail "$app_path is not owned by the current user"
    installed_id="$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist" 2> /dev/null || true)"
    test "$installed_id" = "$bundle_id" || fail "$app_path contains '$installed_id', not '$bundle_id'. Refusing to replace it."
    old_req="$(designated_requirement "$app_path")"
    test -n "$old_req" || fail "Cannot read the requirement of the installed app. Refusing to replace it."
    if test "$old_req" != "$new_req"; then
        echo "installed: $old_req" > /dev/stderr
        echo "new:       $new_req" > /dev/stderr
        fail "Signing identity would change. Move $app_path away manually if that is intended."
    fi
fi

# Checking here, after the build, keeps a running install from blocking a whole compile. The
# script never quits or restarts it: the user quits and re-runs.
if running_pids="$(pgrep -x AeroSpace)"; then
    while read -r app_pid; do
        if [[ "$(ps -o comm= -p "$app_pid")" == "$app_path/Contents/MacOS/AeroSpace" ]]; then
            fail "$app_path is running (pid $app_pid). Quit it and re-run. Nothing was replaced."
        fi
    done <<< "$running_pids"
fi

# The previous bundle is moved aside only after the new and verified copy is complete.
if [[ -e "$app_path" ]]; then
    mv "$app_path" "$stage/old"
    if ! mv "$app" "$app_path"; then
        mv "$stage/old" "$app_path"
        fail "Install failed; the previous app was restored."
    fi
else
    mv "$app" "$app_path"
fi
rm -rf "$stage"
stage=""

# The CLI link stays on the SwiftPM release binary; a signed copy is kept separately.
ln -sfn "$cli_bin" "$cli_link"
echo "Installed $app_path ($build_version)"
echo "CLI: $cli_link -> $cli_bin"
echo "Signed CLI copy: $cli_artifact"
