///|
/// Search-path variables: values that are ordered lists of directories.
///
/// A search path is stored in the manifest with `:` between directories,
/// whatever shell it came from, and marked with the `list` flag. Rendering
/// then uses the family's own separator — PowerShell joins with `;` — and
/// `shrc ls PATH` can show one directory per row in search order.

///|
/// The separator used in the stored, canonical form.
pub let path_sep : String = ":"

///|
/// The search-path variables that are not simply named `*PATH`. Names ending
/// in `PATH` are recognised without being listed.
pub fn search_path_vars() -> Array[String] {
  [
    "CDPATH", "MANPATH", "INFOPATH", "FPATH", "LOCPATH", "NLSPATH", "PERL5LIB", "PKG_CONFIG_PATH",
    "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "LIBRARY_PATH",
    "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "CLASSPATH", "RUBYLIB", "GEM_PATH",
    "XDG_DATA_DIRS", "TERMINFO_DIRS",
  ]
}

///|
/// Whether `name` holds a search path. Any name ending in `PATH` counts, so
/// `PATH`, `PYTHONPATH`, `LD_LIBRARY_PATH` and a project's own `MYPATH` all
/// behave the same.
pub fn is_search_path_name(name : String) -> Bool {
  if name.view().has_suffix("PATH") {
    return true
  }
  for known in search_path_vars() {
    if known == name {
      return true
    }
  }
  false
}

///|
/// Whether an entry should be treated as a search path: an environment
/// variable whose stored flag or name says so.
pub fn is_search_path_entry(entry : Entry) -> Bool {
  kind_eq(entry.kind, Env) && (entry.list || is_search_path_name(entry.name))
}

///|
/// The separator `family` uses between search-path directories.
pub fn family_path_sep(family : ShellFamily) -> String {
  match family {
    PowerShell => ";"
    _ => ":"
  }
}

///|
/// Split a stored search-path value into its directories, in order. An empty
/// value has no directories.
pub fn split_path(value : String) -> Array[String] {
  if value.length() == 0 {
    return []
  }
  value.split(path_sep).map(part => part.to_owned()).to_array()
}

///|
/// Join directories back into the stored form.
pub fn join_path(parts : Array[String]) -> String {
  parts.join(path_sep)
}

///|
/// A directory as it is compared: a trailing `/` is insignificant, `/` itself
/// is kept.
pub fn normalize_dir(dir : String) -> String {
  let mut text = dir
  while text.length() > 1 && text.view().has_suffix("/") {
    text = text.view(end_offset=text.length() - 1).to_owned()
  }
  text
}

///|
/// Whether two directories name the same place.
pub fn same_dir(a : String, b : String) -> Bool {
  normalize_dir(a) == normalize_dir(b)
}

///|
/// Add `dir` to a search path, first removing an identical directory so
/// repeating the command never duplicates it. `at_end` adds it after the
/// existing directories instead of before them.
pub fn path_insert(value : String, dir : String, at_end : Bool) -> String {
  let kept = []
  for part in split_path(value) {
    if !same_dir(part, dir) {
      kept.push(part)
    }
  }
  if at_end {
    kept.push(dir)
  } else {
    kept.insert(0, dir)
  }
  join_path(kept)
}

///|
/// Remove every occurrence of `dir` from a search path. Returns the new value
/// and whether a directory was removed.
pub fn path_remove(value : String, dir : String) -> (String, Bool) {
  let kept = []
  let mut removed = false
  for part in split_path(value) {
    if same_dir(part, dir) {
      removed = true
    } else {
      kept.push(part)
    }
  }
  (join_path(kept), removed)
}

///|
/// The canonical self-reference of a variable: `$NAME` — so a search path
/// shrc creates keeps whatever the shell already had.
pub fn self_ref(name : String) -> String {
  "$" + name
}

///|
/// A value adopted from PowerShell, where search paths are joined by `;`:
/// stored canonically with `:` so every family can render it.
pub fn canonical_list(name : String, value : String) -> String {
  if is_search_path_name(name) && value.contains(";") {
    value.replace_all(old=";", new=":")
  } else {
    value
  }
}
