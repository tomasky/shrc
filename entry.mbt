///|
/// The entries shrc manages: an environment variable or a shell alias.
///
/// An entry is stored in a small manifest so that `shrc ls` and `shrc all`
/// always agree with what was written to the shell files, even after a file
/// has been edited or deleted by hand.

///|
/// Whether an entry is an environment variable or an alias.
pub(all) enum EntryKind {
  Env
  Alias
}

///|
/// Whether two kinds are the same. Kept explicit so the enum needs no
/// derived `Eq`, whose promoted methods would otherwise warn.
pub fn kind_eq(a : EntryKind, b : EntryKind) -> Bool {
  match (a, b) {
    (Env, Env) => true
    (Alias, Alias) => true
    _ => false
  }
}

///|
/// A single managed entry.
///
/// `raw` marks a value that is shell syntax rather than a literal string: an
/// adopted `export PATH="$HOME/bin:$PATH"` must keep expanding when the
/// startup file is read, so rendering embeds it in the family's interpolating
/// quotes instead of literal single quotes. `list` marks a search path — the
/// value is joined by `:` canonically and rendered with the family's own
/// separator (PowerShell uses `;`).
pub(all) struct Entry {
  kind : EntryKind
  name : String
  value : String
  raw : Bool
  list : Bool
}

///|
/// Build a literal entry.
pub fn Entry::new(kind : EntryKind, name : String, value : String) -> Entry {
  { kind, name, value, raw: false, list: false, }
}

///|
/// Build an entry whose value stays live shell syntax (`$VAR`, backticks).
pub fn Entry::new_raw(kind : EntryKind, name : String, value : String) -> Entry {
  { kind, name, value, raw: true, list: false, }
}

///|
/// Build an entry with every attribute spelled out.
pub fn Entry::new_full(
  kind : EntryKind,
  name : String,
  value : String,
  raw : Bool,
  list : Bool,
) -> Entry {
  { kind, name, value, raw, list, }
}

///|
/// Whether two entries agree on kind, name, value and attributes.
pub fn entry_eq(a : Entry, b : Entry) -> Bool {
  kind_eq(a.kind, b.kind) &&
  a.name == b.name &&
  a.value == b.value &&
  a.raw == b.raw &&
  a.list == b.list
}

///|
/// The manifest spelling of a kind.
pub fn kind_label(kind : EntryKind) -> String {
  match kind {
    Env => "env"
    Alias => "alias"
  }
}

///|
/// Parse a manifest kind, accepting the singular and plural spellings.
pub fn parse_kind(text : String) -> EntryKind? {
  match text {
    "env" | "environment" => Some(Env)
    "alias" | "aliases" => Some(Alias)
    _ => None
  }
}

///|
/// Escape a value so it can live on one tab-separated manifest line.
pub fn escape_field(text : String) -> String {
  let out = StringBuilder()
  for ch in text.to_array() {
    match ch {
      '\\' => out.write_string("\\\\")
      '\t' => out.write_string("\\t")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
/// Inverse of `escape_field`.
pub fn unescape_field(text : String) -> String {
  let out = StringBuilder()
  let chars = text.to_array()
  let mut i = 0
  while i < chars.length() {
    let ch = chars[i]
    if ch == '\\' && i + 1 < chars.length() {
      match chars[i + 1] {
        'n' => {
          out.write_char('\n')
          i = i + 2
        }
        't' => {
          out.write_char('\t')
          i = i + 2
        }
        'r' => {
          out.write_char('\r')
          i = i + 2
        }
        '\\' => {
          out.write_char('\\')
          i = i + 2
        }
        _ => {
          out.write_char(ch)
          i = i + 1
        }
      }
    } else {
      out.write_char(ch)
      i = i + 1
    }
  }
  out.to_string()
}

///|
/// The attribute field of a manifest line: empty, or a comma-separated list of
/// `raw` (the value stays live shell syntax) and `list` (a search path).
fn entry_flags(entry : Entry) -> String {
  if entry.raw && entry.list {
    "raw,list"
  } else if entry.raw {
    "raw"
  } else if entry.list {
    "list"
  } else {
    ""
  }
}

///|
/// Serialize one entry as a manifest line: `kind<TAB>name<TAB>value`, with an
/// extra attribute field before the name when the value is not a plain
/// literal (`raw`, `list`, or `raw,list`).
pub fn entry_to_line(entry : Entry) -> String {
  let flags = entry_flags(entry)
  if flags.length() == 0 {
    "\{kind_label(entry.kind)}\t\{entry.name}\t\{escape_field(entry.value)}"
  } else {
    "\{kind_label(entry.kind)}\t\{flags}\t\{entry.name}\t\{escape_field(entry.value)}"
  }
}

///|
/// Parse one manifest line, or `None` when it is blank or malformed.
pub fn entry_of_line(line : String) -> Entry? {
  let trimmed = line.trim().to_owned()
  if trimmed.length() == 0 || trimmed.has_prefix("#") {
    return None
  }
  let parts = trimmed.split("\t").to_array()
  if parts.length() < 3 {
    return None
  }
  let kind = match parse_kind(parts[0].to_owned()) {
    Some(kind) => kind
    None => return None
  }
  if parts.length() >= 4 {
    let mut raw = false
    let mut list = false
    for flag in parts[1].split(",") {
      if flag == "raw" {
        raw = true
      } else if flag == "list" {
        list = true
      }
    }
    return Some(
      Entry::new_full(
        kind,
        parts[2].to_owned(),
        unescape_field(parts[3].to_owned()),
        raw,
        list,
      ),
    )
  }
  Some(
    Entry::new(kind, parts[1].to_owned(), unescape_field(parts[2].to_owned())),
  )
}

///|
/// Parse a whole manifest.
pub fn parse_entries(text : String) -> Array[Entry] {
  let out = []
  for line in text.split("\n") {
    match entry_of_line(line.to_owned()) {
      Some(entry) => out.push(entry)
      None => ()
    }
  }
  out
}

///|
/// Render the whole manifest, one entry per line.
pub fn serialize_entries(entries : Array[Entry]) -> String {
  let out = StringBuilder()
  for entry in entries {
    out.write_string(entry_to_line(entry))
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// Insert `entry`, replacing any entry with the same kind and name.
pub fn upsert_entry(entries : Array[Entry], entry : Entry) -> Array[Entry] {
  let out = []
  let mut replaced = false
  for existing in entries {
    if kind_eq(existing.kind, entry.kind) && existing.name == entry.name {
      out.push(entry)
      replaced = true
    } else {
      out.push(existing)
    }
  }
  if !replaced {
    out.push(entry)
  }
  out
}

///|
/// Split `entries` into the ones that survive and the ones matching `name`.
pub fn remove_by_name(
  entries : Array[Entry],
  name : String,
) -> (Array[Entry], Array[Entry]) {
  let remaining = []
  let removed = []
  for entry in entries {
    if entry.name == name {
      removed.push(entry)
    } else {
      remaining.push(entry)
    }
  }
  (remaining, removed)
}

///|
/// Entries whose name equals or contains `filter`, in manifest order.
pub fn filter_entries(entries : Array[Entry], filter : String) -> Array[Entry] {
  if filter.length() == 0 {
    return entries
  }
  let out = []
  for entry in entries {
    if entry.name == filter || entry.name.contains(filter) {
      out.push(entry)
    }
  }
  out
}
