# shrc

[![CI](https://github.com/tomasky/shrc/actions/workflows/ci.yml/badge.svg)](https://github.com/tomasky/shrc/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@tomasko/shrc.svg)](https://www.npmjs.com/package/@tomasko/shrc)
[![Mooncakes](https://img.shields.io/badge/mooncakes-kupas%2Fshrc-blue)](https://mooncakes.io/docs/kupas/shrc)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)

Manage environment variables and aliases across **every** shell you use —
bash, zsh, fish, csh/tcsh, nushell, PowerShell and the plain POSIX `/bin/sh`
family — from a single command.

`shrc` keeps one managed block in each of your startup files:

```sh
# >>> shrc >>>
export EDITOR='vim'
alias ll='ls -la'
# <<< shrc <<<
```

`shrc set` and `shrc rm` rewrite that block in place, so running a command
twice never duplicates a line, and `shrc rm` leaves no trace behind.

## Install

Pick one of the ways below. Every one of them ends with a working `shrc` on
your `PATH`.

### Installer script (recommended)

```sh
curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash
```

The installer places the `shrc` binary, makes it reachable, and then runs
`shrc init` once to **import the environment variables and aliases your
startup files already define**, so `shrc ls` starts out showing the real
configuration instead of an empty store. It prefers a directory that is
already on your `PATH` (`~/.local/bin`, `~/bin`, `/usr/local/bin`), so the
command works right away; otherwise it installs to `~/.shrc/bin`, adds that to
the startup file for your login shell and prints the one line needed to
activate it in the terminal you are in. Sourcing the script updates the
current shell too:

```sh
source <(curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh)
```

Options: `--version <v>` (`-v`, e.g. `--version 0.1.2`), `--install-dir <dir>`
(`-b`), `--no-modify-path`, `--no-init` (skip the import), `--no-verify`. Run
`install.sh --help` for the full list and the environment overrides
(`SHRC_VERSION`, `SHRC_INSTALL_DIR`, `SHRC_REPO`, `SHRC_DOWNLOAD_BASE`,
`SHRC_NO_MODIFY_PATH`, `SHRC_NO_INIT`).

### npm

```sh
npm install -g @tomasko/shrc
npx @tomasko/shrc ls          # or pnpm / yarn / bun, no global install needed
```

The npm package is a launcher: it downloads the matching prebuilt binary from
GitHub Releases on first run and caches it, so it works under npm, pnpm, yarn,
bun and `npx` with no install script.

### MoonBit

```sh
moon install kupas/shrc/cmd/shrc
```

Installs the published binary into `~/.moon/bin`. To use `shrc` as a MoonBit
library instead:

```sh
moon add kupas/shrc
```

### Windows

`npm install -g @tomasko/shrc` works as-is — the launcher fetches
`shrc-windows-x86_64.exe` on first run. You can also download that `.exe` from
the [latest release](https://github.com/tomasky/shrc/releases/latest) and put
it on your `PATH`. The installer script recognises Git Bash, MSYS2 and Cygwin,
so the one-liner above works there too.

### Prebuilt binary

Download the asset for your platform from the
[latest release](https://github.com/tomasky/shrc/releases/latest), make it
executable and put it on your `PATH`:

| Platform | Asset |
| --- | --- |
| Linux x86-64 | `shrc-linux-x86_64` (static, musl) |
| Linux arm64 | `shrc-linux-aarch64` (static, musl) |
| macOS Apple silicon | `shrc-darwin-aarch64` |
| Windows x86-64 | `shrc-windows-x86_64.exe` (MSVC) |

Each asset ships next to a `.sha256` checksum file:

```sh
curl -LO https://github.com/tomasky/shrc/releases/latest/download/shrc-linux-x86_64
curl -LO https://github.com/tomasky/shrc/releases/latest/download/shrc-linux-x86_64.sha256
sha256sum -c shrc-linux-x86_64.sha256
install -m 755 shrc-linux-x86_64 ~/.local/bin/shrc
```

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version.

### From source

```sh
git clone https://github.com/tomasky/shrc && cd shrc
moon build --target native --release
./_build/native/release/build/cmd/shrc/shrc.exe help
```

## Usage

```sh
shrc set EDITOR vim            # environment variable, in every shell
shrc set NAME=VALUE            # same, one argument
shrc set -a ll 'ls -la'        # an alias instead of a variable
shrc set --prepend PATH /opt/bin   # add a directory in front
shrc set --append PATH /opt/bin    # add a directory at the end
shrc set --drop PATH /opt/bin      # remove a directory
shrc set -r EDITOR '$HOME/bin/vi'  # store shell syntax; references stay live
shrc rm EDITOR                 # remove every entry named EDITOR
shrc rm -a ll                  # remove only the alias
shrc ls                        # list managed entries
shrc ls EDIT                   # filter by name
shrc ls PATH                   # search paths, one directory per row, in order
shrc all                       # the manifest and every startup file
shrc init                      # import what the startup files already define
shrc version
shrc help
```

`set` and `rm` print the statement that applies the change, so you can make it
take effect in the **current** shell with `eval`:

```sh
eval "$(shrc set EDITOR vim)"
eval "$(shrc rm EDITOR)"
```

The printed line is syntax for your login shell (`$SHELL`): `export`/`alias`
for bash and zsh, `set -gx`/`alias` for fish, `setenv` for csh/tcsh,
`$env.X = ...` for nushell, and `$env:X = ...` for PowerShell. A summary goes
to standard error, so it never pollutes an `eval`.

### Applying changes to the current shell automatically

`shrc` itself cannot change its parent shell's environment, so `eval` is the
portable way. If you would rather not type it every time, add a small wrapper
to your interactive startup file (`~/.bashrc`, `~/.zshrc`,
`~/.config/fish/config.fish`); `.profile` only needs it when it is your login
shell's file:

```sh
# bash / zsh / POSIX sh
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
```

```fish
# fish
function shrc
  switch $argv[1]
    case set rm remove unset delete
      eval (command shrc $argv)
    case '*'
      command shrc $argv
  end
end
```

The installer adds this block for you (guarded by a marker, so it is never
duplicated). For a manual install, paste it once.

### Search paths (PATH and friends)

Variables that hold an ordered list of directories — `PATH`, `PYTHONPATH`,
`LD_LIBRARY_PATH`, `MANPATH`, `CLASSPATH` and anything else ending in `PATH` —
get list semantics instead of a plain assignment:

* `shrc set PATH /opt/bin` **prepends** the directory; the previous value is
  kept through `$PATH`. `--append` adds at the end instead, `--drop` removes a
  directory, and an identical directory is never duplicated.
* `shrc set PATH '/a:/b'` (or the PowerShell spelling `'/a;/b'`) replaces the
  whole list; a value containing `$` is stored as live syntax, so
  `shrc set PATH "$HOME/bin:$PATH"` keeps expanding per shell.
* Values are stored canonically with `:` and rendered with each shell's own
  separator — PowerShell gets `;`: `$env:PATH = '$HOME/bin;$env:PATH'`.
* `shrc ls PATH` prints the list as a table, one directory per row, in search
  order, instead of one long line.

### Importing existing configuration

`shrc init` (also run automatically by the installer on a first install)
scans the startup files for your detected shells and adopts what they already
define: `export NAME=...`, `alias ...`, fish `set -gx`/`alias`, csh `setenv`,
nushell `$env.NAME`, PowerShell `$env:NAME`, plus the companion files the
startup files source (`~/.bash_aliases` and the like). Definitions move into
the manifest and the managed block; files are backed up under
`~/.shrc/backup/` before the first edit, and a definition whose value uses
shell syntax shrc cannot translate (command substitutions, backticks, escapes)
stays where it is. `shrc init -n` reports what it would do without touching
anything.

## How it works

* The manifest lives in `~/.shrc/entries` and is the source of truth for
  `shrc ls` and `shrc all`.
* A manifest line can carry attributes: `raw` means the value is shell syntax
  that stays live (`env	raw	EDITOR	$HOME/bin/vi`), `list` means a search
  path stored with `:` between directories
  (`env	raw,list	PATH	/opt/bin:$PATH`).
* On every change, shrc renders the manifest for each detected shell and
  rewrites its managed block.
* `shrc init` adopts what the startup files already define and moves those
  lines into the block; each file it edits is backed up first.
* A shell is managed when its startup file already exists or it is your login
  shell; when nothing is found, `~/.profile` is used as the portable baseline.

| Shell | Startup file |
| --- | --- |
| profile (sh, dash, ...) | `~/.profile` |
| bash | `~/.bashrc` (or `~/.bash_profile`, `~/.bash_login`) |
| zsh | `${ZDOTDIR:-$HOME}/.zshrc` (or `.zprofile`, `.zshenv`) |
| ksh / mksh | `~/.kshrc` / `~/.mkshrc` |
| fish | `${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish` |
| csh / tcsh | `~/.cshrc`, `~/.tcshrc`, `~/.login` |
| nushell | `${XDG_CONFIG_HOME:-$HOME/.config}/nushell/config.nu`, `env.nu` |
| PowerShell | `${XDG_CONFIG_HOME:-$HOME/.config}/powershell/Microsoft.PowerShell_profile.ps1`, `~/Documents/PowerShell/...` |

## Environment

| Variable | Effect |
| --- | --- |
| `SHRC_HOME` | Where the manifest lives (default: `~/.shrc`) |
| `SHELL` | Picks the syntax of the statement printed for `eval` |
| `XDG_CONFIG_HOME` | Base for the fish, nushell and pwsh startup files |
| `ZDOTDIR` | Directory holding the zsh startup files |

The installer and npm launcher read a few more (`SHRC_INSTALL_DIR`,
`SHRC_DOWNLOAD_BASE`, `SHRC_NO_MODIFY_PATH`, `SHRC_BINARY`, `SHRC_CACHE_DIR`);
run `install.sh --help` or see `npmjs/README.md`.

## Development

```sh
moon check --target native --deny-warn
moon test  --target native
moon fmt
moon info
```

`moon info` refreshes `pkg.generated.mbti`; the tests in `shrc_test.mbt`
(blackbox) and `shrc_wbtest.mbt` (whitebox) cover quoting, the manifest round
trip, block rewriting and shell detection.

## License

Apache-2.0
