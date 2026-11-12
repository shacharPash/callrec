#!/bin/bash
#
# CallRec setup: installs what the app and the callrec command need into ~/.callrec, with no Homebrew
# and no admin password: uv (runs the Python engine), ffmpeg, ffprobe and whisper-cli, the Hebrew and
# English transcription models and the silence filter, the engine itself, and the callrec command.
# Every download is pinned and checked with sha256, interrupted downloads resume, and an ivrit.ai model
# you already have from OpenSuperWhisper or Vibe is reused. Safe to re-run.
#
# install.sh and the app's "Finish setup" run this. From a clone of the repo you can run it directly.
#
# Usage: bash setup.sh

set -euo pipefail

RELEASE_URL="${CALLREC_RELEASE_URL:-https://github.com/shacharPash/callrec/releases/download}"

UV_VERSION="0.13.7"
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-aarch64-apple-darwin.tar.gz"
UV_SHA256="81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"

TOOLS_REVISION=1
TOOLS_TAG="v1.1"
TOOLS_NAME="callrec-tools-${TOOLS_REVISION}-macos-arm64"
TOOLS_SHA256="7cc8cdc02a0964cc251f0eeccabcd40740dae6d7f9f7b532e5f8a20d4ae13ffd"
TOOLS=(ffmpeg ffprobe whisper-cli)

HF="https://huggingface.co"
HE_FILE="ivrit-whisper-large-v3-turbo.bin"
HE_URL="$HF/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/2130c78e4a9cb4914cc4df91a1c3031407789705/ggml-model.bin"
HE_SHA256="c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"
HE_BYTES=1624555275
EN_FILE="ggml-large-v3-turbo-q8_0.bin"
EN_URL="$HF/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q8_0.bin"
EN_SHA256="317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
EN_BYTES=874188075
VAD_FILE="ggml-silero-v5.1.2.bin"
VAD_URL="$HF/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"
VAD_SHA256="29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
VAD_BYTES=885098

USER_PATH="$PATH"
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.callrec"
BIN_DIR="$STATE_DIR/bin"
ENGINE_DIR="$STATE_DIR/engine"
MODEL_DIR="$STATE_DIR/models"
APP_SUPPORT="$HOME/Library/Application Support"
HE_REUSE=(
  "$APP_SUPPORT/ru.starmel.OpenSuperWhisper/whisper-models/ggml-ivrit-large-v3-turbo.bin"
  "$APP_SUPPORT/github.com.thewh1teagle.vibe/ggml-ivrit-large-v3-turbo.bin"
)

WORK_DIR=""
PATH_HINT=0

if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
ok()   { printf '  %sok%s  %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!!%s  %s\n' "$YELLOW" "$RESET" "$1"; }
die()  { printf '\n%sError:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

sha256_of()  { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes() { stat -f %z "$1"; }

version_lt() {
  local IFS=. i x y
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2 3; do
    x="${a[$i]:-0}"; x="${x%%[!0-9]*}"; x="${x:-0}"
    y="${b[$i]:-0}"; y="${y%%[!0-9]*}"; y="${y:-0}"
    [ "$x" -lt "$y" ] && return 0
    [ "$x" -gt "$y" ] && return 1
  done
  return 1
}

verified() {  # verified FILE SHA256 BYTES
  [ -f "$1" ] && [ "$(file_bytes "$1")" = "$3" ] && [ "$(sha256_of "$1")" = "$2" ]
}

ensure_work_dir() {
  [ -n "$WORK_DIR" ] && return 0
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/callrec-setup.XXXXXX")" || die "Could not create a temporary folder."
}

recording_now() { pgrep -qf 'ffmpeg .*-f avfoundation'; }

download() {  # download URL FILE SHA256 LABEL
  curl -fL --retry 3 --progress-bar -o "$2" "$1" \
    || die "Could not download $4. Check your internet connection and run the same command again."
  [ "$(sha256_of "$2")" = "$3" ] || die "The downloaded $4 failed its checksum."
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        printf 'Usage: setup.sh\n'
        printf '  Installs the tools, models and the callrec command into ~/.callrec. Safe to re-run.\n'
        exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

check_platform() {
  step "Checking this Mac"
  [ "$(uname -s)" = "Darwin" ] || die "CallRec is for macOS only."
  if [ "$(uname -m)" != "arm64" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
    die "CallRec needs an Apple Silicon Mac (M1 or newer)."
  fi
  local version
  version="$(sw_vers -productVersion)"
  ! version_lt "$version" "14.2" || die "CallRec needs macOS 14.2 or newer. This Mac runs macOS $version."
  ok "Apple Silicon, macOS $version"
}

install_uv() {
  step "uv $UV_VERSION (runs CallRec's Python engine)"
  mkdir -p "$BIN_DIR"
  local installed=""
  if [ -x "$BIN_DIR/uv" ]; then
    installed="$("$BIN_DIR/uv" --version 2>/dev/null | awk '{print $2}' || true)"
    if [ -n "$installed" ] && ! version_lt "$installed" "$UV_VERSION"; then
      ok "Up to date: version $installed"
      return 0
    fi
  fi
  ensure_work_dir
  local dir="$WORK_DIR/uv" archive="$WORK_DIR/uv.tar.gz"
  download "$UV_URL" "$archive" "$UV_SHA256" "uv"
  mkdir -p "$dir"
  tar -xzf "$archive" -C "$dir" --strip-components 1 || die "Could not unpack uv."
  mv -f "$dir/uv" "$dir/uvx" "$BIN_DIR/"
  ok "Installed uv $UV_VERSION in $BIN_DIR"
}

tools_present() {
  local tool
  [ "$(cat "$BIN_DIR/.tools-sha256" 2>/dev/null)" = "$TOOLS_SHA256" ] || return 1
  for tool in "${TOOLS[@]}"; do
    [ -x "$BIN_DIR/$tool" ] || return 1
  done
}

install_tools() {
  step "ffmpeg and whisper-cli (CallRec tools revision $TOOLS_REVISION)"
  if tools_present; then
    ok "Up to date"
    return 0
  fi
  ensure_work_dir
  local dir="$WORK_DIR" archive="$WORK_DIR/$TOOLS_NAME.tar.gz" tool
  download "$RELEASE_URL/$TOOLS_TAG/$TOOLS_NAME.tar.gz" "$archive" "$TOOLS_SHA256" "CallRec tools"
  tar -xzf "$archive" -C "$dir" || die "Could not unpack the CallRec tools."
  for tool in "${TOOLS[@]}"; do
    [ -f "$dir/$TOOLS_NAME/bin/$tool" ] || die "The CallRec tools archive has no $tool."
    chmod +x "$dir/$TOOLS_NAME/bin/$tool"
    mv -f "$dir/$TOOLS_NAME/bin/$tool" "$BIN_DIR/$tool"
  done
  rm -rf "$STATE_DIR/licenses"
  mkdir -p "$STATE_DIR/licenses"
  cp -R "$dir/$TOOLS_NAME/licenses/." "$dir/$TOOLS_NAME/SOURCES.txt" "$STATE_DIR/licenses/"
  printf '%s\n' "$TOOLS_SHA256" > "$BIN_DIR/.tools-sha256"
  ok "Installed ${TOOLS[*]} in $BIN_DIR"
}

check_disk_space() {  # check_disk_space PART BYTES
  local have=0 free_kb need_kb
  [ -f "$1" ] && have="$(file_bytes "$1")"
  free_kb="$(df -k "$MODEL_DIR" | awk 'NR==2 {print $4}')"
  need_kb=$(( ($2 - have) / 1024 + 512000 ))
  [ "$free_kb" -ge "$need_kb" ] || die "Not enough free disk space. About $(( need_kb / 1024 / 1024 + 1 )) GB is needed for the models."
}

install_model() {  # install_model LABEL FILE URL SHA256 BYTES [FILE_TO_REUSE...]
  local label="$1" file="$2" url="$3" sha="$4" bytes="$5" src
  shift 5
  local dest="$MODEL_DIR/$file" part="$MODEL_DIR/$file.part"

  if [ -f "$dest" ]; then
    if verified "$dest" "$sha" "$bytes"; then
      ok "$label: verified"
      return 0
    fi
    warn "$label: out of date or damaged, getting it again (the old file stays until the new one is verified)"
  fi

  for src in "$@"; do
    if verified "$src" "$sha" "$bytes"; then
      rm -f "$dest.tmp"
      ln "$src" "$dest.tmp" 2>/dev/null || cp -c "$src" "$dest.tmp" 2>/dev/null || cp "$src" "$dest.tmp" \
        || die "Could not copy the $label from $(dirname "$src")."
      mv -f "$dest.tmp" "$dest"
      ok "$label: reused from $(dirname "$src")"
      return 0
    fi
  done

  if [ -f "$part" ] && [ "$(file_bytes "$part")" -gt "$bytes" ]; then
    rm -f "$part"
  fi
  check_disk_space "$part" "$bytes"
  if [ ! -f "$part" ] || [ "$(file_bytes "$part")" -lt "$bytes" ]; then
    printf '  downloading %s...\n' "$label"
    curl -fL -C - --retry 5 --retry-delay 3 --progress-bar -o "$part" "$url" \
      || die "The $label download was interrupted. Run the same command again, it resumes where it stopped."
  fi
  if ! verified "$part" "$sha" "$bytes"; then
    rm -f "$part"
    die "The downloaded $label failed its checksum and was deleted. Run the same command again."
  fi
  mv -f "$part" "$dest"
  ok "$label: saved"
}

install_models() {
  step "Transcription models (about 2.5 GB, downloaded once)"
  mkdir -p "$MODEL_DIR"
  install_model "Hebrew model (ivrit.ai)" "$HE_FILE" "$HE_URL" "$HE_SHA256" "$HE_BYTES" "${HE_REUSE[@]}"
  install_model "English model (Whisper large-v3-turbo)" "$EN_FILE" "$EN_URL" "$EN_SHA256" "$EN_BYTES"
  install_model "Silence filter (Silero VAD)" "$VAD_FILE" "$VAD_URL" "$VAD_SHA256" "$VAD_BYTES"
}

install_engine() {
  step "CallRec engine"
  local src="$HERE/callrec" dst="$ENGINE_DIR/callrec"
  [ -f "$src" ] || die "The CallRec engine (callrec) is missing next to $0."
  mkdir -p "$ENGINE_DIR"
  if [ "$src" != "$dst" ] && { [ ! -f "$dst" ] || { ! cmp -s "$src" "$dst" && [ "$src" -nt "$dst" ]; }; }; then
    cp -p "$src" "$dst"
    ok "Installed in $ENGINE_DIR"
  else
    ok "Up to date"
  fi
  chmod +x "$dst"
  rm -f "$ENGINE_DIR/install.sh"

  cat > "$BIN_DIR/callrec" <<EOF
#!/bin/sh
export PATH="$BIN_DIR:\$PATH"
exec "$dst" "\$@"
EOF
  chmod +x "$BIN_DIR/callrec"
}

link_command() {
  step "The callrec command"
  local dir current
  current="$(PATH="$USER_PATH" command -v callrec 2>/dev/null || true)"
  if [ -n "$current" ]; then
    if [ "$current" -ef "$BIN_DIR/callrec" ]; then
      ok "callrec works in any new Terminal window"
    else
      warn "Kept your existing callrec command at $current"
    fi
    return 0
  fi
  for dir in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin" "$HOME/bin"; do
    case ":$USER_PATH:" in *":$dir:"*) ;; *) continue ;; esac
    [ -d "$dir" ] && [ -w "$dir" ] || continue
    ln -sf "$BIN_DIR/callrec" "$dir/callrec"
    ok "Linked $dir/callrec"
    return 0
  done
  PATH_HINT=1
  ok "Installed at $BIN_DIR/callrec"
}

warm_up() {
  step "Checking setup (the first time, uv also downloads Python, about 30 MB)"
  "$BIN_DIR/callrec" doctor || warn "Something is missing, see the list above."
  hash -r 2>/dev/null || true
}

print_done() {
  printf '\n%sSetup is complete.%s\n' "$BOLD" "$RESET"
  if [ "$PATH_HINT" = "1" ]; then
    cat <<'EOF'
To use the callrec command in the Terminal too, run this once and open a new Terminal window:
  echo 'export PATH="$HOME/.callrec/bin:$PATH"' >> ~/.zprofile
EOF
  fi
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  printf '%sCallRec setup%s\n' "$BOLD" "$RESET"
  check_platform
  ! recording_now || die "A call is being recorded right now. Run this again when the call is over."
  install_uv
  install_tools
  install_models
  install_engine
  link_command
  warm_up
  print_done
}

[ "${CALLREC_SETUP_NO_MAIN:-}" = "1" ] || main "$@"
