#!/usr/bin/env bash
# Fetches the minimal WebRTC checkout needed to build WebRTC.xcframework
# (//sdk:framework_objc) for iOS with Xcode's own clang. No depot_tools /
# gclient / cipd needed: only git, curl, unzip, python3 and Xcode.
#
# Usage: fetch_webrtc_ios.sh <dest-dir> [webrtc-revision]
#   webrtc-revision defaults to the tip of main.
# Then build with build_webrtc_ios.sh <dest-dir>.
set -euo pipefail

DEST=${1:?usage: $0 <dest-dir> [webrtc-revision]}
REV=${2:-main}
CIPD=https://chrome-infra-packages.appspot.com/dl
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$(uname -s)" != Darwin ]; then
  echo "iOS builds need macOS and Xcode." >&2
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
# Skip WebRTC directories gn never loads for an iOS build (test media,
# Android SDK, fuzzers, examples, desktop capture, docs).
git_fetch "$SRC" https://webrtc.googlesource.com/src.git "$REV" --no-cone '/*' \
  '!/data/' '!/rtc_tools/rtc_event_log_visualizer/' '!/sdk/android/' \
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
# reference (see fetch_webrtc_android_mac.sh for details).
fetch_dep third_party \
  abseil-cpp boringssl catapult compiler-rt cpu_features cpuinfo dav1d eigen3 \
  farmhash fft2d flatbuffers fp16 fuzztest fxdiv gemmlowp googletest \
  harfbuzz jsoncpp libaom libgav1 libsrtp libvpx libyuv \
  llvm-libc mediapipe/patches ml_dtypes nasm neon_2_sse coremltools \
  opus/src/celt opus/src/include opus/src/silk opus/src/src pffft \
  protobuf/src protobuf/third_party/utf8_range pthreadpool re2 rnnoise \
  rust/cxx/chromium_integration ruy sframe tflite xnnpack zlib

# 4. Third-party code compiled into the framework.
fetch_dep third_party/boringssl/src --no-cone '/*' \
  '!/third_party/wycheproof_testvectors/' '!/third_party/googletest/' \
  '!/third_party/benchmark/' '!/fuzz/' '!/util/' '!/ssl/test/' \
  '!/pki/testdata/' '!test/' '!*_test.cc' '!*_test.h' '!*.txt' \
  '!/crypto/hpke/test-vectors.json'
fetch_dep third_party/catapult --no-cone /BUILD.gn /tracing/BUILD.gn \
  /tracing/trace_viewer.gni /tracing/tracing/BUILD.gn \
  /tracing/tracing/proto/BUILD.gn /third_party/vinn/BUILD.gn
fetch_dep third_party/compiler-rt/src lib/builtins
fetch_dep third_party/cpu_features/src
# The codec repos without their tests, docs, tools and vendored copies of
# other libraries (~25 MB). Other CPUs' assembly is kept, except for CPUs no
# Android or Apple device uses.
fetch_dep third_party/dav1d/libdav1d --no-cone '/*' '!/src/loongarch/' \
  '!/src/riscv/' '!/src/ppc/'
fetch_dep third_party/libaom/source/libaom --no-cone '/*' '!/test/' '!/doc/' \
  '!/tools/' '!/examples/' '!/third_party/highway/' '!/third_party/libyuv/' \
  '!/third_party/googletest/' '!/third_party/libwebm/'
fetch_dep third_party/libvpx/source/libvpx --no-cone '/*' '!/test/' \
  '!/build_debug/' '!/tools/' '!/third_party/libyuv/' \
  '!/third_party/googletest/' '!/third_party/libwebm/'
fetch_dep third_party/libsrtp
fetch_dep third_party/libyuv
fetch_dep third_party/nasm --no-cone /BUILD.gn /nasm_sources.gni \
  /nasm_assemble.gni
fetch_dep third_party/sframe/src

find "$SRC/third_party/abseil-cpp" \( -path '*/testdata/*' -o -name '*_test.cc' \
  -o -name '*_test_util.*' -o -name '*_test_common.*' -o -name '*_test_helper*' \
  -o -name '*_benchmark.cc' \) -type f -delete
find "$SRC/third_party/abseil-cpp" -maxdepth 1 -name '*.def' -type f -delete

# 5. gn from CIPD; ninja from PATH if available.
read -r pkg ver < <(deps_query buildtools/mac:gn/gn/mac)
cipd_fetch "$SRC/buildtools/mac" "$pkg" "$ver"
chmod +x "$SRC/buildtools/mac/gn"
if ! command -v ninja >/dev/null; then
  read -r pkg ver < <(deps_query third_party/ninja:infra/3pp/tools/ninja)
  cipd_fetch "$SRC/third_party/ninja" "$pkg" "$ver"
  chmod +x "$SRC/third_party/ninja/ninja"
fi

# 6. The file gclient would generate from DEPS' gclient_gn_args.
{
  echo "# Generated from 'DEPS'"
  echo "generate_location_tags = $(deps_query var:generate_location_tags | tr A-Z a-z)"
} >"$SRC/build/config/gclient_args.gni"

# 7. Patches.
apply_patch() {
  if ! git -C "$1" apply --reverse --check "$SCRIPT_DIR/$2" 2>/dev/null; then
    git -C "$1" apply "$SCRIPT_DIR/$2"
  fi
}
# build-ndk-clang.patch makes //build work with a clang other than Chromium's
# pinned one (use_chromium_clang = false); build-xcode-clang.patch points the
# Apple toolchains at Xcode's linker, strip, install_name_tool and dsymutil.
apply_patch "$SRC/build" build-ndk-clang.patch
apply_patch "$SRC/build" build-xcode-clang.patch
apply_patch "$SRC" webrtc-no-perfetto.patch

echo
echo "Done. To build WebRTC.xcframework: $SCRIPT_DIR/build_webrtc_ios.sh $DEST"
