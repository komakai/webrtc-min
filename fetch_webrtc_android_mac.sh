#!/usr/bin/env bash
# macOS version of fetch_webrtc_android.sh.
#
# Fetches the minimal WebRTC checkout needed to build
# //sdk/android:libjingle_peerconnection_so for Android with the Android NDK
# compiler, on a macOS host. No depot_tools / gclient / cipd needed: only git,
# curl, unzip and python3, plus Xcode (the full app, not just the Command Line
# Tools: Chromium's build queries `xcodebuild -version` and the macOS SDK to
# build host tools such as protoc).
#
# Chromium only officially supports Android builds on Linux hosts; Mac hosts
# are "best-effort". build-mac-host.patch lifts the Linux-only assert.
#
# Usage: fetch_webrtc_android_mac.sh <dest-dir> [webrtc-revision]
#   webrtc-revision defaults to the tip of main.
# Environment:
#   ANDROID_NDK_HOME  use an existing NDK instead of downloading one.
#   NDK_URL           NDK zip to download (default: r30, matching DEPS).
#   JAVA_HOME         use an existing JDK (for javap) instead of downloading.
#   ANDROID_HOME      Android SDK to take platforms/android-<ver>/ from, if it has
#                     it (default ~/Library/Android/sdk); otherwise downloaded.
#   A ninja on PATH is used instead of downloading one.
#   SOFTWARE_VIDEO_CODECS=0  build without libvpx (VP8/VP9), libaom and dav1d
#                     (AV1) and don't fetch them; video then relies on the
#                     device's MediaCodec (HardwareVideoEncoderFactory etc.).
#   PROTOBUF=0        build without protobuf (no protoc or other host tools;
#                     loses RtcEventLog output and audio debug dumps) and
#                     fetch only protobuf's GN files.
set -euo pipefail

DEST=${1:?usage: $0 <dest-dir> [webrtc-revision]}
REV=${2:-main}
SOFTWARE_VIDEO_CODECS=${SOFTWARE_VIDEO_CODECS:-1}
PROTOBUF=${PROTOBUF:-1}
NDK_URL=${NDK_URL:-https://dl.google.com/android/repository/android-ndk-r30-darwin.zip}
CIPD=https://chrome-infra-packages.appspot.com/dl
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$(uname -s)" != Darwin ]; then
  echo "This script is for macOS; use fetch_webrtc_android.sh on Linux." >&2
  exit 1
fi
case "$(uname -m)" in
  arm64) export CIPD_ARCH=arm64 ;;
  x86_64) export CIPD_ARCH=amd64 ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac
export CIPD_PLATFORM=mac-$CIPD_ARCH

for tool in git curl unzip python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is required (not just the Command Line Tools). Install it, then run" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
SRC=$DEST/src

# Runs a command, retrying a few times (googlesource.com intermittently 503s).
retry() {
  local i
  for i in 1 2 3 4; do
    "$@" && return
    echo "   (attempt $i failed, retrying)" >&2
    sleep $((i * 5))
  done
  "$@"
}

# Shallow-fetches <url> at <rev> into <dir>. Remaining args are sparse-checkout
# directories (cone mode), or, after --no-cone, individual file patterns; none
# means a full checkout.
git_fetch() {
  # A sparse index keeps .git/index small: Chromium's third_party has ~250k
  # files, which would otherwise cost ~36 MB of index for a sparse checkout.
  local dir=$1 url=$2 rev=$3 mode="--cone --sparse-index"
  shift 3
  if [ "${1:-}" = --no-cone ]; then
    mode=--no-cone
    shift
  fi
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then
    echo "== $dir (up to date)"
    # Re-apply the sparse patterns in case this script's list changed.
    [ $# -gt 0 ] && retry git -C "$dir" sparse-checkout set $mode "$@"
    return 0
  fi
  echo "== $dir <- $url@$rev"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote remove origin 2>/dev/null || true
  git -C "$dir" remote add origin "$url"
  if [ $# -gt 0 ]; then
    git -C "$dir" config remote.origin.partialclonefilter blob:none
    git -C "$dir" sparse-checkout set $mode "$@"
    retry git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$rev"
  else
    retry git -C "$dir" fetch -q --depth=1 origin "$rev"
  fi
  retry git -C "$dir" -c advice.detachedHead=false checkout -q -f FETCH_HEAD
}

# Downloads CIPD package <package>@<version> and unpacks it into <dir>.
cipd_fetch() {
  local dir=$1 package=$2 version=$3 stamp
  stamp="$package@$version"
  if [ "$(cat "$dir/.cipd_stamp" 2>/dev/null)" = "$stamp" ]; then
    echo "== $dir (up to date)"
    return
  fi
  echo "== $dir <- cipd $stamp"
  rm -rf "$dir"
  mkdir -p "$dir"
  retry curl -fsSL -o "$dir.zip" "$CIPD/$package/+/$version"
  unzip -q -o "$dir.zip" -d "$dir"
  rm -f "$dir.zip"
  rm -rf "$dir/.cipdpkg"
  echo "$stamp" >"$dir/.cipd_stamp"
}

# 1. WebRTC itself.
if [ "$REV" = main ]; then
  REV=$(retry git ls-remote https://webrtc.googlesource.com/src.git refs/heads/main | cut -f1)
fi
# Skip WebRTC directories gn never loads for an Android build (test media,
# iOS SDK, fuzzers, examples, desktop capture, docs; ~55 MB).
git_fetch "$SRC" https://webrtc.googlesource.com/src.git "$REV" --no-cone '/*' \
  '!/data/' '!/rtc_tools/rtc_event_log_visualizer/' '!/sdk/objc/' \
  '!/test/fuzzers/' '!/examples/' '!/modules/desktop_capture/' '!/infra/' \
  '!/docs/'

# 2. Resolve dependency URLs and versions from DEPS.
deps_query() {
  python3 - "$SRC/DEPS" "$@" <<'EOF'
import os, re, sys
deps_file, *queries = sys.argv[1:]
g = {"Var": lambda n: "{%s}" % n, "Str": str}
exec(open(deps_file).read(), g)
vars_ = g["vars"]
def expand(s):
    for _ in range(5):
        s = re.sub(r"(?<!\{)\{(\w+)\}(?!\})", lambda m: str(vars_[m.group(1)]), s)
    return s.replace("${{", "${").replace("}}", "}")
for q in queries:
    if q.startswith("var:"):
        print(expand(str(vars_[q[4:]])))
        continue
    path, _, pkg = q.partition(":")
    dep = g["deps"]["src/" + path]
    if pkg:
        for p in dep["packages"]:
            name = (expand(p["package"])
                    .replace("${platform}", os.environ["CIPD_PLATFORM"])
                    .replace("${arch}", os.environ["CIPD_ARCH"]))
            if name.startswith(pkg):
                print(name, expand(p["version"]))
                break
        else:
            sys.exit("package %s not found in %s" % (pkg, path))
    else:
        url, rev = expand(dep["url"] if isinstance(dep, dict) else dep).rsplit("@", 1)
        print(url, rev)
EOF
}

fetch_dep() {
  local path=$1
  shift
  local url rev
  read -r url rev < <(deps_query "$path")
  git_fetch "$SRC/$path" "$url" "$rev" ${1+"$@"}
}

# 3. Chromium build infrastructure (sparse where most of the repo is unused).
fetch_dep build
fetch_dep buildtools
fetch_dep testing
fetch_dep tools protoc_wrapper
# Many of these are only here so gn can load BUILD files that unbuilt targets
# reference. rust/ is ~240 MB of crates; gn only imports one .gni from it.
# mediapipe/patches stands in for mediapipe/: gn only reads its top-level
# features.gni, and cone mode includes a listed directory's parents' files.
# protobuf/ is mostly other languages: the C++ build needs src/ and
# third_party/utf8_range; with PROTOBUF=0 only its top-level GN files (which
# cone mode includes as the parent of utf8_range).
if [ "$PROTOBUF" = 0 ]; then
  PROTOBUF_DIRS="protobuf/third_party/utf8_range"
else
  PROTOBUF_DIRS="protobuf/src protobuf/third_party/utf8_range"
fi
# shellcheck disable=SC2086
fetch_dep third_party \
  abseil-cpp android_build_tools android_deps android_sdk android_toolchain \
  androidx aosp_dalvik boringssl byte_buddy catapult compiler-rt cpu_features \
  cpuinfo dav1d eigen3 farmhash fft2d flatbuffers fp16 fuzztest fxdiv gemmlowp \
  google-truth googletest hamcrest harfbuzz icu4j jdk jni_zero jsoncpp junit \
  kotlin_stdlib libaom libgav1 libjpeg_turbo libsrtp libvpx libyuv llvm-libc \
  mediapipe/patches ml_dtypes mockito nasm neon_2_sse opus/src/celt opus/src/include \
  opus/src/silk opus/src/src pffft $PROTOBUF_DIRS \
  pthreadpool re2 rnnoise robolectric rust/cxx/chromium_integration ruy \
  sframe sqlite4java tflite xnnpack zlib

# 4. Third-party code compiled into libjingle_peerconnection_so.
# Skip BoringSSL's tests, test vectors, fuzz corpora, tools and test-only deps
# (~220 MB).
fetch_dep third_party/boringssl/src --no-cone '/*' \
  '!/third_party/wycheproof_testvectors/' '!/third_party/googletest/' \
  '!/third_party/benchmark/' '!/fuzz/' '!/util/' '!/ssl/test/' \
  '!/pki/testdata/' '!test/' '!*_test.cc' '!*_test.h' '!*.txt' \
  '!/crypto/hpke/test-vectors.json'
# Only catapult's GN files are needed: //test references its histogram
# targets, so gn must be able to load them, but nothing in the .so builds them.
fetch_dep third_party/catapult --no-cone /BUILD.gn /tracing/BUILD.gn \
  /tracing/trace_viewer.gni /tracing/tracing/BUILD.gn \
  /tracing/tracing/proto/BUILD.gn /third_party/vinn/BUILD.gn
fetch_dep third_party/compiler-rt/src lib/builtins
fetch_dep third_party/cpu_features/src
fetch_dep third_party/libjpeg_turbo
fetch_dep third_party/libsrtp
fetch_dep third_party/libyuv
# nasm only assembles x86 code; gn just needs its build files.
fetch_dep third_party/nasm --no-cone /BUILD.gn /nasm_sources.gni \
  /nasm_assemble.gni
if [ "$SOFTWARE_VIDEO_CODECS" != 0 ]; then
  fetch_dep third_party/dav1d/libdav1d
  fetch_dep third_party/libaom/source/libaom
  fetch_dep third_party/libvpx/source/libvpx
fi
fetch_dep third_party/sframe/src

# abseil-cpp is in the cone-mode third_party checkout, which can't exclude
# files inside a listed directory, so delete its Windows symbol lists and tests
# (~13 MB) after checkout instead. git shows them as deleted; that's harmless.
find "$SRC/third_party/abseil-cpp" \( -path '*/testdata/*' -o -name '*_test.cc' \
  -o -name '*_test_util.*' -o -name '*_test_common.*' -o -name '*_test_helper*' \
  -o -name '*_benchmark.cc' \) -type f -delete
find "$SRC/third_party/abseil-cpp" -maxdepth 1 -name '*.def' -type f -delete

# 5. Prebuilt tools from CIPD.
read -r pkg ver < <(deps_query buildtools/mac:gn/gn/mac)
cipd_fetch "$SRC/buildtools/mac" "$pkg" "$ver"
chmod +x "$SRC/buildtools/mac/gn"

# ninja: nothing in the build invokes it by path, so any recent local one works.
if command -v ninja >/dev/null; then
  NINJA=$(command -v ninja)
else
  read -r pkg ver < <(deps_query third_party/ninja:infra/3pp/tools/ninja)
  cipd_fetch "$SRC/third_party/ninja" "$pkg" "$ver"
  chmod +x "$SRC/third_party/ninja/ninja"
  NINJA=third_party/ninja/ninja
fi

# android.jar is used to generate JNI headers for framework classes. Only
# platforms/android-<version>/ is read, so an installed Android SDK with that
# platform can stand in for the download (jni_zero hard-codes this path, so a
# symlink is needed rather than setting android_sdk_root).
read -r pkg ver < <(deps_query third_party/android_sdk/public:chromium/third_party/android_sdk/public/platforms/)
SDK_PLATFORM=${pkg##*/}
SDK_LINK=$SRC/third_party/android_sdk/public
LOCAL_SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
if [ -f "$LOCAL_SDK/platforms/$SDK_PLATFORM/android.jar" ]; then
  echo "== $SDK_LINK -> $LOCAL_SDK"
  rm -rf "$SDK_LINK"
  ln -sfn "$LOCAL_SDK" "$SDK_LINK"
else
  # The package is rooted at the SDK root (platforms/android-<version>/...).
  [ -L "$SDK_LINK" ] && rm -f "$SDK_LINK"
  cipd_fetch "$SDK_LINK" "$pkg" "$ver"
fi

# javap is used to generate JNI headers. The build expects it at
# third_party/jdk/current/bin/javap.
JDK_LINK=$SRC/third_party/jdk/current
if [ -z "${JAVA_HOME:-}" ] && /usr/libexec/java_home >/dev/null 2>&1; then
  JAVA_HOME=$(/usr/libexec/java_home)
fi
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javap" ]; then
  rm -rf "$JDK_LINK"
  ln -sfn "$JAVA_HOME" "$JDK_LINK"
elif [ "$CIPD_ARCH" = arm64 ]; then
  # Chromium's macOS JDK is an app-style bundle rooted at Contents/Home.
  read -r pkg ver < <(deps_query third_party/jdk/current:chromium/third_party/jdk)
  cipd_fetch "$SRC/third_party/jdk/mac" "$pkg" "$ver"
  chmod +x "$SRC/third_party/jdk/mac/Contents/Home/bin/"*
  rm -rf "$JDK_LINK"
  ln -sfn mac/Contents/Home "$JDK_LINK"
else
  echo "No JDK found. Chromium has no Intel-Mac JDK package; install one" >&2
  echo "(e.g. 'brew install openjdk') and set JAVA_HOME." >&2
  exit 1
fi

# 6. Android NDK: provides the compiler (for both Android and the macOS host
# tools) and the Android sysroot.
NDK_DIR=$SRC/third_party/android_toolchain/ndk
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  # DEPS pins e.g. "2@30.0.16248370". A different major version breaks the
  # build (and mixing NDKs in one out/ dir fails at link time), so refuse it.
  want=$(deps_query var:android_ndk_version)
  want=${want#*@}
  have=$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties" 2>/dev/null)
  if [ "${have%%.*}" != "${want%%.*}" ]; then
    echo "ANDROID_NDK_HOME is NDK ${have:-unknown} ($ANDROID_NDK_HOME), but" >&2
    echo "this WebRTC revision needs NDK $want. Point ANDROID_NDK_HOME at an" >&2
    echo "r${want%%.*} NDK, or unset it to download one." >&2
    exit 1
  elif [ "$have" != "$want" ]; then
    echo "Warning: using NDK $have; DEPS pins $want." >&2
  fi
  rm -rf "$NDK_DIR"
  ln -sfn "$ANDROID_NDK_HOME" "$NDK_DIR"
elif [ "$(cat "$NDK_DIR/.ndk_url" 2>/dev/null)" != "$NDK_URL" ]; then
  echo "== $NDK_DIR <- $NDK_URL"
  rm -rf "$NDK_DIR" "$NDK_DIR.tmp"
  mkdir -p "$NDK_DIR.tmp"
  retry curl -fsSL -o "$NDK_DIR.zip" "$NDK_URL"
  unzip -q "$NDK_DIR.zip" -d "$NDK_DIR.tmp"
  rm -f "$NDK_DIR.zip"
  mv "$NDK_DIR.tmp"/android-ndk-* "$NDK_DIR"
  rm -rf "$NDK_DIR.tmp"
  echo "$NDK_URL" >"$NDK_DIR/.ndk_url"
fi
# The NDK's macOS binaries are universal, under darwin-x86_64.
NDK_PREBUILT=toolchains/llvm/prebuilt/darwin-x86_64
NDK_CLANG_VERSION=$(ls "$NDK_DIR/$NDK_PREBUILT/lib/clang")

# 7. The file gclient would generate from DEPS' gclient_gn_args.
{
  echo "# Generated from 'DEPS'"
  echo "android_ndk_version = \"$(deps_query var:android_ndk_version)\""
  echo "generate_location_tags = $(deps_query var:generate_location_tags | tr A-Z a-z)"
} >"$SRC/build/config/gclient_args.gni"

# 8. Patches: allow the NDK clang and a Mac host (in //build), and drop
# WebRTC's unneeded Perfetto dependency (so third_party/perfetto isn't fetched).
apply_patch() {
  if ! git -C "$1" apply --reverse --check "$SCRIPT_DIR/$2" 2>/dev/null; then
    git -C "$1" apply "$SCRIPT_DIR/$2"
  fi
}
apply_patch "$SRC/build" build-ndk-clang.patch
apply_patch "$SRC/build" build-mac-host.patch
apply_patch "$SRC" webrtc-no-perfetto.patch
# Adds the rtc_include_software_video_codecs gn arg (default true).
apply_patch "$SRC" webrtc-optional-sw-video-codecs.patch

# 9. Build configuration.
OUT=$SRC/out/android_arm64
mkdir -p "$OUT"
if [ ! -f "$OUT/args.gn" ]; then
  cat >"$OUT/args.gn" <<EOF
target_os = "android"
target_cpu = "arm64"
is_debug = false
clang_base_path = "//third_party/android_toolchain/ndk/$NDK_PREBUILT"
clang_version = "$NDK_CLANG_VERSION"
clang_use_chrome_plugins = false
use_chromium_clang = false
use_custom_libcxx = false
use_custom_libcxx_for_host = false
use_custom_libunwind = false
enable_rust = false
rtc_rust = false
rtc_include_tests = false
rtc_build_examples = false
rtc_build_tools = false
# The NDK's lld doesn't support --read-workers (used for macOS host links).
enable_lld_read_workers = false
EOF
  if [ "$SOFTWARE_VIDEO_CODECS" = 0 ]; then
    echo "rtc_include_software_video_codecs = false" >>"$OUT/args.gn"
  fi
  if [ "$PROTOBUF" = 0 ]; then
    echo "rtc_enable_protobuf = false" >>"$OUT/args.gn"
  fi
fi

cat <<EOF

Done. To build:
  cd $SRC
  buildtools/mac/gn gen out/android_arm64
  $NINJA -C out/android_arm64 libjingle_peerconnection_so
EOF
