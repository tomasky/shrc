#!/usr/bin/env bash
# shrc installer — https://github.com/tomasky/shrc
#
#   curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash
#   curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash -s -- --version 0.1.5
#
# The installer places the `shrc` binary, makes it reachable, and runs
# `shrc init` once so the configuration the startup files already define is
# imported into the manifest (so `shrc ls` shows it). The startup files are
# not modified. `--no-init` skips even that.
#
# Environment overrides:
#   SHRC_VERSION         release version to install (default: latest)
#   SHRC_INSTALL_DIR     where to put the `shrc` binary
#                        (default: the first writable directory already on PATH)
#   SHRC_REPO            owner/repo to download from (default: tomasky/shrc)
#   SHRC_DOWNLOAD_BASE   full base URL; overrides SHRC_REPO/SHRC_VERSION
#   SHRC_NO_MODIFY_PATH  do not touch any shell startup file
#   SHRC_NO_INIT         skip the `shrc init` step
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
  -v, --version <version>       install a specific version (e.g. 0.1.5)
  -b, --install-dir <dir>       install into <dir>
      --no-modify-path          do not edit any shell startup file
      --no-init                 skip the 'shrc init' step
      --no-verify               skip SHA-256 checksum verification
  -h, --help                    show this help

Environment:
  SHRC_VERSION, SHRC_INSTALL_DIR, SHRC_REPO, SHRC_DOWNLOAD_BASE,
  SHRC_NO_MODIFY_PATH, SHRC_NO_INIT
EOF
}

version=""
install_dir=""
verify=1
modify_path=1
init=1

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
    --no-init)
      init=0
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
[ -n "${SHRC_NO_INIT:-}" ] && init=0
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
  # Git Bash, MSYS2 and Cygwin on 64-bit Windows can run this script; the
  # installed command is still the native shrc.exe.
  MINGW64_NT-*-x86_64 | UCRT64_NT-*-x86_64 | CLANG64_NT-*-x86_64 | MSYS_NT-*-x86_64 | CYGWIN_NT-*-x86_64)
    target="windows-x86_64"
    ;;
  *)
    err "unsupported platform: $os-$arch (shrc publishes linux-x86_64, linux-aarch64, darwin-aarch64 and windows-x86_64)"
    ;;
esac

# --- asset name ------------------------------------------------------------
# Windows release assets carry an `.exe` suffix, and the installed command is
# `shrc.exe` so cmd.exe and PowerShell resolve `shrc` through PATHEXT.
asset="shrc-$target"
case "$target" in
  windows-*)
    asset="$asset.exe"
    BIN="$BIN.exe"
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

# A directory the binary can actually be installed into: it exists and is
# writable, or it can be created.
dir_usable() {
  if [ -d "$1" ]; then
    [ -w "$1" ]
  else
    mkdir -p "$1" 2>/dev/null && [ -w "$1" ]
  fi
}

if [ -z "$install_dir" ]; then
  for candidate in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    if path_contains "$candidate" && dir_usable "$candidate"; then
      install_dir="$candidate"
      break
    fi
  done
fi
if [ -n "$install_dir" ]; then
  dir_usable "$install_dir" ||
    err "cannot install into '$install_dir' (set SHRC_INSTALL_DIR to a writable directory)"
else
  install_dir="$HOME/.shrc/bin"
  dir_usable "$install_dir" ||
    err "cannot create '$install_dir' (set SHRC_INSTALL_DIR to a writable directory)"
fi

# --- shell startup file ----------------------------------------------------
shell_name="$(basename "${SHELL:-sh}")"

profile_file() {
  case "$shell_name" in
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
  # Look for this exact directory, not just our marker: a reinstall into a
  # different directory must not be skipped.
  if [ -f "$profile" ] && grep -qF "$dir" "$profile" 2>/dev/null; then
    say "shrc: $profile already sets up $dir; leaving it alone"
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

# Add a small wrapper so `shrc set` / `shrc rm` apply to the current shell
# without an explicit `eval`. Guarded by a marker so reinstalling never
# duplicates it. Only the startup file this install already touches gets it;
# `.profile` is covered when it is the login shell's file.
add_shell_integration() {
  local profile="$1"
  [ "$modify_path" = 1 ] || return 0
  if [ -f "$profile" ] && grep -qF "shrc shell integration" "$profile" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$(dirname "$profile")"
  case "$profile" in
    */config.fish)
      cat >>"$profile" <<'EOF'

# >>> shrc shell integration >>>
function shrc
  switch $argv[1]
    case set rm remove unset delete
      eval (command shrc $argv)
    case '*'
      command shrc $argv
  end
end
# <<< shrc shell integration <<<
EOF
      ;;
    *)
      cat >>"$profile" <<'EOF'

# >>> shrc shell integration >>>
shrc() {
  case "$1" in
    set|rm|remove|unset|delete)
      eval "$(command shrc "$@")"
      ;;
    *)
      command shrc "$@"
      ;;
  esac
}
# <<< shrc shell integration <<<
EOF
      ;;
  esac
  say "shrc: added shell integration to $profile"
}

# --- resolve base URL ------------------------------------------------------
if [ -n "${SHRC_DOWNLOAD_BASE:-}" ]; then
  base="${SHRC_DOWNLOAD_BASE%/}"
elif [ -n "$version" ]; then
  base="https://github.com/$REPO/releases/download/v$version"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

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
  add_shell_integration "$(profile_file)"
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
  # The shell may have cached command lookups; drop them so `shrc` resolves
  # right now rather than at the next shell.
  hash -r 2>/dev/null || true
  say "shrc: PATH updated for the current shell"
fi

say ""
add_shell_integration "$(profile_file)"

if ! installed_version="$("$install_dir/$BIN" version 2>/dev/null)"; then
  err "installed $install_dir/$BIN but it failed to run"
fi
say "$installed_version"

# --- import what the user already has -------------------------------------
# `shrc init` imports definitions into the manifest so `shrc ls` shows them.
# It never rewrites a startup file.
if [ "$init" = 1 ]; then
  say ""
  "$install_dir/$BIN" init || say "shrc: warning: 'shrc init' did not finish"
fi

say ""
say "shrc: manage environment variables and aliases with:"
say "  shrc set EDITOR vim"
say "  shrc set -a ll 'ls -la'"
say "  shrc set --prepend PATH /opt/bin"
say "  shrc ls PATH"
say "  shrc all"
say "  eval \"\$(shrc set EDITOR vim)\"   # apply to the current shell"
