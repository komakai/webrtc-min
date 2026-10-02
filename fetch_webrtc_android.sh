#!/usr/bin/env bash
# Fetches the minimal WebRTC checkout needed to build
# //sdk/android:libjingle_peerconnection_so for Android with the Android NDK
# compiler. No depot_tools / gclient / cipd needed: only git, curl, unzip and
# python3.
#
# Usage: fetch_webrtc_android.sh <dest-dir> [webrtc-revision]
#   webrtc-revision defaults to the tip of main.
# Environment:
#   ANDROID_NDK_HOME  use an existing NDK instead of downloading one.
#   NDK_URL           NDK zip to download (default: r30, matching DEPS).
#   JAVA_HOME         use an existing JDK (for javap) instead of downloading.
set -euo pipefail

DEST=${1:?usage: $0 <dest-dir> [webrtc-revision]}
REV=${2:-main}
NDK_URL=${NDK_URL:-https://dl.google.com/android/repository/android-ndk-r30-linux.zip}
CIPD=https://chrome-infra-packages.appspot.com/dl
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
SRC=$DEST/src

# Shallow-fetches <url> at <rev> into <dir>. Remaining args are sparse-checkout
# directories (cone mode); none means a full checkout.
git_fetch() {
  local dir=$1 url=$2 rev=$3
  shift 3
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then
    echo "== $dir (up to date)"
    return
  fi
  echo "== $dir <- $url@$rev"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote remove origin 2>/dev/null || true
  git -C "$dir" remote add origin "$url"
  if [ $# -gt 0 ]; then
    git -C "$dir" config remote.origin.partialclonefilter blob:none
    git -C "$dir" sparse-checkout set --cone "$@"
    git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$rev"
  else
    git -C "$dir" fetch -q --depth=1 origin "$rev"
  fi
  git -C "$dir" -c advice.detachedHead=false checkout -q -f FETCH_HEAD
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
  curl -fsSL -o "$dir.zip" "$CIPD/$package/+/$version"
  unzip -q -o "$dir.zip" -d "$dir"
  rm -f "$dir.zip"
  rm -rf "$dir/.cipdpkg"
  echo "$stamp" >"$dir/.cipd_stamp"
}

# 1. WebRTC itself.
if [ "$REV" = main ]; then
  REV=$(git ls-remote https://webrtc.googlesource.com/src.git refs/heads/main | cut -f1)
fi
git_fetch "$SRC" https://webrtc.googlesource.com/src.git "$REV"

# 2. Resolve dependency URLs and versions from DEPS.
deps_query() {
  python3 - "$SRC/DEPS" "$@" <<'EOF'
import re, sys
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
            name = expand(p["package"]).replace("${platform}", "linux-amd64").replace("${arch}", "amd64")
            if not pkg or name.startswith(pkg):
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
fetch_dep third_party \
  abseil-cpp android_build_tools android_deps android_sdk android_toolchain \
  androidx aosp_dalvik boringssl byte_buddy catapult compiler-rt cpu_features \
  cpuinfo dav1d eigen3 farmhash fft2d flatbuffers fp16 fuzztest fxdiv gemmlowp \
  google-truth googletest hamcrest harfbuzz icu4j jdk jni_zero jsoncpp junit \
  kotlin_stdlib libaom libgav1 libjpeg_turbo libsrtp libvpx libyuv llvm-libc \
  mediapipe ml_dtypes mockito nasm neon_2_sse opus perfetto pffft protobuf \
  pthreadpool re2 rnnoise robolectric rust ruy sframe sqlite4java tflite \
  xnnpack zlib

# 4. Third-party code compiled into libjingle_peerconnection_so.
fetch_dep third_party/boringssl/src
fetch_dep third_party/catapult tracing third_party/vinn
fetch_dep third_party/compiler-rt/src lib/builtins
fetch_dep third_party/cpu_features/src
fetch_dep third_party/dav1d/libdav1d
fetch_dep third_party/libaom/source/libaom
fetch_dep third_party/libjpeg_turbo
fetch_dep third_party/libsrtp
fetch_dep third_party/libvpx/source/libvpx
fetch_dep third_party/libyuv
fetch_dep third_party/nasm
fetch_dep third_party/perfetto

# 5. Prebuilt tools from CIPD.
read -r pkg ver < <(deps_query buildtools/linux64:gn/gn/linux)
cipd_fetch "$SRC/buildtools/linux64" "$pkg" "$ver"
chmod +x "$SRC/buildtools/linux64/gn"

read -r pkg ver < <(deps_query third_party/ninja:infra/3pp/tools/ninja)
cipd_fetch "$SRC/third_party/ninja" "$pkg" "$ver"
chmod +x "$SRC/third_party/ninja/ninja"

# android.jar is used to generate JNI headers for framework classes.
read -r pkg ver < <(deps_query third_party/android_sdk/public:chromium/third_party/android_sdk/public/platforms/android-37.0)
# The package is rooted at the SDK root (platforms/android-37.0/...).
cipd_fetch "$SRC/third_party/android_sdk/public" "$pkg" "$ver"

# javap is used to generate JNI headers.
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javap" ]; then
  rm -rf "$SRC/third_party/jdk/current"
  ln -sfn "$JAVA_HOME" "$SRC/third_party/jdk/current"
else
  read -r pkg ver < <(deps_query third_party/jdk/current:chromium/third_party/jdk)
  cipd_fetch "$SRC/third_party/jdk/current" "$pkg" "$ver"
  chmod +x "$SRC/third_party/jdk/current/bin/"*
fi

# 6. Android NDK: provides both the compiler and the sysroot.
NDK_DIR=$SRC/third_party/android_toolchain/ndk
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  rm -rf "$NDK_DIR"
  ln -sfn "$ANDROID_NDK_HOME" "$NDK_DIR"
elif [ "$(cat "$NDK_DIR/.ndk_url" 2>/dev/null)" != "$NDK_URL" ]; then
  echo "== $NDK_DIR <- $NDK_URL"
  rm -rf "$NDK_DIR" "$NDK_DIR.tmp"
  mkdir -p "$NDK_DIR.tmp"
  curl -fsSL -o "$NDK_DIR.zip" "$NDK_URL"
  unzip -q "$NDK_DIR.zip" -d "$NDK_DIR.tmp"
  rm -f "$NDK_DIR.zip"
  mv "$NDK_DIR.tmp"/android-ndk-* "$NDK_DIR"
  rm -rf "$NDK_DIR.tmp"
  echo "$NDK_URL" >"$NDK_DIR/.ndk_url"
fi
NDK_CLANG_VERSION=$(ls "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/lib/clang")

# 7. Host sysroot, used to build host tools such as protoc.
python3 "$SRC/build/linux/sysroot_scripts/install-sysroot.py" --arch=amd64

# 8. The file gclient would generate from DEPS' gclient_gn_args.
{
  echo "# Generated from 'DEPS'"
  echo "android_ndk_version = \"$(deps_query var:android_ndk_version)\""
  echo "generate_location_tags = $(deps_query var:generate_location_tags | tr A-Z a-z)"
} >"$SRC/build/config/gclient_args.gni"

# 9. Build config patch allowing the NDK clang to be used.
if ! git -C "$SRC/build" apply --reverse --check "$SCRIPT_DIR/build-ndk-clang.patch" 2>/dev/null; then
  git -C "$SRC/build" apply "$SCRIPT_DIR/build-ndk-clang.patch"
fi

# 10. Build configuration.
OUT=$SRC/out/android_arm64
mkdir -p "$OUT"
if [ ! -f "$OUT/args.gn" ]; then
  cat >"$OUT/args.gn" <<EOF
target_os = "android"
target_cpu = "arm64"
is_debug = false
clang_base_path = "//third_party/android_toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64"
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
EOF
fi

cat <<EOF

Done. To build:
  cd $SRC
  buildtools/linux64/gn gen out/android_arm64
  third_party/ninja/ninja -C out/android_arm64 libjingle_peerconnection_so
EOF
