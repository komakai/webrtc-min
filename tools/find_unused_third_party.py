#!/usr/bin/env python3
"""Lists the third-party source files WebRTC never links, for WEBRTC_MIN.

Takes an Android arm64 and an iOS arm64 CMake build directory of webrtc-min
(both built, with WEBRTC_MIN off so that every file is compiled), relinks each
library with the linker reporting which archive members it loads (lld
--why-extract, ld64 -map), and prints, per library, the files neither linker
loaded: the webrtc_min_exclude() lists in third_party/CMakeLists.txt. Files
with CPU- or OS-specific code are never listed, as another ABI may need them,
and assembly is left to the per-OS filter in that file.

  tools/find_unused_third_party.py out/arm64 out/ios-arm64
"""
import collections
import os
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/"

# CMake target -> its source directory, for the libraries trimmed.
LIBRARIES = {
    "absl": "third_party/abseil-cpp/",
    "boringssl": "third_party/boringssl/src/",
    "libyuv": "third_party/libyuv/",
    "opus": "third_party/opus/",
    "sframe": "third_party/sframe/src/",
}

# CPU- or OS-specific code: kept even when unused on Android/iOS arm64.
KEEP = re.compile(r"""(
  \.S$ |
  /cpu_[a-z0-9_]+\.cc$ | /rand/ | /thread[a-z_]*\.cc$ |
  poly1305_(arm|vec) | _adx\.cc$ |
  cpu_detect | unscaledcycleclock | crc_memcpy | crc_non_temporal |
  _waiter\.cc$ | vdso_support | elf_mem_image | address_is_readable |
  _(gcc|neon|neon64|win|rvv|msa|lsx|lasx|sve|sme)\.cc$ |
  /arm/ | /x86/ | _neon | _sse | _avx
)""", re.X)


def link_command(build_dir, output):
    out = subprocess.run(["ninja", "-C", build_dir, "-t", "commands", output],
                         capture_output=True, text=True, check=True).stdout
    command = out.strip().splitlines()[-1]
    return command.split("&& ", 1)[1].split(" && ")[0]


def loaded_members(build_dir, output, flag):
    """Relinks <output> with <flag> (a format string taking a file name) and
    returns the 'libfoo.a(member.o)' entries the linker loaded."""
    with tempfile.TemporaryDirectory() as tmp:
        report = os.path.join(tmp, "report")
        command = link_command(build_dir, output).replace(
            "-o " + output + " ",
            "-o %s %s " % (os.path.join(tmp, "out"), flag % report))
        subprocess.run(command, shell=True, cwd=build_dir, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        text = open(report, errors="replace").read()
    return set(re.findall(r"([^/\s]+\.a\([^)]+\))", text))


def library_sources(build_dir):
    """Maps each third-party source file to (archive, archive member)."""
    ninja = open(os.path.join(build_dir, "build.ninja")).read()
    obj_to_src = {
        m.group(1): m.group(2).replace(ROOT, "")
        for m in re.finditer(r"^build ([^ :]+\.o): \S+ (\S+)", ninja, re.M)
    }
    sources = {}
    for m in re.finditer(r"^build (third_party/[^ :]+\.a): \S+ ([^|\n]+)",
                         ninja, re.M):
        archive = os.path.basename(m.group(1))
        for obj in m.group(2).split():
            if obj.endswith(".o"):
                sources[obj_to_src.get(obj, obj)] = (
                    archive, os.path.basename(obj))
    return sources


def absl_non_min_sources():
    """abseil-cpp's CMakeLists.txt already leaves these out with WEBRTC_MIN
    (the Abseil targets WebRTC doesn't depend on)."""
    text = open(ROOT + "third_party/abseil-cpp/CMakeLists.txt").read()
    block = text.split("if(NOT WEBRTC_MIN)", 1)[1].split("\nendif()", 1)[0]
    return set(LIBRARIES["absl"] + f for f in re.findall(r"^\s+(\S+\.cc)$",
                                                        block, re.M))


def main():
    android, ios = sys.argv[1:3]
    used = set()
    for build_dir, output, flag in (
        (android, "webrtc/sdk/libjingle_peerconnection_so.so",
         "-Wl,--why-extract=%s"),
        (ios, "webrtc/sdk/WebRTC.framework/WebRTC", "-Wl,-map,%s"),
    ):
        loaded = loaded_members(build_dir, output, flag)
        for src, (archive, member) in library_sources(build_dir).items():
            if "%s(%s)" % (archive, member) in loaded:
                used.add(src)
    sources = set(library_sources(android)) | set(library_sources(ios))
    sources -= absl_non_min_sources()
    unused = collections.defaultdict(list)
    for src in sorted(sources - used):
        for target, directory in LIBRARIES.items():
            if src.startswith(directory) and not KEEP.search(src):
                unused[target].append(src[len(directory):])
    for target in LIBRARIES:
        print("  webrtc_min_exclude(%s" % target)
        for src in unused[target]:
            print("    " + src)
        print("  )")


if __name__ == "__main__":
    main()
