#!/usr/bin/env bash
# shrc installer — https://github.com/tomasky/shrc
#
#   curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash
#   curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash -s -- --version 0.1.1
#
# The installer only places the `shrc` binary and makes it reachable. Managing
# environment variables and aliases is `shrc`'s own job, not the installer's.
#
# Environment overrides:
#   SHRC_VERSION         release version to install (default: latest)
#   SHRC_INSTALL_DIR     where to put the `shrc` binary
#                        (default: the first writable directory already on PATH)
#   SHRC_REPO            owner/repo to download from (default: tomasky/shrc)
#   SHRC_DOWNLOAD_BASE   full base URL; overrides SHRC_REPO/SHRC_VERSION
#   SHRC_NO_MODIFY_PATH  do not touch any shell startup file
set -euo pipefail

REPO="${SHRC_REPO:-tomasky/shrc}"
BIN="shrc"
PATH_MARKER="# Added by shrc installer"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
shrc installer

Usage:
  install.sh [options]

Options:
  -v, --version <version>       install a specific version (e.g. 0.1.1)
  -b, --install-dir <dir>       install into <dir>
      --no-modify-path          do not edit any shell startup file
      --no-verify               skip SHA-256 checksum verification
  -h, --help                    show this help

Environment:
  SHRC_VERSION, SHRC_INSTALL_DIR, SHRC_REPO, SHRC_DOWNLOAD_BASE,
  SHRC_NO_MODIFY_PATH
EOF
}

version=""
install_dir=""
verify=1
modify_path=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -v | --version)
      [ $# -ge 2 ] || err "--version requires a value"
      version="$2"
      shift 2
      ;;
    --version=*)
      version="${1#*=}"
      shift
      ;;
    -b | --install-dir)
      [ $# -ge 2 ] || err "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    --install-dir=*)
      install_dir="${1#*=}"
      shift
      ;;
    --no-modify-path)
      modify_path=0
      shift
      ;;
    --no-verify)
      verify=0
      shift
      ;;
    *)
      err "unknown argument: $1 (try --help)"
      ;;
  esac
done

[ -n "$version" ] || version="${SHRC_VERSION:-}"
[ -n "$install_dir" ] || install_dir="${SHRC_INSTALL_DIR:-}"
[ -n "${SHRC_NO_MODIFY_PATH:-}" ] && modify_path=0
version="${version#v}"

# --- detect platform -------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Linux-x86_64 | Linux-amd64) target="linux-x86_64" ;;
  Linux-aarch64 | Linux-arm64) target="linux-aarch64" ;;
  Darwin-arm64) target="darwin-aarch64" ;;
  Darwin-x86_64)
    err "unsupported platform: $os-$arch — the MoonBit toolchain no longer ships a darwin-x86_64 target, so no Intel macOS build is published"
    ;;
  *)
    err "unsupported platform: $os-$arch (shrc publishes linux-x86_64, linux-aarch64 and darwin-aarch64)"
    ;;
esac

# --- downloader ------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "either curl or wget is required"
fi

# --- install directory -----------------------------------------------------
# Prefer a directory that is already on PATH: the binary then works in the
# current shell with no restart, which is the whole point of "install and go".
path_contains() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "$install_dir" ]; then
  for candidate in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    if path_contains "$candidate"; then
      install_dir="$candidate"
      break
    fi
  done
fi
[ -n "$install_dir" ] || install_dir="$HOME/.shrc/bin"

# --- shell startup file ----------------------------------------------------
shell_name="$(basename "${SHELL:-sh}")"

profile_file() {
  case "$(basename "${SHELL:-sh}")" in
    bash)
      if [ -f "$HOME/.bashrc" ]; then
        printf '%s' "$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then
        printf '%s' "$HOME/.bash_profile"
      else
        printf '%s' "$HOME/.bashrc"
      fi
      ;;
    zsh)
      printf '%s' "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    fish)
      printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      ;;
    *)
      printf '%s' "$HOME/.profile"
      ;;
  esac
}

add_to_path() {
  local dir="$1" profile="$2"
  [ "$modify_path" = 1 ] || return 0
  if [ -f "$profile" ] && grep -qF "$PATH_MARKER" "$profile" 2>/dev/null; then
    say "shrc: $profile already sets up shrc; leaving it alone"
    return 0
  fi
  mkdir -p "$(dirname "$profile")"
  # shellcheck disable=SC2016  # $PATH must stay literal in the written line
  case "$profile" in
    */config.fish)
      printf '\nset -gx PATH "%s" $PATH  %s\n' "$dir" "$PATH_MARKER" >>"$profile"
      ;;
    *)
      printf '\nexport PATH="%s:$PATH"  %s\n' "$dir" "$PATH_MARKER" >>"$profile"
      ;;
  esac
  say "shrc: added $dir to PATH in $profile"
}

# --- resolve base URL ------------------------------------------------------
if [ -n "${SHRC_DOWNLOAD_BASE:-}" ]; then
  base="${SHRC_DOWNLOAD_BASE%/}"
elif [ -n "$version" ]; then
  base="https://github.com/$REPO/releases/download/v$version"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

asset="shrc-$target"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "shrc: downloading $base/$asset"
dl "$base/$asset" "$tmp/$asset" || err "failed to download $base/$asset"

# --- verify ----------------------------------------------------------------
if [ "$verify" = 1 ]; then
  if dl "$base/$asset.sha256" "$tmp/$asset.sha256" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null) ||
        err "checksum verification failed for $asset"
    elif command -v shasum >/dev/null 2>&1; then
      (cd "$tmp" && shasum -a 256 -c "$asset.sha256" >/dev/null) ||
        err "checksum verification failed for $asset"
    else
      say "shrc: warning: no sha256sum/shasum available, skipping verification"
    fi
  else
    say "shrc: warning: no checksum published for $asset, skipping verification"
  fi
fi

# --- install ---------------------------------------------------------------
mkdir -p "$install_dir"
if command -v install >/dev/null 2>&1; then
  install -m 755 "$tmp/$asset" "$install_dir/$BIN"
else
  cp "$tmp/$asset" "$install_dir/$BIN"
  chmod 755 "$install_dir/$BIN"
fi
say "shrc: installed $install_dir/$BIN"

# --- make it effective -----------------------------------------------------
# The installer runs as a child process and cannot change its parent shell's
# environment. It does the next best thing: put the directory on PATH for every
# future shell, and tell the current one exactly how to catch up. When the
# script is *sourced* rather than piped, it can update the current shell too.
if ! path_contains "$install_dir"; then
  add_to_path "$install_dir" "$(profile_file)"
  say ""
  if [ "$shell_name" = "fish" ]; then
    say "shrc: to start using it in this shell, run:"
    say "  set -gx PATH \"$install_dir\" \$PATH"
  else
    say "shrc: to start using it in this shell, run:"
    say "  export PATH=\"$install_dir:\$PATH\""
  fi
  say "shrc: or open a new terminal."
fi

was_sourced() {
  if [ -n "${BASH_VERSION:-}" ]; then
    [ "${BASH_SOURCE[0]:-}" != "$0" ]
  elif [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
      *:file*) return 0 ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

if ! path_contains "$install_dir" && was_sourced; then
  export PATH="$install_dir:$PATH"
  say "shrc: PATH updated for the current shell"
fi

say ""
"$install_dir/$BIN" version 2>/dev/null || true
say ""
say "shrc: manage environment variables and aliases with:"
say "  shrc set EDITOR vim"
say "  shrc set -a ll 'ls -la'"
say "  shrc ls"
say "  shrc all"
say "  eval \"\$(shrc set EDITOR vim)\"   # apply to the current shell"
