#!/usr/bin/env bash
# Builds WebRTC.xcframework from a checkout made by fetch_webrtc_ios.sh, using
# Xcode's clang. Mirrors WebRTC's tools_webrtc/ios/build_ios_libs.py without
# depot_tools or siso: one gn/ninja build per slice, lipo per environment,
# then xcodebuild -create-xcframework.
#
# Usage: build_webrtc_ios.sh <dest-dir>
# Environment:
#   SLICES          environment:cpu list (default
#                   "device:arm64 simulator:arm64 simulator:x64").
#   IOS_DEPLOYMENT_TARGET  minimum iOS version (default 14.0).
#   PROTOBUF=0      build without protobuf, so nothing is built for the Mac
#                   host (loses RtcEventLog output and audio debug dumps).
#   DEBUG=1         debug build.
# Output: <dest-dir>/out_ios_libs/WebRTC.xcframework
set -euo pipefail

DEST=$(cd "${1:?usage: $0 <dest-dir>}" && pwd)
SRC=$DEST/src
SLICES=${SLICES:-device:arm64 simulator:arm64 simulator:x64}
IOS_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET:-14.0}
PROTOBUF=${PROTOBUF:-1}
DEBUG=${DEBUG:-0}
OUT=$DEST/out_ios_libs

XCODE_TOOLCHAIN=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr
CLANG_VERSION=$(ls "$XCODE_TOOLCHAIN/lib/clang" | sort | head -1)
NINJA=$(command -v ninja || echo "$SRC/third_party/ninja/ninja")
GN=$SRC/buildtools/mac/gn

# 1. One build per slice.
for slice in $SLICES; do
  env=${slice%%:*}
  cpu=${slice#*:}
  dir=$SRC/out/ios_${env}_${cpu}
  mkdir -p "$dir"
  cat >"$dir/args.gn" <<EOF
target_os = "ios"
target_environment = "$env"
target_cpu = "$cpu"
ios_deployment_target = "$IOS_DEPLOYMENT_TARGET"
ios_enable_code_signing = false
is_component_build = false
is_debug = $([ "$DEBUG" = 1 ] && echo true || echo false)
enable_dsyms = true
enable_stripping = true
rtc_enable_objc_symbol_export = true
rtc_libvpx_build_vp9 = false
rtc_include_tests = false
rtc_build_examples = false
rtc_build_tools = false
rtc_enable_protobuf = $([ "$PROTOBUF" = 0 ] && echo false || echo true)
# Xcode's clang and linker instead of Chromium's downloaded toolchain.
clang_base_path = "$XCODE_TOOLCHAIN"
clang_version = "$CLANG_VERSION"
use_chromium_clang = false
clang_use_chrome_plugins = false
use_lld = false
use_custom_libcxx = false
use_custom_libcxx_for_host = false
enable_rust = false
rtc_rust = false
EOF
  echo "== $slice"
  "$GN" gen --root="$SRC" "$dir" >/dev/null
  "$NINJA" -C "$dir" framework_objc
done

# 2. Merge the slices of each environment with lipo.
rm -rf "$OUT"
envs=$(for slice in $SLICES; do echo "${slice%%:*}"; done | awk '!seen[$0]++')
xcframework_args=()
for env in $envs; do
  dirs=()
  for slice in $SLICES; do
    [ "${slice%%:*}" = "$env" ] && dirs+=("$SRC/out/ios_${env}_${slice#*:}")
  done
  mkdir -p "$OUT/$env"
  cp -R "${dirs[0]}/WebRTC.framework" "${dirs[0]}/WebRTC.dSYM" "$OUT/$env/"
  lipo -create "${dirs[@]/%//WebRTC.framework/WebRTC}" \
    -output "$OUT/$env/WebRTC.framework/WebRTC"
  dwarf=WebRTC.dSYM/Contents/Resources/DWARF/WebRTC
  lipo -create "${dirs[@]/%//$dwarf}" -output "$OUT/$env/$dwarf"
  xcframework_args+=(-framework "$OUT/$env/WebRTC.framework"
                     -debug-symbols "$OUT/$env/WebRTC.dSYM")
done

# 3. The xcframework.
xcodebuild -create-xcframework "${xcframework_args[@]}" \
  -output "$OUT/WebRTC.xcframework"
echo
echo "Done: $OUT/WebRTC.xcframework"
