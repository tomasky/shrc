# shrc

Manage environment variables and aliases across **every** shell you use —
bash, zsh, fish and the plain POSIX `/bin/sh` family — from a single command.

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

```sh
curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash
```

The installer only places the `shrc` binary. It prefers a directory that is
already on your `PATH` (`~/.local/bin`, `~/bin`, `/usr/local/bin`), so the
command works right away; otherwise it installs to `~/.shrc/bin` and adds that
to the startup file for your login shell. Sourcing the script updates the
current shell too:

```sh
source <(curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh)
```

### npm

```sh
npm install -g @tomasko/shrc
```

The npm package is a launcher: it downloads the matching prebuilt binary from
GitHub Releases on first run and caches it, so it works under npm, pnpm, yarn,
bun and `npx` with no install script.

### From source

```sh
git clone https://github.com/tomasky/shrc && cd shrc
moon build --target native --release
```

## Usage

```sh
shrc set EDITOR vim            # environment variable, in every shell
shrc set NAME=VALUE            # same, one argument
shrc set -a ll 'ls -la'        # an alias instead of a variable
shrc rm EDITOR                 # remove every entry named EDITOR
shrc rm -a ll                  # remove only the alias
shrc ls                        # list managed entries
shrc ls EDIT                   # filter by name
shrc all                       # the manifest and every startup file
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
for bash and zsh, `set -gx`/`alias` for fish. A summary goes to standard error,
so it never pollutes an `eval`.

## How it works

* The manifest lives in `~/.shrc/entries` and is the source of truth for
  `shrc ls` and `shrc all`.
* On every change, shrc renders the manifest for each detected shell and
  rewrites its managed block.
* A shell is managed when its startup file already exists or it is your login
  shell; when nothing is found, `~/.profile` is used as the portable baseline.

| Shell | Startup file |
| --- | --- |
| profile (sh, dash, ksh, ...) | `~/.profile` |
| bash | `~/.bashrc` (or `~/.bash_profile` when that is what exists) |
| zsh | `${ZDOTDIR:-$HOME}/.zshrc` (or `.zprofile`) |
| fish | `${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish` |

## Environment

| Variable | Effect |
| --- | --- |
| `SHRC_HOME` | Where the manifest lives (default: `~/.shrc`) |
| `SHELL` | Picks the syntax of the statement printed for `eval` |

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
