# `@tomasko/shrc`

[![npm](https://img.shields.io/npm/v/@tomasko/shrc.svg)](https://www.npmjs.com/package/@tomasko/shrc)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/tomasky/shrc/blob/master/LICENSE)

The npm launcher for [`shrc`](https://github.com/tomasky/shrc) — manage
environment variables and aliases across bash, zsh, fish and other shells from
one command.

```sh
npm install -g @tomasko/shrc
shrc set EDITOR vim
shrc set -a ll 'ls -la'
shrc init            # import what your startup files already define
shrc ls              # search paths are listed one directory per row
shrc all
```

`shrc` writes a single managed block into each detected startup file
(`~/.profile`, `~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish`) and keeps
the manifest in `~/.shrc`. Because the block is rewritten rather than appended
to, running `shrc set` twice never duplicates a line. On a first run it also
imports your existing configuration and installs a small shell wrapper so
`shrc set`/`shrc rm` apply to the current shell automatically. Use `eval` if
you prefer to do it manually:

```sh
eval "$(shrc set EDITOR vim)"
eval "$(shrc rm EDITOR)"
```

`PATH` and other search-path variables (`PYTHONPATH`, `LD_LIBRARY_PATH`,
`MANPATH`, ...) are kept as ordered lists: `shrc set PATH /opt/bin` prepends a
directory, `--append` adds at the end, `--drop` removes one, and
`shrc ls PATH` prints the search order as a table. The values are stored once
and rendered with each shell's own separator, so PowerShell gets `;` where
bash and fish get `:`.

## What this package contains

A small launcher, not the binary itself. On the first `shrc` run it downloads
the prebuilt native binary for your platform from the GitHub release and caches
it. Nothing is downloaded at install time.

| Platform | Target |
| --- | --- |
| Linux x86-64 | `shrc-linux-x86_64` (static, musl) |
| Linux arm64 | `shrc-linux-aarch64` (static, musl) |
| macOS Apple silicon | `shrc-darwin-aarch64` |
| Windows x86-64 | `shrc-windows-x86_64.exe` (MSVC) |

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version. The Windows build carries the
`.exe` suffix in both the release and the local cache.

## Why there is no `postinstall`

This package deliberately declares **no install script**. Since npm 12,
dependency lifecycle scripts are blocked unless the user opts in; and pnpm 12
fails a *project* install outright with `ERR_PNPM_IGNORED_BUILDS` when a
dependency declares one:

```console
$ pnpm add @tomasko/shrc
Error: ERR_PNPM_IGNORED_BUILDS
  × adding a new package
  ╰─▶ Ignored build scripts: @tomasko/shrc@0.1.2
```

Downloading lazily from `bin/shrc.js` sidesteps all of it: it works under npm,
pnpm, yarn, bun, `npx`, and `--ignore-scripts`, because it is an ordinary
command rather than an install hook.

## Cache location

The downloaded binary is kept outside the package, so reinstalling or clearing
`node_modules` never triggers a second download:

| Platform | Path |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/shrc` or `~/.cache/shrc` |
| macOS | `~/Library/Caches/shrc` |

## Environment variables

| Variable | Effect |
| --- | --- |
| `SHRC_BINARY` | Run this binary and never download anything |
| `SHRC_CACHE_DIR` | Where to keep the downloaded binary |
| `SHRC_VERSION` | Release version to fetch (default: this package's version) |
| `SHRC_REPO` | `owner/repo` to download from (default: `tomasky/shrc`) |
| `SHRC_DOWNLOAD_BASE` | Full base URL, overriding `SHRC_REPO`/`SHRC_VERSION` |
| `SHRC_FORCE_DOWNLOAD` | Re-download even if the cached binary exists |
| `SHRC_SKIP_DOWNLOAD` | Never download; fail if the binary is absent |
| `SHRC_NO_VERIFY` | Skip SHA-256 verification of the download |

`SHRC_DOWNLOAD_BASE` and `SHRC_REPO` are there for forks, private mirrors and
air-gapped installs:

```sh
SHRC_DOWNLOAD_BASE=https://internal.example.com/shrc npm install -g @tomasko/shrc
```

## Other ways to install

```sh
# Installer script (no Node.js required)
curl -LsSf https://raw.githubusercontent.com/tomasky/shrc/master/install.sh | bash

# From the MoonBit package registry
moon install kupas/shrc/cmd/shrc

# Build from source
git clone https://github.com/tomasky/shrc && cd shrc
moon build --target native --release
```

## License

Apache-2.0
