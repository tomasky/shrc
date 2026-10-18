///|
/// The shrc store: the manifest of managed entries, and the code that writes
/// them into every detected startup file.

///|
/// Read the manifest. A missing or unreadable manifest is an empty store, not
/// an error: the first `shrc set` creates it.
pub fn load_entries() -> Array[Entry] {
  let path = manifest_path()
  if !@fs.path_exists(path) {
    return []
  }
  let text = @fs.read_file_to_string(path) catch { _ => return [] }
  parse_entries(text)
}

///|
/// Persist the manifest, creating `SHRC_HOME` when needed.
pub fn save_entries(entries : Array[Entry]) -> Result[Unit, String] {
  match ensure_dir(shrc_home()) {
    Ok(_) => ()
    Err(msg) => return Err(msg)
  }
  @fs.write_string_to_file(manifest_path(), serialize_entries(entries)) catch {
    _ => return Err("cannot write '\{manifest_path()}'")
  }
  Ok(())
}

///|
/// Write `entries` into every startup file in `shells`.
///
/// Returns one human-readable message per file that could not be written; an
/// empty array means everything succeeded.
pub fn apply_to_shells(
  entries : Array[Entry],
  shells : Array[Shell],
) -> Array[String] {
  let errors = []
  for shell in shells {
    let exists = @fs.path_exists(shell.rc)
    let existing = if exists {
      @fs.read_file_to_string(shell.rc) catch {
        _ => ""
      }
    } else {
      ""
    }
    let updated = sync_block(existing, shell.family, entries)
    // Removing the last entry leaves an empty block, and an empty block in a
    // file that never existed should not create one.
    if exists || updated.length() > 0 {
      match ensure_dir(path_dirname(shell.rc)) {
        Ok(_) => ()
        Err(msg) => {
          errors.push(msg)
          continue
        }
      }
      @fs.write_string_to_file(shell.rc, updated) catch {
        _ => errors.push("cannot write '\{shell.rc}'")
      }
    }
  }
  errors
}

///|
/// One line per entry, in the order they are stored.
pub fn format_ls(entries : Array[Entry]) -> String {
  let out = StringBuilder()
  for entry in entries {
    out.write_string(kind_label(entry.kind))
    out.write_string("\t")
    out.write_string(entry.name)
    out.write_string("=")
    out.write_string(entry.value)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// The complete picture: the manifest, then every shell shrc would manage and
/// the block it would receive.
pub fn format_all(entries : Array[Entry], shells : Array[Shell]) -> String {
  let out = StringBuilder()
  out.write_string("# shrc — managed shell configuration\n")
  out.write_string("# home: \{shrc_home()}\n")
  out.write_string("\n# entries (\{entries.length()})\n")
  if entries.length() == 0 {
    out.write_string("#   (none)\n")
  } else {
    for entry in entries {
      out.write_string(
        "#   \{kind_label(entry.kind)}  \{entry.name}=\{entry.value}\n",
      )
    }
  }
  out.write_string("\n# startup files\n")
  for shell in shells {
    out.write_string("\n# \{shell.name}  \{shell.rc}\n")
    if entries.length() == 0 {
      out.write_string("#   (nothing to write)\n")
    } else {
      for entry in entries {
        out.write_string(render_entry(shell.family, entry))
        out.write_char('\n')
      }
    }
  }
  out.to_string()
}
