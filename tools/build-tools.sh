#!/bin/bash
#
# Builds the command line tools CallRec runs (ffmpeg, ffprobe, whisper-cli) from their official
# sources into one archive for the GitHub Release. setup.sh downloads that archive, checks its sha256
# and puts the tools in ~/.callrec/bin, so nobody needs Homebrew.
#
# ffmpeg is an LGPL build with no external libraries: it links only macOS frameworks. whisper-cli is
# static with the Metal shaders embedded, and built for every Apple Silicon Mac, not just this one.
# Needs the Xcode Command Line Tools and uv (cmake comes from PyPI through uvx). Apple Silicon only.
#
# Usage: tools/build-tools.sh     writes build/callrec-tools-<revision>-macos-arm64.tar.gz

set -euo pipefail

TOOLS_REVISION=1
MIN_MACOS="14.2"

FFMPEG_VERSION="9.0.2"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

WHISPER_VERSION="1.9.5"
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${WHISPER_VERSION}.tar.gz"
WHISPER_SHA256="ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"

CMAKE_VERSION="4.4.4"

FFMPEG_FLAGS=(
  --cc=clang --arch=arm64 --target-os=darwin
  "--extra-cflags=-mmacosx-version-min=$MIN_MACOS"
  "--extra-ldflags=-mmacosx-version-min=$MIN_MACOS"
  --enable-static --disable-shared
  --disable-autodetect --enable-avfoundation --enable-audiotoolbox --enable-zlib --enable-bzlib
  --disable-ffplay --disable-doc --disable-debug --disable-network
  --disable-indevs --enable-indev=avfoundation --disable-outdevs
  --disable-encoders "--enable-encoder=aac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le"
)

WHISPER_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_OSX_ARCHITECTURES=arm64 "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS"
  -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF
)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/tools"
SRC="$WORK/src"
NAME="callrec-tools-${TOOLS_REVISION}-macos-arm64"
STAGE="$WORK/$NAME"
ARCHIVE="$ROOT/build/$NAME.tar.gz"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

step() { printf '\n==> %s\n' "$1"; }
die()  { printf '\nError: %s\n' "$1" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
cmake() { uvx --quiet --from "cmake==$CMAKE_VERSION" cmake "$@"; }

check_host() {
  [ "$(uname -m)" = "arm64" ] || die "Build on an Apple Silicon Mac."
  xcode-select -p >/dev/null 2>&1 || die "Install the Xcode Command Line Tools first: xcode-select --install"
  command -v uvx >/dev/null || die "uv is needed (it provides cmake): https://docs.astral.sh/uv/"
}

fetch() {  # fetch URL SHA256 FILE
  local file="$SRC/$3"
  mkdir -p "$SRC"
  if [ ! -f "$file" ] || [ "$(sha256_of "$file")" != "$2" ]; then
    curl -fL --retry 3 --progress-bar -o "$file.part" "$1" || die "Could not download $1"
    mv -f "$file.part" "$file"
  fi
  [ "$(sha256_of "$file")" = "$2" ] || { rm -f "$file"; die "$3 failed its checksum."; }
}

unpack() {  # unpack FILE DIR
  rm -rf "$2" && mkdir -p "$2"
  tar -xf "$SRC/$1" -C "$2" --strip-components 1
}

build_ffmpeg() {
  step "ffmpeg $FFMPEG_VERSION (LGPL, macOS frameworks only)"
  fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "ffmpeg-$FFMPEG_VERSION.tar.xz"
  local src="$WORK/ffmpeg-src" prefix="$WORK/ffmpeg-out"
  unpack "ffmpeg-$FFMPEG_VERSION.tar.xz" "$src"
  rm -rf "$prefix"
  (cd "$src" && ./configure --prefix="$prefix" "${FFMPEG_FLAGS[@]}" >"$WORK/ffmpeg-configure.log" 2>&1) \
    || die "ffmpeg configure failed, see $WORK/ffmpeg-configure.log (and $src/ffbuild/config.log)"
  make -C "$src" -j "$JOBS" install >"$WORK/ffmpeg-build.log" 2>&1 || die "ffmpeg build failed, see $WORK/ffmpeg-build.log"
  cp "$prefix/bin/ffmpeg" "$prefix/bin/ffprobe" "$STAGE/bin/"
  cp "$src/COPYING.LGPLv2.1" "$STAGE/licenses/ffmpeg-LGPL-2.1.txt"
}

build_whisper() {
  step "whisper-cli $WHISPER_VERSION (static, Metal)"
  fetch "$WHISPER_URL" "$WHISPER_SHA256" "whisper.cpp-$WHISPER_VERSION.tar.gz"
  local src="$WORK/whisper-src" out="$WORK/whisper-build"
  unpack "whisper.cpp-$WHISPER_VERSION.tar.gz" "$src"
  rm -rf "$out"
  cmake -S "$src" -B "$out" "${WHISPER_FLAGS[@]}" >"$WORK/whisper-configure.log" 2>&1 \
    || die "whisper.cpp configure failed, see $WORK/whisper-configure.log"
  cmake --build "$out" --config Release -j "$JOBS" --target whisper-cli >"$WORK/whisper-build.log" 2>&1 \
    || die "whisper.cpp build failed, see $WORK/whisper-build.log"
  cp "$out/bin/whisper-cli" "$STAGE/bin/"
  cp "$src/LICENSE" "$STAGE/licenses/whisper.cpp-MIT.txt"
}

check_binaries() {
  step "Checking the binaries"
  local bin lib
  for bin in "$STAGE"/bin/*; do
    strip -x "$bin" 2>/dev/null || true
    codesign --force --sign - "$bin" >/dev/null 2>&1 || die "Could not sign $bin"
    lib="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)' || true)"
    [ -z "$lib" ] || die "$(basename "$bin") links a library that is not part of macOS: $lib"
  done
  "$STAGE/bin/ffmpeg" -hide_banner -devices 2>/dev/null | grep -q avfoundation || die "ffmpeg has no AVFoundation input."
  "$STAGE/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q ' aac ' || die "ffmpeg has no AAC encoder."
  "$STAGE/bin/whisper-cli" --help 2>&1 | grep -q -- '--vad' || die "whisper-cli has no VAD support."
  ls -l "$STAGE/bin"
}

write_sources() {
  cat >"$STAGE/SOURCES.txt" <<EOF
CallRec tools, revision $TOOLS_REVISION, built on macOS $(sw_vers -productVersion) for macOS $MIN_MACOS or newer (Apple Silicon).

ffmpeg and ffprobe $FFMPEG_VERSION, LGPL 2.1 (licenses/ffmpeg-LGPL-2.1.txt)
  source: $FFMPEG_URL
  sha256: $FFMPEG_SHA256
  configure: ${FFMPEG_FLAGS[*]}

whisper-cli from whisper.cpp $WHISPER_VERSION, MIT (licenses/whisper.cpp-MIT.txt)
  source: $WHISPER_URL
  sha256: $WHISPER_SHA256
  cmake: ${WHISPER_FLAGS[*]}

Build script: tools/build-tools.sh in https://github.com/shacharPash/callrec
EOF
}

main() {
  check_host
  rm -rf "$STAGE"
  mkdir -p "$STAGE/bin" "$STAGE/licenses"
  build_ffmpeg
  build_whisper
  check_binaries
  write_sources
  rm -f "$ARCHIVE"
  tar -czf "$ARCHIVE" -C "$WORK" "$NAME"
  printf '\n%s\nsha256 %s\n' "$ARCHIVE" "$(sha256_of "$ARCHIVE")"
}

[ "${CALLREC_BUILD_NO_MAIN:-}" = "1" ] || main "$@"
