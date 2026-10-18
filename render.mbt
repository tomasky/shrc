///|
/// Rendering entries into shell syntax, and syncing them into a startup file
/// inside a marked block.
///
/// Every managed file gets exactly one block:
///
/// ```sh
/// # >>> shrc >>>
/// export EDITOR='vim'
/// alias ll='ls -la'
/// # <<< shrc <<<
/// ```
///
/// Rewriting the block is idempotent, so `shrc set` can run on every change
/// without ever appending a duplicate line.

///|
/// The line that opens a managed block.
pub let block_begin : String = "# >>> shrc >>>"

///|
/// The line that closes a managed block.
pub let block_end : String = "# <<< shrc <<<"

///|
/// Single-quote a value for a POSIX shell (`'` becomes `'\''`).
pub fn quote_posix(value : String) -> String {
  "'" + value.replace_all(old="'", new="'\\''") + "'"
}

///|
/// Single-quote a value for fish. Inside fish single quotes only `\` and `'`
/// are special.
pub fn quote_fish(value : String) -> String {
  let escaped = value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="'", new="\\'")
  "'" + escaped + "'"
}

///|
/// Single-quote a value for csh/tcsh. csh expands `!` for history even inside
/// single quotes, so it is escaped separately; a `'` is closed and reopened
/// around an escaped one.
pub fn quote_csh(value : String) -> String {
  let bang = value.replace_all(old="!", new="\\!")
  "'" + bang.replace_all(old="'", new="'\\''") + "'"
}

///|
/// Double-quote a value for nushell. nushell's double-quoted strings do not
/// interpolate `$`, so only backslash, the quote itself and the control
/// characters need escaping.
pub fn quote_nu(value : String) -> String {
  let escaped = value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\n", new="\\n")
    .replace_all(old="\t", new="\\t")
    .replace_all(old="\r", new="\\r")
    .replace_all(old="\"", new="\\\"")
  "\"" + escaped + "\""
}

///|
/// Single-quote a value for PowerShell. A single quote is doubled.
pub fn quote_ps(value : String) -> String {
  "'" + value.replace_all(old="'", new="''") + "'"
}

///|
/// Double-quote a value for a POSIX shell while leaving `$` and backticks
/// live, so an adopted `PATH` keeps expanding. Only `\` and `"` are escaped.
pub fn quote_posix_live(value : String) -> String {
  let escaped = value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\"", new="\\\"")
  "\"" + escaped + "\""
}

///|
/// Double-quote a live value for fish. Interpolation works like a POSIX
/// shell, so the escaping is the same.
pub fn quote_fish_live(value : String) -> String {
  let escaped = value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\"", new="\\\"")
  "\"" + escaped + "\""
}

///|
/// Double-quote a live value for csh/tcsh. `!` stays a history escape even
/// inside double quotes, so it is escaped as well.
pub fn quote_csh_live(value : String) -> String {
  let escaped = value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\"", new="\\\"")
    .replace_all(old="!", new="\\!")
  "\"" + escaped + "\""
}

///|
/// Quote a live value for nushell: an interpolating `$"..."` string, where
/// `$VAR` expands at load time.
pub fn quote_nu_live(value : String) -> String {
  let escaped = value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\"", new="\\\"")
  "$\"" + escaped + "\""
}

///|
/// Double-quote a live value for PowerShell, where `$VAR` expands inside
/// double quotes. The backtick is PowerShell's escape character.
pub fn quote_ps_live(value : String) -> String {
  let escaped = value
    .replace_all(old="`", new="``")
    .replace_all(old="\"", new="`\"")
  "\"" + escaped + "\""
}

///|
/// The literal quoting of a value in the syntax of `family`.
fn quote_literal(family : ShellFamily, value : String) -> String {
  match family {
    Posix => quote_posix(value)
    Fish => quote_fish(value)
    Csh => quote_csh(value)
    Nu => quote_nu(value)
    PowerShell => quote_ps(value)
  }
}

///|
/// The interpolating quoting of a live value in the syntax of `family`.
fn quote_live(family : ShellFamily, value : String) -> String {
  match family {
    Posix => quote_posix_live(value)
    Fish => quote_fish_live(value)
    Csh => quote_csh_live(value)
    Nu => quote_nu_live(value)
    PowerShell => quote_ps_live(value)
  }
}

///|
/// The quoted form of an entry's value in the syntax of `family`: single
/// quotes normally, interpolating quotes when the value stays live shell
/// syntax. Live values are canonical (`$NAME`), so their references are
/// rewritten for the family before quoting. A search path is stored with `:`
/// separators and rendered with the family's own separator.
fn quoted_value(family : ShellFamily, entry : Entry) -> String {
  let text = if entry.list && family_path_sep(family) != path_sep {
    entry.value.replace_all(old=path_sep, new=family_path_sep(family))
  } else {
    entry.value
  }
  if entry.raw {
    quote_live(family, translate_refs(family, text))
  } else {
    quote_literal(family, text)
  }
}

///|
/// Render one entry in the syntax of `family`.
pub fn render_entry(family : ShellFamily, entry : Entry) -> String {
  match family {
    Posix => {
      let value = quoted_value(family, entry)
      match entry.kind {
        Env => "export \{entry.name}=\{value}"
        Alias => "alias \{entry.name}=\{value}"
      }
    }
    Fish => {
      let value = quoted_value(family, entry)
      match entry.kind {
        Env => "set -gx \{entry.name} \{value}"
        Alias => "alias \{entry.name} \{value}"
      }
    }
    Csh => {
      let value = quoted_value(family, entry)
      match entry.kind {
        Env => "setenv \{entry.name} \{value}"
        Alias => "alias \{entry.name} \{value}"
      }
    }
    Nu =>
      match entry.kind {
        Env => "$env.\{entry.name} = \{quoted_value(family, entry)}"
        // nushell refuses `alias NAME = "..."` (an alias cannot expand to an
        // expression), so the value is the pipeline as typed.
        Alias => "alias \{entry.name} = \{entry.value}"
      }
    PowerShell =>
      match entry.kind {
        Env => "$env:\{entry.name} = \{quoted_value(family, entry)}"
        // PowerShell has no alias that carries arguments, so an alias becomes
        // a function whose body is the value as typed.
        Alias => "function \{entry.name} { \{entry.value} }"
      }
  }
}

///|
/// The statement that applies `entry` to the shell that evaluates it.
pub fn render_apply(family : ShellFamily, entry : Entry) -> String {
  render_entry(family, entry)
}

///|
/// The statement that removes `entry` from the shell that evaluates it.
pub fn render_remove(family : ShellFamily, entry : Entry) -> String {
  match family {
    Posix =>
      match entry.kind {
        Env => "unset \{entry.name}"
        Alias => "unalias \{entry.name} 2>/dev/null || true"
      }
    Fish =>
      match entry.kind {
        Env => "set -e \{entry.name}"
        Alias => "functions -e \{entry.name} 2>/dev/null; true"
      }
    Csh =>
      match entry.kind {
        Env => "unsetenv \{entry.name}"
        Alias => "unalias \{entry.name}"
      }
    Nu =>
      match entry.kind {
        Env => "hide-env \{entry.name}"
        Alias => "hide \{entry.name}"
      }
    PowerShell =>
      match entry.kind {
        Env => "Remove-Item Env:\{entry.name} -ErrorAction SilentlyContinue"
        Alias =>
          "Remove-Item Function:\{entry.name} -ErrorAction SilentlyContinue"
      }
  }
}

///|
/// Split a file into lines, dropping the empty element a trailing newline
/// leaves behind.
fn split_lines(text : String) -> Array[String] {
  let raw = text.split("\n").map(v => v.to_owned()).to_array()
  if raw.length() > 0 && raw[raw.length() - 1] == "" {
    raw.exact_view(end=raw.length() - 1).to_owned()
  } else {
    raw
  }
}

///|
/// The lines of a managed block, markers included.
fn block_lines(family : ShellFamily, entries : Array[Entry]) -> Array[String] {
  let lines = [block_begin]
  for entry in entries {
    lines.push(render_entry(family, entry))
  }
  lines.push(block_end)
  lines
}

///|
/// Return `text` with its managed block replaced by the one for `entries`.
///
/// A file without a block gets one appended; an empty entry list removes the
/// block entirely, so `shrc rm` leaves no trace. Duplicate or unbalanced
/// markers — what a hand edit can leave behind — are collapsed too: the first
/// complete block is rewritten in place and any other marker or block is
/// dropped, so a file can never accumulate two shrc blocks, and a stray
/// opening marker can never swallow the lines around it.
pub fn sync_block(
  text : String,
  family : ShellFamily,
  entries : Array[Entry],
) -> String {
  let lines = split_lines(text)
  let block = block_lines(family, entries)
  let out = []
  let mut replaced = false
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if line == block_begin {
      let mut end = i + 1
      let mut nested = false
      while end < lines.length() && lines[end] != block_end {
        if lines[end] == block_begin {
          nested = true
          break
        }
        end = end + 1
      }
      if nested {
        // A second opening marker before any closing one: this outer marker
        // is stray, and the inner pair is the real block.
        i = i + 1
      } else if end < lines.length() {
        if !replaced && entries.length() > 0 {
          for block_line in block {
            out.push(block_line)
          }
        }
        replaced = true
        i = end + 1
      } else {
        // An opening marker with no closing one: drop the stray marker and
        // keep everything after it.
        i = i + 1
      }
    } else if line == block_end {
      // A closing marker with no opening one.
      i = i + 1
    } else {
      out.push(line)
      i = i + 1
    }
  }
  if !replaced && entries.length() > 0 {
    if out.length() > 0 {
      out.push("")
    }
    for block_line in block {
      out.push(block_line)
    }
  }
  if out.length() == 0 {
    ""
  } else {
    out.join("\n") + "\n"
  }
}
