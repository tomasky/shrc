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
/// Render one entry in the syntax of `family`.
pub fn render_entry(family : ShellFamily, entry : Entry) -> String {
  match family {
    Posix =>
      match entry.kind {
        Env => "export \{entry.name}=\{quote_posix(entry.value)}"
        Alias => "alias \{entry.name}=\{quote_posix(entry.value)}"
      }
    Fish =>
      match entry.kind {
        Env => "set -gx \{entry.name} \{quote_fish(entry.value)}"
        Alias => "alias \{entry.name} \{quote_fish(entry.value)}"
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
/// The index of the first line equal to `target`.
fn find_line(lines : Array[String], target : String) -> Int32? {
  for i = 0; i < lines.length(); i = i + 1 {
    if lines[i] == target {
      return Some(i)
    }
  }
  None
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
/// block entirely, so `shrc rm` leaves no trace.
pub fn sync_block(
  text : String,
  family : ShellFamily,
  entries : Array[Entry],
) -> String {
  let lines = split_lines(text)
  let begin = find_line(lines, block_begin)
  let end = find_line(lines, block_end)
  let out = []
  match (begin, end) {
    (Some(b), Some(e)) if b <= e => {
      for i = 0; i < b; i = i + 1 {
        out.push(lines[i])
      }
      if entries.length() > 0 {
        for line in block_lines(family, entries) {
          out.push(line)
        }
      }
      for i = e + 1; i < lines.length(); i = i + 1 {
        out.push(lines[i])
      }
    }
    _ => {
      for line in lines {
        out.push(line)
      }
      if entries.length() > 0 {
        if out.length() > 0 {
          out.push("")
        }
        for line in block_lines(family, entries) {
          out.push(line)
        }
      }
    }
  }
  if out.length() == 0 {
    ""
  } else {
    out.join("\n") + "\n"
  }
}
