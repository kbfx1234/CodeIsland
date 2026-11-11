# Sourced by build.sh and scripts/build-dmg.sh: build one architecture of the
# release products and make sure the products packaged are the ones that
# build just made.
#
# Release builds pin SwiftPM's native build system. Swift 6.4 (Xcode 27) made
# swiftbuild the default, and its products break a release in two ways: every
# --arch writes the same .build/out/Products/Release, so building x86_64 after
# arm64 overwrites it, and LC_BUILD_VERSION records the 14.0 deployment target
# as the SDK, which makes AppKit run the app in its old-SDK compatibility mode.
# The scripts meanwhile kept copying from .build/<arch>-apple-macosx/release,
# where nothing had been built since v1.0.35, so v1.0.36 to v1.0.38 shipped
# v1.0.35's binaries under new version numbers. If a toolchain drops the
# native build system, check the SDK it records before switching.
SWIFTPM_RELEASE_FLAGS=(-c release --build-system native)

# Builds `arch` and prints the directory holding its products. The previous
# products are deleted first, so a build that writes somewhere else fails here
# instead of leaving an earlier build's binaries to be packaged.
swiftpm_release_build() {
    local arch="$1"
    local bin_dir
    bin_dir=$(swift build "${SWIFTPM_RELEASE_FLAGS[@]}" --arch "$arch" --show-bin-path) || return 1
    rm -rf "$bin_dir/CodeIsland" "$bin_dir/codeisland-bridge" "$bin_dir/CodeIsland_CodeIsland.bundle"
    swift build "${SWIFTPM_RELEASE_FLAGS[@]}" --arch "$arch" >&2 || return 1
    swiftpm_check_release_binary "$bin_dir/CodeIsland" "$arch" || return 1
    swiftpm_check_release_binary "$bin_dir/codeisland-bridge" "$arch" || return 1
    if [ ! -d "$bin_dir/CodeIsland_CodeIsland.bundle" ]; then
        echo "ERROR: the $arch build left no CodeIsland_CodeIsland.bundle in $bin_dir" >&2
        return 1
    fi
    echo "$bin_dir"
}

# A product must exist, hold exactly `arch`, and record the SDK it was linked
# against rather than its deployment target.
swiftpm_check_release_binary() {
    local binary="$1" arch="$2"
    local archs sdk expected_sdk
    if [ ! -f "$binary" ]; then
        echo "ERROR: the $arch build left no $binary" >&2
        return 1
    fi
    archs=$(lipo -archs "$binary")
    if [ "$archs" != "$arch" ]; then
        echo "ERROR: $binary contains '$archs', expected '$arch'" >&2
        return 1
    fi
    sdk=$(otool -l "$binary" | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1 } found && $1 == "sdk" { print $2; exit }')
    expected_sdk=$(xcrun --sdk macosx --show-sdk-version)
    if [ "$sdk" != "$expected_sdk" ]; then
        echo "ERROR: $binary records SDK ${sdk:-none}, but the $expected_sdk SDK built it" >&2
        return 1
    fi
}
