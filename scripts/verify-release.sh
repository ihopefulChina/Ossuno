#!/bin/zsh
set -euo pipefail

if [[ "$#" != "5" ]]; then
    print -u2 "Usage: scripts/verify-release.sh <dmg> <version> <build> <appcast> <arm64|x86_64>"
    exit 64
fi

dmg_path="${1:A}"
expected_version="$2"
expected_build="$3"
appcast_path="${4:A}"
expected_architecture="$5"
expected_bundle_identifier="app.ihopeful.Ossuno"
expected_team="${OSSUNO_DEVELOPMENT_TEAM:-}"
sign_update="${OSSUNO_SPARKLE_SIGN_UPDATE:-}"
sparkle_key_file="${OSSUNO_SPARKLE_KEY_FILE:-}"
adhoc="${OSSUNO_ADHOC:-0}"

fail() {
    print -u2 "Release verification failed: $1"
    exit 1
}

[[ "$expected_architecture" == "arm64" || "$expected_architecture" == "x86_64" ]] \
    || fail "expected architecture must be arm64 or x86_64"
[[ -f "$dmg_path" ]] || fail "DMG does not exist"
[[ -f "$appcast_path" ]] || fail "appcast does not exist"
if [[ "$adhoc" != "1" ]]; then
    [[ -n "$expected_team" ]] || fail "OSSUNO_DEVELOPMENT_TEAM is required"
fi
[[ -x "$sign_update" ]] || fail "OSSUNO_SPARKLE_SIGN_UPDATE must point to sign_update"
[[ -f "$sparkle_key_file" ]] || fail "OSSUNO_SPARKLE_KEY_FILE is required"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ossuno-verify-release.XXXXXX")"
mount_dir="$stage_dir/mount"
mounted=0
cleanup() {
    if [[ "$mounted" == "1" ]]; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    if [[ "$stage_dir" == "${TMPDIR:-/tmp}"/ossuno-verify-release.* ]]; then
        rm -rf "$stage_dir"
    fi
}
trap cleanup EXIT

hdiutil verify "$dmg_path" >/dev/null
if [[ "$adhoc" == "1" ]]; then
    print 'Ad-hoc build: skipping notarization and Gatekeeper checks.'
else
    codesign --verify --strict --verbose=2 "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
fi

mkdir -p "$mount_dir"
hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
mounted=1
app_path="$mount_dir/Ossuno.app"
[[ -d "$app_path" ]] || fail "mounted DMG does not contain Ossuno.app"

actual_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
actual_build="$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
actual_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")"
[[ "$actual_version" == "$expected_version" ]] || fail "expected version $expected_version, found $actual_version"
[[ "$actual_build" == "$expected_build" ]] || fail "expected build $expected_build, found $actual_build"
[[ "$actual_bundle_identifier" == "$expected_bundle_identifier" ]] \
    || fail "expected bundle identifier $expected_bundle_identifier, found $actual_bundle_identifier"

executable_name="$(plutil -extract CFBundleExecutable raw "$app_path/Contents/Info.plist")"
executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -x "$executable_path" ]] || fail "app executable is missing"

# Check every Mach-O, including Sparkle's framework, updater app, XPC services,
# and Autoupdate helper. A thin release must not quietly embed the other slice.
macho_count=0
while IFS= read -r -d $'\0' candidate; do
    description="$(file -b "$candidate")"
    if [[ "$description" == Mach-O* ]]; then
        architectures="$(lipo -archs "$candidate" 2>/dev/null)" \
            || fail "unable to inspect Mach-O architectures: $candidate"
        [[ "$architectures" == "$expected_architecture" ]] \
            || fail "expected only $expected_architecture in $candidate, found: $architectures"
        macho_count=$((macho_count + 1))
    fi
done < <(find "$app_path" -type f -print0)
(( macho_count > 0 )) || fail "mounted app contains no Mach-O files"

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
if [[ "$adhoc" == "1" ]]; then
    print -r -- "$signature_details" | grep -Fq 'Signature=adhoc' \
        || fail "app is not ad-hoc signed"
else
    print -r -- "$signature_details" | grep -Eq '^Authority=Developer ID Application:' \
        || fail "Developer ID Application authority is missing"
    print -r -- "$signature_details" | grep -Fq "TeamIdentifier=$expected_team" \
        || fail "TeamIdentifier does not match OSSUNO_DEVELOPMENT_TEAM"
    print -r -- "$signature_details" | grep -Eq '^flags=.*runtime' \
        || fail "Hardened Runtime flag is missing"
    print -r -- "$signature_details" | grep -Eq '^Timestamp=.+' \
        || fail "secure timestamp is missing"
    if print -r -- "$signature_details" | grep -Fq 'Timestamp=none'; then
        fail "secure timestamp is missing"
    fi
    spctl --assess --type execute --verbose=2 "$app_path"
fi

item_xpath="//*[local-name()='item' and *[local-name()='version' and text()='$expected_build']]"
item_count="$(xmllint --xpath "count($item_xpath)" "$appcast_path")"
[[ "$item_count" == "1" ]] || fail "appcast must contain exactly one item for build $expected_build"

declared_length="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@length)" "$appcast_path")"
signature="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast_path")"
download_url="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@url)" "$appcast_path")"
short_version="$(xmllint --xpath "string($item_xpath/*[local-name()='shortVersionString'])" "$appcast_path")"
hardware_requirements="$(xmllint --xpath "string($item_xpath/*[local-name()='hardwareRequirements'])" "$appcast_path")"
expected_artifact_name="${dmg_path:t}"

[[ "$short_version" == "$expected_version" ]] || fail "appcast version does not match"
[[ "${download_url##*/}" == "$expected_artifact_name" ]] \
    || fail "appcast URL does not select $expected_artifact_name"
[[ -n "$signature" ]] || fail "Sparkle signature is missing"
[[ "$declared_length" == "$(stat -f %z "$dmg_path")" ]] || fail "appcast file length does not match DMG"

if [[ "$expected_architecture" == "arm64" ]]; then
    [[ "${hardware_requirements:l}" == "arm64" ]] \
        || fail "arm64 item must declare sparkle:hardwareRequirements=arm64"
else
    [[ -z "$hardware_requirements" ]] \
        || fail "x86_64 item must not declare hardware requirements"
fi

"$sign_update" --verify --ed-key-file "$sparkle_key_file" "$dmg_path" "$signature"

print "Release verification passed for Ossuno $expected_version ($expected_build, $expected_architecture)."
