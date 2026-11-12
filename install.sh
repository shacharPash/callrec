#!/bin/bash
#
# CallRec: record every call on your Mac and get a transcript, automatically. Free and fully local.
# One-command install: installs or updates the CallRec app from the GitHub Release, runs its setup
# (tools and transcription models into ~/.callrec, no Homebrew, no admin password) and opens it.
# Safe to re-run: the same command installs and updates. Apple Silicon, macOS 14.2 or newer.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/shacharPash/callrec/main/install.sh)"
#   bash install.sh [--no-open]

set -euo pipefail

APP_NAME="CallRec"
APP_VERSION="1.1"
APP_BUNDLE_ID="app.callrec.CallRec"
APP_ZIP_SHA256="5fb75994135a407ce4755345decbb1ce9d157f601ef4e6a8b161503c2294ace9"
RELEASE_URL="${CALLREC_RELEASE_URL:-https://github.com/shacharPash/callrec/releases/download}"
APP_DIR="/Applications"

USER_PATH="$PATH"
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

OPEN_APP=1
APP_PATH=""
APP_WAS_RUNNING=0
WORK_DIR=""

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

sha256_of()   { shasum -a 256 "$1" | awk '{print $1}'; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

app_version() {
  local version
  version="$(plist_value "$1" CFBundleShortVersionString)"
  printf '%s\n' "${version:-0}"
}

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

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-open) OPEN_APP=0 ;;
      -h|--help)
        printf 'Usage: install.sh [--no-open]\n'
        printf '  Installs or updates CallRec, its tools and its transcription models, then opens it.\n'
        printf '  --no-open  do not open the app at the end\n'
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

find_app() {
  local dir
  for dir in "$APP_DIR" "$HOME/Applications"; do
    if [ -d "$dir/$APP_NAME.app" ]; then
      printf '%s\n' "$dir/$APP_NAME.app"
      return 0
    fi
  done
  return 1
}

app_running()   { pgrep -xq "$APP_NAME"; }
recording_now() { pgrep -qf 'ffmpeg .*-f avfoundation'; }

verify_app() {
  local app="$1" id version
  id="$(plist_value "$app" CFBundleIdentifier)"
  [ "$id" = "$APP_BUNDLE_ID" ] || die "The downloaded app is not $APP_NAME (bundle id '$id')."
  version="$(app_version "$app")"
  [ "$version" = "$APP_VERSION" ] || die "The downloaded app is version $version, expected $APP_VERSION."
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 || die "The signature of the downloaded $APP_NAME is broken."
}

refuse_while_recording() {
  if app_running && recording_now; then
    die "$APP_NAME is recording a call right now. Run the same command again when the call is over."
  fi
}

quit_app_if_running() {
  app_running || return 0
  APP_WAS_RUNNING=1
  osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local waited=0
  while [ "$waited" -lt 20 ]; do
    app_running || return 0
    sleep 1
    waited=$((waited + 1))
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 1
}

install_app() {
  step "$APP_NAME app"
  refuse_while_recording
  local existing="" installed="" target_dir="$APP_DIR"
  if existing="$(find_app)"; then
    installed="$(app_version "$existing")"
    if ! version_lt "$installed" "$APP_VERSION"; then
      APP_PATH="$existing"
      ok "Up to date: version $installed at $APP_PATH"
      return 0
    fi
    target_dir="$(dirname "$existing")"
    printf '  updating %s -> %s\n' "$installed" "$APP_VERSION"
  fi

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/callrec-install.XXXXXX")" || die "Could not create a temporary folder."
  local zip="$WORK_DIR/$APP_NAME.zip"
  curl -fL --retry 3 --progress-bar -o "$zip" "$RELEASE_URL/v$APP_VERSION/$APP_NAME.zip" \
    || die "Could not download $APP_NAME. Check your internet connection and run the same command again."
  [ "$(sha256_of "$zip")" = "$APP_ZIP_SHA256" ] || die "The downloaded $APP_NAME failed its checksum."
  ditto -x -k "$zip" "$WORK_DIR/unzipped" || die "Could not unpack $APP_NAME."
  local src="$WORK_DIR/unzipped/$APP_NAME.app"
  [ -d "$src" ] || die "The download does not contain $APP_NAME.app."
  verify_app "$src"

  if [ ! -w "$target_dir" ]; then
    [ -z "$existing" ] || die "No write access to $target_dir to update $APP_NAME."
    target_dir="$HOME/Applications"
    mkdir -p "$target_dir"
    warn "No write access to $APP_DIR, installing into $target_dir instead"
  fi

  local staged="$target_dir/.$APP_NAME.app.new"
  rm -rf "$staged"
  ditto "$src" "$staged" || die "Could not copy $APP_NAME into $target_dir."

  if app_running && recording_now; then
    rm -rf "$staged"
    die "A call started while downloading. $APP_NAME was left as it was; run the same command again when the call is over."
  fi
  quit_app_if_running
  rm -rf "${target_dir:?}/$APP_NAME.app"
  mv "$staged" "$target_dir/$APP_NAME.app"

  APP_PATH="$target_dir/$APP_NAME.app"
  ok "Installed $APP_NAME $APP_VERSION at $APP_PATH"
}

run_setup() {
  local setup="$APP_PATH/Contents/Resources/engine/setup.sh"
  [ -f "$setup" ] || die "$APP_PATH has no setup script. Delete it and run the same command again."
  if ! PATH="$USER_PATH" /bin/bash "$setup"; then
    if [ "$APP_WAS_RUNNING" = "1" ]; then
      open "$APP_PATH" >/dev/null 2>&1 || true
      die "Setup did not finish. $APP_NAME is open again; run the same command again, it continues where it stopped."
    fi
    die "Setup did not finish. Run the same command again, it continues where it stopped."
  fi
}

launch_app() {
  [ "$OPEN_APP" = "1" ] || return 0
  step "Opening $APP_NAME"
  open "$APP_PATH" || die "Could not open $APP_PATH. Open it from the Applications folder."
  ok "Opened. Look for the waveform icon in the menu bar."
}

print_next_steps() {
  cat <<EOF

${BOLD}Done.${RESET} $APP_NAME lives in the menu bar (the waveform icon, no Dock icon).
The first time it opens it records a 5 second test, and macOS asks for two permissions:
Microphone and System Audio Recording. Allow both.

${BOLD}How to use:${RESET}
  Click the menu bar icon and choose Start recording, or press Ctrl + Option + R anywhere.
  Turn on "Start automatically when a call starts" to record every call by itself.
  Recordings and transcripts are saved in ~/CallRecordings.
  In the Terminal: callrec list, callrec doctor, callrec --help.

${BOLD}To update later:${RESET} run the same command again. CallRec is not signed with an Apple
developer account, so after an update macOS may ask for the two permissions again.

Recording laws differ by country. In Israel a participant may record a conversation they take
part in; elsewhere you may need everyone's consent. Check your workplace policy too. You are
responsible for following the rules that apply to you and to the people on the call.
EOF
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  printf '%sCallRec: record and transcribe your calls, fully local%s\n' "$BOLD" "$RESET"
  check_platform
  install_app
  run_setup
  launch_app
  print_next_steps
}

[ "${CALLREC_INSTALL_NO_MAIN:-}" = "1" ] || main "$@"
