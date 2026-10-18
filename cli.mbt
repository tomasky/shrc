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
    "  shrc rm  [-a|--alias] [-q|--quiet] NAME", "  shrc ls  [NAME]", "  shrc all",
    "  shrc version", "  shrc help", "", "Commands:", "  set   Add or update an environment variable (default) or an alias in",
    "        every detected startup file (~/.profile, ~/.bashrc, ~/.zshrc,", "        ~/.config/fish/config.fish). Prints the statement to eval so the",
    "        change also applies to the current shell.", "  rm    Remove every entry named NAME.",
    "  ls    List managed entries, optionally filtered by NAME.", "  all   Show the full managed configuration and every startup file.",
    "", "Options:", "  -a, --alias   Operate on an alias instead of an environment variable.",
    "  -e, --env     Operate on an environment variable (the default).", "  -q, --quiet   Print neither the statement nor the summary.",
    "", "Apply a change to the current shell with eval:", "  eval \"$(shrc set EDITOR vim)\"",
    "  eval \"$(shrc rm EDITOR)\"", "", "Environment:", "  SHRC_HOME   where the manifest lives (default: ~/.shrc)",
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
/// nor `-e` was given, which lets `rm` act on both kinds at once.
priv struct CommonFlags {
  kind : EntryKind?
  quiet : Bool
}

///|
fn parse_common(args : Array[String]) -> (CommonFlags, Array[String]) {
  let mut kind : EntryKind? = None
  let mut quiet = false
  let positional = []
  for arg in args {
    match arg {
      "-a" | "--alias" => kind = Some(Alias)
      "-e" | "--env" => kind = Some(Env)
      "-q" | "--quiet" => quiet = true
      _ => positional.push(arg)
    }
  }
  ({ kind, quiet, }, positional)
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
/// The statement that applies `entry` to the shell named by `$SHELL`.
fn apply_statement(entry : Entry) -> String {
  render_apply(eval_family(@env.get_env_var("SHELL")), entry)
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
  let entry = Entry::new(kind, name, value)
  let entries = upsert_entry(load_entries(), entry)
  match save_entries(entries) {
    Ok(_) => ()
    Err(message) => return failure("shrc: \{message}")
  }
  let shells = current_shells()
  let errors = apply_to_shells(entries, shells)
  let out = if flags.quiet { "" } else { apply_statement(entry) }
  let notes = []
  if !flags.quiet {
    notes.push(
      "shrc: set \{kind_label(entry.kind)} \{entry.name} in \{shells.length()} file(s)",
    )
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
    let family = eval_family(@env.get_env_var("SHELL"))
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
  ok(format_ls(entries).trim_end().to_owned())
}

///|
/// `shrc all`
fn cmd_all(args : Array[String]) -> CliResult {
  for arg in args {
    if arg.has_prefix("-") {
      return failure("shrc: all takes no options")
    }
  }
  ok(format_all(load_entries(), current_shells()).trim_end().to_owned())
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
    "version" | "--version" | "-v" => ok("shrc \{shrc_version}")
    "help" | "--help" | "-h" => ok(help_text())
    _ => failure("shrc: unknown command '\{command}'\n\n" + help_text())
  }
}
