#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
mode="${1:-}"
architecture_selection="${2:-all}"
version_info="$("$repo_dir/scripts/project-version.sh")"
version="${version_info%% *}"
base_build_number="${version_info##* }"
expected_bundle_identifier="app.ihopeful.Ossuno"
sparkle_account="studio.ossuno.oss"
# This is the Keychain account for the existing Sparkle signing key, not the
# application Bundle ID. Keep it stable across the 1.0.5 identity migration.
informational_update_below_version="12"
version_slug="${version//./}"
dist_dir="$repo_dir/dist"
tracked_appcast_path="$repo_dir/appcast.xml"
release_notes_path="$repo_dir/docs/releases/$version.md"

usage() {
    print -u2 "Usage: scripts/package-dmg.sh <development|adhoc|adhoc-release|release> [all|arm64|x86_64]"
    print -u2 "       adhoc, adhoc-release, and release must package all architectures together."
    print -u2 "       adhoc-release also requires OSSUNO_ALLOW_ADHOC_RELEASE=1."
    exit 64
}

fail() {
    print -u2 "Packaging failed: $1"
    exit 1
}

[[ "$mode" == "development" || "$mode" == "adhoc" || "$mode" == "adhoc-release" || "$mode" == "release" ]] || usage
[[ "$architecture_selection" == "all" || "$architecture_selection" == "arm64" || "$architecture_selection" == "x86_64" ]] || usage
if [[ "$mode" != "development" && "$architecture_selection" != "all" ]]; then
    fail "$mode packaging requires both arm64 and x86_64 so Sparkle can generate one complete feed"
fi
[[ -f "$release_notes_path" ]] || fail "missing release notes: $release_notes_path"
case "$base_build_number" in
    ''|*[!0-9]*) fail "project build number must be a positive integer" ;;
esac
(( base_build_number > 1 )) || fail "project build number must be greater than 1 for dual-architecture packaging"
(( base_build_number % 2 == 1 )) \
    || fail "project build number must be odd (3, 5, 7, ...) so architecture build pairs never collide"

# Sparkle 2 uses sparkle:hardwareRequirements=arm64 to hide an ARM-only item
# from Intel Macs. It deliberately rejects duplicate CFBundleVersion archives,
# so the two thin packages share MARKETING_VERSION but need distinct internal
# build numbers. CURRENT_PROJECT_VERSION is the ARM build; Intel uses the
# immediately preceding number. Apple Silicon sees both items and selects the
# higher ARM build, while Intel filters it out and selects the x86_64 item.
arm64_build_number="$base_build_number"
x86_64_build_number="$((base_build_number - 1))"

if [[ "$architecture_selection" == "all" ]]; then
    architectures=(x86_64 arm64)
else
    architectures=("$architecture_selection")
fi

build_number_for_architecture() {
    case "$1" in
        arm64) print -r -- "$arm64_build_number" ;;
        x86_64) print -r -- "$x86_64_build_number" ;;
        *) fail "unsupported architecture: $1" ;;
    esac
}

artifact_name_for_architecture() {
    local architecture="$1"
    if [[ "$mode" == "development" ]]; then
        print -r -- "Ossuno-$version-development-$architecture.dmg"
    elif [[ "$mode" == "adhoc" ]]; then
        print -r -- "Ossuno-$version-adhoc-$architecture.dmg"
    else
        print -r -- "Ossuno-$version-$architecture.dmg"
    fi
}

derived_dir_for_architecture() {
    print -r -- "$repo_dir/.build/release-v$version_slug-$mode-$1"
}

assert_thin_macho_tree() {
    local root="$1"
    local expected_architecture="$2"
    local candidate description slices
    local macho_count=0

    while IFS= read -r -d $'\0' candidate; do
        description="$(file -b "$candidate")"
        if [[ "$description" == Mach-O* ]]; then
            slices="$(lipo -archs "$candidate" 2>/dev/null)" \
                || fail "unable to inspect Mach-O architectures: $candidate"
            [[ "$slices" == "$expected_architecture" ]] \
                || fail "expected only $expected_architecture in $candidate, found: $slices"
            macho_count=$((macho_count + 1))
        fi
    done < <(find "$root" -type f -print0)

    (( macho_count > 0 )) || fail "no Mach-O files found in $root"
}

developer_identity="${OSSUNO_DEVELOPER_ID_APPLICATION:-}"
development_team="${OSSUNO_DEVELOPMENT_TEAM:-}"
notary_profile="${OSSUNO_NOTARY_PROFILE:-}"

if [[ "$mode" == "adhoc-release" ]]; then
    [[ "${OSSUNO_ALLOW_ADHOC_RELEASE:-0}" == "1" ]] \
        || fail "adhoc-release requires the explicit OSSUNO_ALLOW_ADHOC_RELEASE=1 acknowledgement"
    if grep -Eiq '(使用 Developer ID 签名|通过 Apple 公证|Gatekeeper 正常验证|Developer ID signed|Apple notarized)' "$release_notes_path"; then
        fail "release notes must not claim Developer ID signing, notarization, or normal Gatekeeper verification for adhoc-release"
    fi
    grep -Eiq '(ad.?hoc|未公证|未经.*公证|右键.*打开)' "$release_notes_path" \
        || fail "release notes must explicitly disclose the ad-hoc, non-notarized distribution"
fi

# Release requirements are checked before the build or tracked file changes.
# Ad-hoc mode intentionally skips them and must never be presented as a
# Gatekeeper-ready public release.
if [[ "$mode" == "release" ]]; then
    if grep -Eiq '(ad.?hoc|右键.*打开)' "$release_notes_path"; then
        fail "release notes still describe an ad-hoc or Gatekeeper-bypass build"
    fi
    [[ -n "$developer_identity" ]] || fail "OSSUNO_DEVELOPER_ID_APPLICATION is required"
    [[ -n "$development_team" ]] || fail "OSSUNO_DEVELOPMENT_TEAM is required"
    [[ -n "$notary_profile" ]] || fail "OSSUNO_NOTARY_PROFILE is required"
    security find-identity -v -p codesigning | grep -Fq "\"$developer_identity\"" \
        || fail "the configured Developer ID Application identity is unavailable"
    xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null \
        || fail "the configured notarization profile is unavailable"
fi

for architecture in "${architectures[@]}"; do
    output_path="$dist_dir/$(artifact_name_for_architecture "$architecture")"
    [[ ! -e "$output_path" ]] || fail "refusing to overwrite $output_path"
done

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ossuno-v$version_slug-dmg.XXXXXX")"
appcast_dir="$stage_dir/appcast"
private_key_path="$stage_dir/sparkle-signing.key"
cleanup() {
    if [[ "$stage_dir" == "${TMPDIR:-/tmp}"/ossuno-v$version_slug-dmg.* ]]; then
        rm -rf "$stage_dir"
    fi
}
trap cleanup EXIT

build_architecture() {
    local architecture="$1"
    local build_number artifact_name derived_dir built_app_path packaged_app_path
    local temp_dmg volume_dir actual_version actual_build actual_bundle_identifier signature_details

    build_number="$(build_number_for_architecture "$architecture")"
    artifact_name="$(artifact_name_for_architecture "$architecture")"
    derived_dir="$(derived_dir_for_architecture "$architecture")"
    built_app_path="$derived_dir/Build/Products/Release/Ossuno.app"
    packaged_app_path="$stage_dir/apps/$architecture/Ossuno.app"
    temp_dmg="$stage_dir/$artifact_name"
    volume_dir="$stage_dir/volumes/$architecture"

    local build_settings=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        "ARCHS=$architecture"
        ONLY_ACTIVE_ARCH=YES
        "CURRENT_PROJECT_VERSION=$build_number"
    )
    if [[ "$mode" == "development" || "$mode" == "adhoc" || "$mode" == "adhoc-release" ]]; then
        build_settings+=(
            CODE_SIGN_IDENTITY=-
            DEVELOPMENT_TEAM=
            ENABLE_HARDENED_RUNTIME=NO
        )
    else
        build_settings+=(
            "CODE_SIGN_IDENTITY=$developer_identity"
            "DEVELOPMENT_TEAM=$development_team"
            ENABLE_HARDENED_RUNTIME=YES
            OTHER_CODE_SIGN_FLAGS=--timestamp
        )
    fi

    xcodebuild \
        -project "$repo_dir/Ossuno.xcodeproj" \
        -scheme Ossuno \
        -configuration Release \
        -destination "platform=macOS,arch=$architecture" \
        -derivedDataPath "$derived_dir" \
        -onlyUsePackageVersionsFromResolvedFile \
        -skipPackageUpdates \
        -packageAuthorizationProvider netrc \
        clean build \
        "${build_settings[@]}"

    [[ -d "$built_app_path" ]] || fail "built app is missing for $architecture"
    actual_version="$(plutil -extract CFBundleShortVersionString raw "$built_app_path/Contents/Info.plist")"
    actual_build="$(plutil -extract CFBundleVersion raw "$built_app_path/Contents/Info.plist")"
    actual_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$built_app_path/Contents/Info.plist")"
    [[ "$actual_version" == "$version" ]] || fail "$architecture app version is $actual_version"
    [[ "$actual_build" == "$build_number" ]] || fail "$architecture app build is $actual_build"
    [[ "$actual_bundle_identifier" == "$expected_bundle_identifier" ]] \
        || fail "$architecture app bundle identifier is $actual_bundle_identifier, expected $expected_bundle_identifier"

    # Sparkle is delivered as a universal binary artifact. ditto --arch keeps
    # the requested CodeDirectory slice while removing every other slice from
    # the app and all nested helpers/frameworks.
    mkdir -p "${packaged_app_path:h}"
    ditto --arch "$architecture" "$built_app_path" "$packaged_app_path"
    assert_thin_macho_tree "$packaged_app_path" "$architecture"

    if [[ "$mode" == "development" || "$mode" == "adhoc" || "$mode" == "adhoc-release" ]]; then
        codesign --force --deep --sign - "$packaged_app_path"
        codesign --verify --deep --strict --verbose=2 "$packaged_app_path"
    else
        codesign --verify --deep --strict --verbose=2 "$packaged_app_path"
        signature_details="$(codesign -dv --verbose=4 "$packaged_app_path" 2>&1)"
        print -r -- "$signature_details" | grep -Eq '^Authority=Developer ID Application:' \
            || fail "$architecture app is not signed with Developer ID Application"
        print -r -- "$signature_details" | grep -Fq "TeamIdentifier=$development_team" \
            || fail "$architecture app team identifier does not match"
        print -r -- "$signature_details" | grep -Eq '^flags=.*runtime' \
            || fail "$architecture app does not enable Hardened Runtime"
    fi

    if plutil -extract SUEnableInstallerLauncherService raw "$packaged_app_path/Contents/Info.plist" >/dev/null 2>&1; then
        fail "non-sandboxed builds must use Sparkle's in-process installer launcher"
    fi

    mkdir -p "$volume_dir" "$dist_dir"
    ditto "$packaged_app_path" "$volume_dir/Ossuno.app"
    ln -s /Applications "$volume_dir/Applications"
    if [[ "$mode" == "development" ]]; then
        print "LOCAL DEVELOPMENT ARTIFACT ($architecture) — DO NOT PUBLISH" \
            > "$volume_dir/DEVELOPMENT-ONLY.txt"
    fi

    hdiutil create \
        -volname "Ossuno $version ($architecture)" \
        -srcfolder "$volume_dir" \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$temp_dmg"
    hdiutil verify "$temp_dmg" >/dev/null

    if [[ "$mode" == "release" ]]; then
        codesign --force --sign "$developer_identity" --timestamp "$temp_dmg"
        xcrun notarytool submit "$temp_dmg" --keychain-profile "$notary_profile" --wait
        xcrun stapler staple "$temp_dmg"
        xcrun stapler validate "$temp_dmg"
    fi
}

cd "$repo_dir"
for architecture in "${architectures[@]}"; do
    build_architecture "$architecture"
done

if [[ "$mode" == "development" ]]; then
    for architecture in "${architectures[@]}"; do
        artifact_name="$(artifact_name_for_architecture "$architecture")"
        output_path="$dist_dir/$artifact_name"
        mv "$stage_dir/$artifact_name" "$output_path"
        print "Created local-only $architecture artifact: $output_path"
        shasum -a 256 "$output_path"
    done
    exit 0
fi

arm64_artifact_name="$(artifact_name_for_architecture arm64)"
x86_64_artifact_name="$(artifact_name_for_architecture x86_64)"
arm64_temp_dmg="$stage_dir/$arm64_artifact_name"
x86_64_temp_dmg="$stage_dir/$x86_64_artifact_name"
arm64_app_path="$stage_dir/apps/arm64/Ossuno.app"
x86_64_app_path="$stage_dir/apps/x86_64/Ossuno.app"

sparkle_dir="$(derived_dir_for_architecture arm64)/SourcePackages/artifacts/sparkle/Sparkle"
generate_appcast="$sparkle_dir/bin/generate_appcast"
generate_keys="$sparkle_dir/bin/generate_keys"
sign_update="$sparkle_dir/bin/sign_update"
[[ -x "$generate_appcast" ]] || fail "Sparkle generate_appcast is missing"
[[ -x "$generate_keys" ]] || fail "Sparkle generate_keys is missing"
[[ -x "$sign_update" ]] || fail "Sparkle sign_update is missing"

arm64_public_key="$(plutil -extract SUPublicEDKey raw "$arm64_app_path/Contents/Info.plist")"
x86_64_public_key="$(plutil -extract SUPublicEDKey raw "$x86_64_app_path/Contents/Info.plist")"
[[ "$arm64_public_key" == "$x86_64_public_key" ]] || fail "architecture builds use different Sparkle public keys"
signing_public_key="$("$generate_keys" --account "$sparkle_account" -p)"
[[ "$signing_public_key" == "$arm64_public_key" ]] || fail "Sparkle signing key does not match the apps"
"$generate_keys" --account "$sparkle_account" -x "$private_key_path"
chmod 600 "$private_key_path"

mkdir -p "$appcast_dir"
ditto "$arm64_temp_dmg" "$appcast_dir/$arm64_artifact_name"
ditto "$x86_64_temp_dmg" "$appcast_dir/$x86_64_artifact_name"
ditto "$release_notes_path" "$appcast_dir/${arm64_artifact_name:r}.md"
ditto "$release_notes_path" "$appcast_dir/${x86_64_artifact_name:r}.md"
if [[ "$mode" != "adhoc-release" && -f "$tracked_appcast_path" ]]; then
    ditto "$tracked_appcast_path" "$appcast_dir/appcast.xml"
fi

# generate_appcast infers the arm64 hardware requirement from the actual thin
# executable. Distinct build numbers let it represent both packages in one
# official Sparkle feed without hand-written or duplicate-version entries.
"$generate_appcast" \
    --ed-key-file "$private_key_path" \
    --download-url-prefix "https://github.com/ihopefulChina/Ossuno/releases/download/v$version/" \
    --link "https://github.com/ihopefulChina/Ossuno/releases/tag/v$version" \
    --versions "$x86_64_build_number,$arm64_build_number" \
    --informational-update-versions "<$informational_update_below_version" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$appcast_dir"

for build_number in "$x86_64_build_number" "$arm64_build_number"; do
    informational_update_count="$(xmllint --xpath "count(//*[local-name()='item' and *[local-name()='version' and text()='$build_number'] and *[local-name()='informationalUpdate']/*[local-name()='belowVersion' and text()='$informational_update_below_version']])" "$appcast_dir/appcast.xml")"
    [[ "$informational_update_count" == "1" ]] \
        || fail "build $build_number must be informational for hosts below build $informational_update_below_version"
done

if [[ "$mode" == "adhoc-release" ]]; then
    all_item_count="$(xmllint --xpath "count(//*[local-name()='item'])" "$appcast_dir/appcast.xml")"
    x86_64_item_count="$(xmllint --xpath "count(//*[local-name()='item' and *[local-name()='version' and text()='$x86_64_build_number']])" "$appcast_dir/appcast.xml")"
    arm64_item_count="$(xmllint --xpath "count(//*[local-name()='item' and *[local-name()='version' and text()='$arm64_build_number']])" "$appcast_dir/appcast.xml")"
    [[ "$all_item_count" == "2" && "$x86_64_item_count" == "1" && "$arm64_item_count" == "1" ]] \
        || fail "adhoc-release appcast must contain exactly builds $x86_64_build_number and $arm64_build_number, with no historical items"
fi

for architecture in x86_64 arm64; do
    artifact_name="$(artifact_name_for_architecture "$architecture")"
    build_number="$(build_number_for_architecture "$architecture")"
    OSSUNO_SPARKLE_SIGN_UPDATE="$sign_update" \
    OSSUNO_SPARKLE_KEY_FILE="$private_key_path" \
    OSSUNO_DEVELOPMENT_TEAM="$development_team" \
    OSSUNO_ADHOC="$([[ "$mode" == "adhoc" || "$mode" == "adhoc-release" ]] && print 1 || print 0)" \
        "$script_dir/verify-release.sh" \
        "$stage_dir/$artifact_name" \
        "$version" \
        "$build_number" \
        "$appcast_dir/appcast.xml" \
        "$architecture"
done

# Only fully verified artifacts may affect release outputs. Ad-hoc mode keeps
# its feed separate and never mutates either tracked feed.
for architecture in x86_64 arm64; do
    artifact_name="$(artifact_name_for_architecture "$architecture")"
    output_path="$dist_dir/$artifact_name"
    mv "$stage_dir/$artifact_name" "$output_path"
    if [[ "$mode" == "adhoc" ]]; then
        print "Created local-only ad-hoc $architecture artifact (DO NOT PUBLISH): $output_path"
    elif [[ "$mode" == "adhoc-release" ]]; then
        print "Created formal ad-hoc $architecture artifact (NOT Developer ID signed; NOT notarized): $output_path"
    else
        print "Created verified $architecture release artifact: $output_path"
    fi
    shasum -a 256 "$output_path"
done
if [[ "$mode" == "adhoc" ]]; then
    adhoc_appcast_path="$dist_dir/appcast-adhoc.xml"
    ditto "$appcast_dir/appcast.xml" "$adhoc_appcast_path"
    print "Created local-only ad-hoc feed (DO NOT PUBLISH): $adhoc_appcast_path"
    shasum -a 256 "$adhoc_appcast_path"
    exit 0
fi

ditto "$appcast_dir/appcast.xml" "$dist_dir/appcast.xml"
ditto "$appcast_dir/appcast.xml" "$tracked_appcast_path"
ditto "$appcast_dir/appcast.xml" "$repo_dir/website/appcast.xml"
shasum -a 256 "$dist_dir/appcast.xml"

print
if [[ "$mode" == "adhoc-release" ]]; then
    print "AD-HOC DISTRIBUTION WARNING: these artifacts are ad-hoc signed, not Developer ID signed, and not notarized."
    print "Gatekeeper may block normal double-click launch; do not describe them as Apple-verified artifacts."
    print
fi
print "Publishing checklist:"
print "  1. Upload both uniquely named DMGs before publishing any link or feed:"
print "       - $arm64_artifact_name"
print "       - $x86_64_artifact_name"
print "     gh release upload v$version $dist_dir/$arm64_artifact_name $dist_dir/$x86_64_artifact_name"
print "  2. Verify both public asset URLs, lengths, hashes, architectures, and Gatekeeper assessments."
print "  3. Commit + push the website and both appcast files to main, then wait for Pages to serve the new feed."
print "  4. Replace only the release-page appcast asset after the Pages feed is live:"
print "     gh release upload v$version $tracked_appcast_path --clobber"
print "  5. Remove the obsolete architecture-neutral DMG only after both new downloads and feeds are verified."
next_arm64_build_number="$((arm64_build_number + 2))"
print "  6. Set the next release CURRENT_PROJECT_VERSION to odd build $next_arm64_build_number or higher (advance by 2)."
