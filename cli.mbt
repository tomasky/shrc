///|
/// The shrc command-line interface.
///
/// `dispatch` is a pure-ish function: it returns the text to print and the
/// exit status, and performs its file writes through the store. Keeping the
/// printing out of it makes the commands testable without capturing a
/// terminal.

///|
/// What a command produced: an exit status, text for standard output and text
/// for standard error.
pub(all) struct CliResult {
  code : Int32
  out : String
  err : String
}

///|
fn ok(out : String) -> CliResult {
  { code: 0, out, err: "", }
}

///|
fn ok_with(out : String, err : String) -> CliResult {
  { code: 0, out, err, }
}

///|
fn failure(message : String) -> CliResult {
  { code: 1, out: "", err: message, }
}

///|
/// The help screen.
pub fn help_text() -> String {
  [
    "shrc — manage environment variables and aliases across shells", "", "Usage:",
    "  shrc set [-a|--alias] [-q|--quiet] NAME VALUE", "  shrc set [-a|--alias] [-q|--quiet] NAME=VALUE",
    "  shrc set [-p|--prepend | --append | --drop] [-q|--quiet] NAME VALUE", "  shrc set [-r|--raw] [-q|--quiet] NAME VALUE",
    "  shrc rm  [-a|--alias] [-q|--quiet] NAME", "  shrc ls  [NAME]", "  shrc all",
    "  shrc init [-n|--dry-run] [-q|--quiet]", "  shrc version", "  shrc help", "",
    "Commands:", "  set   Add or update an environment variable (default) or an alias in",
    "        every detected startup file (~/.profile, ~/.bashrc, ~/.zshrc,", "        ~/.config/fish/config.fish). Prints the statement to eval so the",
    "        change also applies to the current shell. A search-path variable", "        (PATH, PYTHONPATH, LD_LIBRARY_PATH, ...) is stored as an ordered",
    "        list: a directory on its own is prepended, --append puts it last.",
    "  rm    Remove every entry named NAME.", "  ls    List managed entries, optionally filtered by NAME. A search path",
    "        is listed as one row per directory, in search order.", "  all   Show the full managed configuration and every startup file.",
    "  init  Import the environment variables and aliases the detected startup",
    "        files already define: they become managed entries and move into", "        the shrc block. The installer runs this on a first install.",
    "", "Options:", "  -a, --alias   Operate on an alias instead of an environment variable.",
    "  -e, --env     Operate on an environment variable (the default).", "  -q, --quiet   Print neither the statement nor the summary.",
    "  -p, --prepend add a directory at the front of a search path.", "      --append  add a directory at the end of a search path.",
    "      --drop    remove a directory from a search path.", "  -r, --raw     store VALUE as shell syntax: $VAR references stay live.",
    "  -n, --dry-run init: report what would be imported, changing nothing.", "",
    "Apply a change to the current shell with eval:", "  eval \"$(shrc set EDITOR vim)\"",
    "  eval \"$(shrc rm EDITOR)\"", "  eval \"$(shrc set --prepend PATH /opt/bin)\"",
    "", "Environment:", "  SHRC_HOME   where the manifest lives (default: ~/.shrc)",
    "  SHELL       used to pick the syntax of the statement printed for eval",
  ].join("\n")
}

///|
/// A POSIX environment variable name: a letter or `_`, then letters, digits or
/// `_`. Anything else would not be valid `export` syntax and could break the
/// startup file it is written into.
pub fn is_valid_env_name(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  let first = chars[0]
  let first_ok = (first >= 'a' && first <= 'z') ||
    (first >= 'A' && first <= 'Z') ||
    first == '_'
  if !first_ok {
    return false
  }
  for i = 1; i < chars.length(); i = i + 1 {
    let ch = chars[i]
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_'
    if !ok {
      return false
    }
  }
  true
}

///|
/// An alias name: permissive enough for `..` and friends, but no whitespace or
/// shell metacharacters, so the rendered `alias NAME=...` stays a single
/// statement that cannot break out into code.
pub fn is_valid_alias_name(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  for ch in chars {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' ||
      ch == '-' ||
      ch == '.' ||
      ch == ':' ||
      ch == '@' ||
      ch == '%' ||
      ch == ',' ||
      ch == '+' ||
      ch == '^' ||
      ch == '/'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Split `NAME=VALUE` at the first `=`.
fn split_eq(text : String) -> (String, String)? {
  match text.find("=") {
    Some(index) =>
      Some(
        (
          text.view(end_offset=index).to_owned(),
          text.view(start_offset=index + 1).to_owned(),
        ),
      )
    None => None
  }
}

///|
/// The flags shared by `set` and `rm`. `kind` is `None` when neither `-a`
/// nor `-e` was given, which lets `rm` act on both kinds at once. The raw and
/// search-path flags only make sense for `set`, which rejects them elsewhere.
priv struct CommonFlags {
  kind : EntryKind?
  quiet : Bool
  raw : Bool
  prepend : Bool
  append_dir : Bool
  drop : Bool
}

///|
fn parse_common(args : Array[String]) -> (CommonFlags, Array[String]) {
  let mut kind : EntryKind? = None
  let mut quiet = false
  let mut raw = false
  let mut prepend = false
  let mut append_dir = false
  let mut drop = false
  let positional = []
  for arg in args {
    match arg {
      "-a" | "--alias" => kind = Some(Alias)
      "-e" | "--env" => kind = Some(Env)
      "-q" | "--quiet" => quiet = true
      "-r" | "--raw" => raw = true
      "-p" | "--prepend" => prepend = true
      "--append" => append_dir = true
      "--drop" => drop = true
      _ => positional.push(arg)
    }
  }
  ({ kind, quiet, raw, prepend, append_dir, drop, }, positional)
}

///|
/// Whether `kind` passes the `-a`/`-e` filter (`None` accepts both).
fn kind_matches(filter : EntryKind?, kind : EntryKind) -> Bool {
  match filter {
    None => true
    Some(wanted) => kind_eq(wanted, kind)
  }
}

///|
/// The statement that applies `entry` to the shell that is evaluating it.
fn apply_statement(entry : Entry) -> String {
  render_apply(current_eval_family(), entry)
}

///|
/// What `shrc set` decided: the entry to store, or `None` with a note when
/// there is nothing to change (dropping a directory that is not there).
priv struct SetOutcome {
  entry : Entry?
  note : String
}

///|
/// The entry one `shrc set` invocation should store.
///
/// A search path is special: a plain directory value is prepended so the
/// variable keeps its previous contents, `--append`/`--drop` move or remove a
/// single directory, and an identical directory is never duplicated.
fn set_entry(
  kind : EntryKind,
  name : String,
  value : String,
  flags : CommonFlags,
  existing : Entry?,
) -> Result[SetOutcome, String] {
  let path_like = kind_eq(kind, Env) && is_search_path_name(name)
  let base = match existing {
    Some(entry) => entry.value
    None => ""
  }
  let was_raw = match existing {
    Some(entry) => entry.raw
    None => true
  }
  if flags.drop {
    match existing {
      None => Ok({ entry: None, note: "no entry named \{name}", })
      Some(entry) => {
        let (updated, removed) = path_remove(entry.value, value)
        if !removed {
          Ok({ entry: None, note: "\{value} is not in \{name}", })
        } else {
          Ok({
            entry: Some(
              Entry::new_full(
                entry.kind,
                entry.name,
                updated,
                entry.raw,
                entry.list,
              ),
            ),
            note: "dropped \{value} from \{name}",
          })
        }
      }
    }
  } else if flags.prepend || flags.append_dir {
    let root = if base.length() > 0 { base } else { self_ref(name) }
    let updated = path_insert(root, value, flags.append_dir)
    let verb = if flags.append_dir { "appended" } else { "prepended" }
    Ok({
      entry: Some(Entry::new_full(Env, name, updated, was_raw, true)),
      note: "\{verb} \{value} to \{name}",
    })
  } else if flags.raw {
    if value.contains("\\") || !refs_translatable(value) {
      Err(
        "`\{value}` is not shell syntax shrc can translate; use --prepend or --append for one directory",
      )
    } else {
      let list = path_like ||
        (match existing {
          Some(entry) => entry.list
          None => false
        })
      Ok({
        entry: Some(
          Entry::new_full(Env, name, canonical_list(name, value), true, list),
        ),
        note: "",
      })
    }
  } else if path_like {
    if contains_live(value) {
      if value.contains("\\") ||
        !refs_translatable(value) ||
        value.contains("[") ||
        value.contains("]") ||
        value.contains("(") ||
        value.contains(")") {
        Err(
          "`\{value}` uses shell syntax shrc cannot translate; pass a directory, a plain search path, or --raw",
        )
      } else {
        Ok({
          entry: Some(
            Entry::new_full(Env, name, canonical_list(name, value), true, true),
          ),
          note: "",
        })
      }
    } else if value.contains(":") || value.contains(";") {
      Ok({
        entry: Some(
          Entry::new_full(Env, name, canonical_list(name, value), false, true),
        ),
        note: "",
      })
    } else {
      let root = if base.length() > 0 { base } else { self_ref(name) }
      let updated = path_insert(root, value, false)
      Ok({
        entry: Some(Entry::new_full(Env, name, updated, was_raw, true)),
        note: "prepended \{value} to \{name}",
      })
    }
  } else {
    Ok({ entry: Some(Entry::new(kind, name, value)), note: "", })
  }
}

///|
/// `shrc set ...`
fn cmd_set(args : Array[String]) -> CliResult {
  let (flags, positional) = parse_common(args)
  let (name, value) = match positional.length() {
    2 => (positional[0], positional[1])
    1 =>
      match split_eq(positional[0]) {
        Some(pair) => pair
        None => return failure("shrc: set needs NAME VALUE or NAME=VALUE")
      }
    _ => return failure("shrc: set needs NAME VALUE or NAME=VALUE")
  }
  let kind = flags.kind.unwrap_or(Env)
  if flags.prepend && flags.append_dir {
    return failure("shrc: set takes --prepend or --append, not both")
  }
  if flags.raw && (flags.prepend || flags.append_dir || flags.drop) {
    return failure(
      "shrc: --raw cannot be combined with --prepend, --append or --drop",
    )
  }
  if kind_eq(kind, Alias) &&
    (flags.raw || flags.prepend || flags.append_dir || flags.drop) {
    return failure(
      "shrc: --raw, --prepend, --append and --drop only apply to environment variables",
    )
  }
  let valid = match kind {
    Env => is_valid_env_name(name)
    Alias => is_valid_alias_name(name)
  }
  if !valid {
    return failure(
      match kind {
        Env => "shrc: '\{name}' is not a valid environment variable name"
        Alias => "shrc: '\{name}' is not a valid alias name"
      },
    )
  }
  let entries = load_entries()
  let existing = find_entry(entries, Entry::new(kind, name, value))
  let outcome = match set_entry(kind, name, value, flags, existing) {
    Ok(outcome) => outcome
    Err(message) => return failure("shrc: \{message}")
  }
  let entry = match outcome.entry {
    None => {
      if flags.quiet {
        return ok("")
      }
      return ok_with("", "shrc: \{outcome.note}")
    }
    Some(entry) => entry
  }
  let entries = upsert_entry(entries, entry)
  match save_entries(entries) {
    Ok(_) => ()
    Err(message) => return failure("shrc: \{message}")
  }
  let shells = current_shells()
  let errors = apply_to_shells(entries, shells)
  let out = if flags.quiet { "" } else { apply_statement(entry) }
  let notes = []
  if !flags.quiet {
    if outcome.note.length() > 0 {
      notes.push("shrc: \{outcome.note}")
    } else {
      notes.push(
        "shrc: set \{kind_label(entry.kind)} \{entry.name} in \{shells.length()} file(s)",
      )
    }
  }
  for message in errors {
    notes.push("shrc: \{message}")
  }
  if errors.length() > 0 {
    { code: 1, out, err: notes.join("\n"), }
  } else {
    ok_with(out, notes.join("\n"))
  }
}

///|
/// `shrc rm ...`
fn cmd_rm(args : Array[String]) -> CliResult {
  let (flags, positional) = parse_common(args)
  if flags.raw || flags.prepend || flags.append_dir || flags.drop {
    return failure("shrc: rm takes only -a, -e and -q")
  }
  if positional.length() != 1 {
    return failure("shrc: rm needs NAME")
  }
  let name = positional[0]
  let remaining = []
  let removed = []
  for entry in load_entries() {
    let matches = entry.name == name && kind_matches(flags.kind, entry.kind)
    if matches {
      removed.push(entry)
    } else {
      remaining.push(entry)
    }
  }
  match save_entries(remaining) {
    Ok(_) => ()
    Err(message) => return failure("shrc: \{message}")
  }
  let shells = current_shells()
  let errors = apply_to_shells(remaining, shells)
  let statements = []
  if !flags.quiet {
    let family = current_eval_family()
    for entry in removed {
      statements.push(render_remove(family, entry))
    }
  }
  let notes = []
  if removed.length() == 0 {
    notes.push("shrc: no entry named \{name}")
  } else if !flags.quiet {
    notes.push("shrc: removed \{name} from \{shells.length()} file(s)")
  }
  for message in errors {
    notes.push("shrc: \{message}")
  }
  let out = statements.join("\n")
  if errors.length() > 0 {
    { code: 1, out, err: notes.join("\n"), }
  } else {
    ok_with(out, notes.join("\n"))
  }
}

///|
/// Scan every detected startup file (and the files it sources) for definitions.
/// Merges them into `entries` (the loaded manifest) so conflicts and
/// duplicates are detected, and returns the newly imported entries plus the
/// scan details. Does not modify any file.
fn discover_candidates(
  entries : Array[Entry],
) -> (Array[Entry], Array[(Shell, FileScan, String)], Int32, Int32, Int32) {
  let shells = current_shells()
  let imported = []
  let scans = []
  let mut duplicates = 0
  let mut conflicts = 0
  let mut retained = 0
  let follow = []
  for shell in shells {
    if @fs.path_exists(shell.rc) {
      let original = @fs.read_file_to_string(shell.rc) catch { _ => "" }
      let scan = scan_file(shell.family, original)
      retained = retained + scan.retained
      if scan.entries.length() > 0 {
        scans.push((shell, scan, original))
      }
      let tally = merge_candidates(entries, imported, scan.entries)
      duplicates = duplicates + tally.0
      conflicts = conflicts + tally.1
      follow.push((shell.family, original))
    }
  }
  let seen = []
  for shell in shells {
    seen.push(shell.rc)
  }
  let queue = []
  for item in follow {
    let (family, original) = item
    for path in sourced_files(family, original) {
      if !array_contains(seen, path) {
        seen.push(path)
        queue.push((family, path))
      }
    }
  }
  for item in queue {
    let (family, path) = item
    let original = @fs.read_file_to_string(path) catch { _ => "" }
    let scan = scan_file(family, original)
    retained = retained + scan.retained
    if scan.entries.length() > 0 {
      scans.push((shell(path_basename(path), family, path), scan, original))
    }
    let tally = merge_candidates(entries, imported, scan.entries)
    duplicates = duplicates + tally.0
    conflicts = conflicts + tally.1
  }
  (imported, scans, duplicates, conflicts, retained)
}

///|
/// `shrc init [-n|--dry-run] [-q|--quiet]`
///
/// Import what the startup files already define into the manifest, so
/// `shrc ls` shows them. The startup files themselves are not touched: their
/// original definitions stay where they are, and `shrc set`/`shrc rm` are the
/// only commands that rewrite the managed block. A name the manifest already
/// knows keeps its value.
fn cmd_init(args : Array[String]) -> CliResult {
  let mut dry_run = false
  let mut quiet = false
  for arg in args {
    match arg {
      "-n" | "--dry-run" => dry_run = true
      "-q" | "--quiet" => quiet = true
      _ => return failure("shrc: init takes only -n/--dry-run and -q/--quiet")
    }
  }
  let entries = load_entries()
  let (imported, scans, duplicates, conflicts, retained) = discover_candidates(
    entries,
  )
  let has_work = imported.length() > 0 ||
    (scans.length() > 0 && entries.length() > 0)
  let notes = []
  if !quiet {
    if imported.length() > 0 {
      let verb = if dry_run { "would import" } else { "imported" }
      notes.push(
        "shrc: \{verb} \{imported.length()} entry(s) from \{scans.length()} file(s)",
      )
    } else if !has_work {
      notes.push("shrc: nothing to import")
    } else {
      notes.push("shrc: no new entries to import")
    }
    if duplicates > 0 && imported.length() > 0 {
      notes.push("shrc: skipped \{duplicates} duplicate(s)")
    }
    if conflicts > 0 {
      notes.push(
        "shrc: kept the managed value for \{conflicts} conflicting name(s)",
      )
    }
    if retained > 0 {
      notes.push(
        "shrc: \{retained} definition(s) could not be moved and stay in place",
      )
    }
  }
  let out = if quiet || imported.length() == 0 {
    ""
  } else {
    format_ls(imported).trim_end().to_owned()
  }
  if dry_run || imported.length() == 0 {
    return ok_with(out, notes.join("\n"))
  }
  match save_entries(entries) {
    Ok(_) => ()
    Err(message) => return failure("shrc: \{message}")
  }
  ok_with(out, notes.join("\n"))
}

///|
/// Append the optional shell integration (auto-eval for set/rm) to every
/// detected startup file that does not already contain it. Safe to call on
/// every run: it is guarded by a marker and never duplicates the block.
pub fn install_shell_integration() -> Unit {
  for shell in current_shells() {
    let block = shell_integration_block(shell.family)
    if block.length() > 0 && @fs.path_exists(shell.rc) {
      let current = @fs.read_file_to_string(shell.rc) catch { _ => "" }
      if !current.contains("shrc shell integration") {
        let next = if current.length() == 0 {
          block
        } else {
          current.trim_end().to_owned() + "\n\n" + block
        }
        @fs.write_string_to_file(shell.rc, next) catch {
          _ => ()
        }
      }
    }
  }
}

///|
/// A note for a store that has never been written — every install path except
/// the installer script lands here on the first run.
fn empty_store_note() -> String {
  if @fs.path_exists(manifest_path()) {
    ""
  } else {
    "shrc: no entries yet — run 'shrc init' to import your existing configuration"
  }
}

///|
/// `shrc ls [NAME]`
fn cmd_ls(args : Array[String]) -> CliResult {
  let filter = []
  for arg in args {
    if !arg.has_prefix("-") {
      filter.push(arg)
    }
  }
  let pattern = if filter.length() > 0 { filter[0] } else { "" }
  let entries = filter_entries(load_entries(), pattern)
  if entries.length() == 0 && pattern.length() > 0 {
    return failure("shrc: no entry matching '\{pattern}'")
  }
  let out = format_ls(entries).trim_end().to_owned()
  let note = if entries.length() == 0 { empty_store_note() } else { "" }
  if note.length() > 0 {
    ok_with(out, note)
  } else {
    ok(out)
  }
}

///|
/// `shrc all`
fn cmd_all(args : Array[String]) -> CliResult {
  for arg in args {
    if arg.has_prefix("-") {
      return failure("shrc: all takes no options")
    }
  }
  let entries = load_entries()
  let out = format_all(entries, current_shells()).trim_end().to_owned()
  let note = if entries.length() == 0 { empty_store_note() } else { "" }
  if note.length() > 0 {
    ok_with(out, note)
  } else {
    ok(out)
  }
}

///|
/// Run one shrc command. `args` is the argument list without the program name.
pub fn dispatch(args : Array[String]) -> CliResult {
  if args.length() == 0 {
    return ok(help_text())
  }
  let command = args[0]
  let rest = args.exact_view(start=1).to_owned()
  match command {
    "set" => cmd_set(rest)
    "rm" | "remove" | "unset" | "delete" => cmd_rm(rest)
    "ls" | "list" => cmd_ls(rest)
    "all" => cmd_all(rest)
    "init" => cmd_init(rest)
    "version" | "--version" | "-v" => ok("shrc \{shrc_version}")
    "help" | "--help" | "-h" => ok(help_text())
    _ => failure("shrc: unknown command '\{command}'\n\n" + help_text())
  }
}
