// shrc — manage environment variables and aliases across every shell
// (bash, zsh, fish, ...), implemented in MoonBit.
//
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "kupas/shrc"

version = "0.1.5"

readme = "README.mbt.md"

repository = "https://github.com/tomasky/shrc"

license = "Apache-2.0"

keywords = [
  "shell",
  "shrc",
  "env",
  "alias",
  "bash",
  "zsh",
  "fish",
  "dotfiles",
  "cli",
]

description = "Manage environment variables and aliases across bash, zsh, fish and other shells"

preferred_target = "native"

import {
  "moonbitlang/x@0.5.5",
}
