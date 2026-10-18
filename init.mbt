///|
/// `shrc init` support: adopt the environment variables and aliases a user
/// already has in their startup files.
///
/// Only top-level lines are candidates: a definition indented inside an `if`,
/// a `case` or a function belongs to that construct and is never moved. A
/// line that cannot be moved faithfully is left where it is and counted, so
/// the summary can say how much was skipped instead of silently moving half
/// of it.

///|
/// How one line of a startup file was handled.
priv enum LineScan {
  Adopt(Entry)
  Retain
  Ignore
}

///|
/// One scanned startup file.
pub(all) struct FileScan {
  /// The file text with the adopted top-level lines removed.
  cleaned : String
  /// The entries that could be adopted, in file order.
  entries : Array[Entry]
  /// Lines that look like definitions but could not be moved.
  retained : Int32
}

///|
/// A variable name starts with a letter or `_`.
fn is_name_start(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

///|
/// The rest of a variable name is letters, digits or `_`.
fn is_name_char(ch : Char) -> Bool {
  is_name_start(ch) || (ch >= '0' && ch <= '9')
}

///|
/// Read the variable name that begins at `chars[i]`.
fn read_name(chars : Array[Char], i : Int32) -> (String, Int32)? {
  if i >= chars.length() || !is_name_start(chars[i]) {
    return None
  }
  let out = StringBuilder()
  let mut j = i
  while j < chars.length() && is_name_char(chars[j]) {
    out.write_char(chars[j])
    j = j + 1
  }
  Some((out.to_string(), j))
}

///|
/// Parse the variable reference that starts at the `$` at `chars[i]`:
/// `$NAME`, `${NAME}`, or the `$env.NAME` / `$env:NAME` spellings of nushell
/// and PowerShell. Returns the variable name and the index just past the
/// reference.
fn scan_ref(chars : Array[Char], i : Int32) -> (String, Int32)? {
  let j = i + 1
  if j >= chars.length() {
    return None
  }
  if chars[j] == '{' {
    match read_name(chars, j + 1) {
      Some((name, next)) =>
        if next < chars.length() && chars[next] == '}' {
          Some((name, next + 1))
        } else {
          None
        }
      None => None
    }
  } else {
    match read_name(chars, j) {
      Some((name, next)) =>
        if name == "env" &&
          next < chars.length() &&
          (chars[next] == '.' || chars[next] == ':') {
          read_name(chars, next + 1)
        } else {
          Some((name, next))
        }
      None => None
    }
  }
}

///|
/// Whether every `$` in `text` is a variable reference shrc can translate
/// between shells. Command substitutions and backticks cannot be translated,
/// so a value containing them is not adopted.
pub fn refs_translatable(text : String) -> Bool {
  if text.contains("`") {
    return false
  }
  let chars = text.to_array()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '$' {
      match scan_ref(chars, i) {
        Some((_, next)) => i = next
        None => return false
      }
    } else {
      i = i + 1
    }
  }
  true
}

///|
/// The spelling of a variable reference in the syntax of `family`.
fn ref_text(family : ShellFamily, name : String) -> String {
  match family {
    Posix | Fish | Csh => "$\{name}"
    Nu => "$env.\{name}"
    PowerShell => "$env:\{name}"
  }
}

///|
/// Rewrite every variable reference in `value` for the syntax of `family`.
/// Values are stored canonically (`$NAME`), so a value adopted from nushell
/// or PowerShell renders correctly in every other family.
pub fn translate_refs(family : ShellFamily, value : String) -> String {
  let chars = value.to_array()
  let out = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '$' {
      match scan_ref(chars, i) {
        Some((name, next)) => {
          out.write_string(ref_text(family, name))
          i = next
        }
        None => {
          out.write_char('$')
          i = i + 1
        }
      }
    } else {
      out.write_char(chars[i])
      i = i + 1
    }
  }
  out.to_string()
}

///|
/// Whether `text` uses shell syntax that must stay live when rendered.
fn contains_live(text : String) -> Bool {
  text.contains("$") || text.contains("`")
}

///|
/// Whether an unquoted word can be moved as a literal value. Characters the
/// shell would treat as syntax, and `~` / `[...]` whose expansion depends on
/// position, disqualify it.
fn bare_value_ok(text : String) -> Bool {
  for forbidden in [";", "|", "&", "<", ">", "(", ")", "{", "}", "[", "]", "~"] {
    if text.contains(forbidden) {
      return false
    }
  }
  !text.has_prefix("#")
}

///|
/// Remove leading spaces and tabs.
fn strip_leading_ws(text : String) -> String {
  let chars = text.to_array()
  let mut i = 0
  while i < chars.length() && (chars[i] == ' ' || chars[i] == '\t') {
    i = i + 1
  }
  if i == 0 {
    text
  } else {
    text.view(start_offset=i).to_owned()
  }
}

///|
/// The text after `keyword` when `line` begins a `keyword ...` command, or
/// `None`. The keyword must be followed by whitespace, so `exported=1` is not
/// taken for an `export`.
fn after_keyword(line : String, keyword : String) -> String? {
  if !line.has_prefix(keyword) {
    return None
  }
  let rest = line.view(start_offset=keyword.length()).to_owned()
  if rest.length() == 0 {
    return None
  }
  let first = rest.to_array()[0]
  if first != ' ' && first != '\t' {
    return None
  }
  Some(strip_leading_ws(rest))
}

///|
/// Split a command line into words, keeping single- and double-quoted spans
/// together. `None` when a quote is left open.
fn split_words(text : String) -> Array[String]? {
  let words = []
  let chars = text.to_array()
  let mut i = 0
  while i < chars.length() {
    while i < chars.length() && (chars[i] == ' ' || chars[i] == '\t') {
      i = i + 1
    }
    if i >= chars.length() {
      break
    }
    let start = i
    let mut quote : Char? = None
    while i < chars.length() {
      let ch = chars[i]
      match quote {
        Some(open) => if ch == open { quote = None } else { () }
        None => if ch == '\'' || ch == '"' { quote = Some(ch) } else { () }
      }
      if quote is None && (chars[i] == ' ' || chars[i] == '\t') {
        break
      }
      i = i + 1
    }
    if quote is Some(_) {
      return None
    }
    words.push(text.view(start_offset=start, end_offset=i).to_owned())
  }
  Some(words)
}

///|
/// The shape of the text on the right of an assignment.
priv enum ValueForm {
  SingleQuoted(String)
  DoubleQuoted(String)
  BareWord(String)
  Unparsed
}

///|
/// Parse the text after `NAME=`: a single-quoted literal, a double-quoted
/// string, or a bare word (with an optional trailing comment). Anything else
/// — concatenations, escapes, a trailing command — is `Unparsed`.
fn parse_rhs(rhs : String) -> ValueForm {
  let chars = rhs.to_array()
  let len = chars.length()
  if len == 0 {
    return BareWord("")
  }
  let first = chars[0]
  if first == '\'' || first == '"' {
    if len >= 2 && chars[len - 1] == first {
      let inner = rhs.view(start_offset=1, end_offset=len - 1).to_owned()
      let has_quote = if first == '\'' {
        inner.contains("'")
      } else {
        inner.contains("\"")
      }
      if !has_quote {
        return if first == '\'' {
          SingleQuoted(inner)
        } else {
          DoubleQuoted(inner)
        }
      }
    }
    return Unparsed
  }
  let mut end = 0
  while end < len && chars[end] != ' ' && chars[end] != '\t' {
    end = end + 1
  }
  let token = rhs.view(end_offset=end).to_owned()
  let rest = rhs.view(start_offset=end).to_owned().to_array()
  let mut i = 0
  while i < rest.length() && (rest[i] == ' ' || rest[i] == '\t') {
    i = i + 1
  }
  if i < rest.length() && rest[i] != '#' {
    return Unparsed
  }
  if token.contains("'") || token.contains("\"") {
    return Unparsed
  }
  BareWord(token)
}

///|
/// The entry for an adopted environment variable. A search path is marked as
/// a list so rendering can use the family's separator and `shrc ls` can show
/// each directory on its own row.
fn env_entry(name : String, value : String, raw : Bool) -> Entry {
  Entry::new_full(Env, name, value, raw, is_search_path_name(name))
}

///|
/// Adopt `text` — the inside of a pair of double quotes, or an unquoted word —
/// as the value of environment variable `name`.
fn scan_env_text(name : String, text : String, bare : Bool) -> LineScan {
  if text.contains("\\") {
    return Retain
  }
  if bare && !bare_value_ok(text) {
    return Retain
  }
  if !contains_live(text) {
    return Adopt(env_entry(name, text, false))
  }
  if !refs_translatable(text) ||
    text.contains("[") ||
    text.contains("]") ||
    text.contains("(") ||
    text.contains(")") {
    return Retain
  }
  Adopt(env_entry(name, translate_refs(Posix, text), true))
}

///|
/// Adopt `rhs` as the value of environment variable `name`.
fn scan_env_value(name : String, rhs : String) -> LineScan {
  if !is_valid_env_name(name) {
    return Retain
  }
  match parse_rhs(rhs) {
    SingleQuoted(value) => Adopt(env_entry(name, value, false))
    DoubleQuoted(inner) => scan_env_text(name, inner, false)
    BareWord(token) => scan_env_text(name, token, true)
    Unparsed => Retain
  }
}

///|
/// The literal text of one alias word, or `None` when it uses variables or
/// escapes and cannot be moved literally.
fn alias_word_text(word : String) -> String? {
  match parse_rhs(word) {
    SingleQuoted(value) => Some(value)
    DoubleQuoted(inner) =>
      if contains_live(inner) || inner.contains("\\") {
        None
      } else {
        Some(inner)
      }
    BareWord(token) =>
      if token.length() == 0 ||
        contains_live(token) ||
        token.contains("\\") ||
        !bare_value_ok(token) {
        None
      } else {
        Some(token)
      }
    Unparsed => None
  }
}

///|
/// Adopt `rhs` as the value of alias `name`.
fn scan_alias_value(name : String, rhs : String) -> LineScan {
  if !is_valid_alias_name(name) {
    return Retain
  }
  match alias_word_text(rhs) {
    Some(value) => Adopt(Entry::new(Alias, name, value))
    None => Retain
  }
}

///|
/// Whether `name` is spelled like an environment variable: valid, and with no
/// lowercase letters. A bare assignment of a mixed-case name is usually a
/// shell-local helper (`__conda_setup=...`), not an environment variable.
fn is_env_style_name(name : String) -> Bool {
  if !is_valid_env_name(name) {
    return false
  }
  for ch in name.to_array() {
    if ch >= 'a' && ch <= 'z' {
      return false
    }
  }
  true
}

///|
/// `NAME=VALUE` from an `export NAME=VALUE` statement.
fn posix_assign(rest : String) -> LineScan {
  match split_eq(rest) {
    Some((name, rhs)) => scan_env_value(name, rhs)
    None => Ignore
  }
}

///|
/// Scan a line of a POSIX shell startup file (`~/.bashrc`, `~/.zshrc`, ...):
/// `export NAME=VALUE`, `alias NAME=VALUE`, and bare `NAME=VALUE`.
fn scan_posix(line : String) -> LineScan {
  match after_keyword(line, "export") {
    Some(rest) => posix_assign(rest)
    None =>
      match after_keyword(line, "alias") {
        Some(rest) => posix_assign_alias(rest)
        None =>
          match split_eq(line) {
            Some((name, rhs)) =>
              // A bare assignment the shell does not export: still a variable
              // the user has, so it is managed like one — when it is spelled
              // like an environment variable.
              if is_env_style_name(name) {
                scan_env_value(name, rhs)
              } else {
                Ignore
              }
            None => Ignore
          }
      }
  }
}

///|
/// `NAME=VALUE` from an `alias NAME=VALUE` statement.
fn posix_assign_alias(rest : String) -> LineScan {
  match split_eq(rest) {
    Some((name, rhs)) => scan_alias_value(name, rhs)
    None => Ignore
  }
}

///|
/// `alias NAME VALUE...` in fish and csh, where the value is the command line
/// the name expands to. A trailing `#` comment is not part of the alias.
fn alias_list_line(rest : String) -> LineScan {
  let words = match split_words(rest) {
    Some(words) => words
    None => return Retain
  }
  if words.length() == 0 {
    return Ignore
  }
  let name = words[0]
  if !is_valid_alias_name(name) {
    return Retain
  }
  if words.length() == 1 {
    return Ignore
  }
  let parts = []
  let mut i = 1
  while i < words.length() {
    if words[i].has_prefix("#") {
      break
    }
    match alias_word_text(words[i]) {
      Some(text) => parts.push(text)
      None => return Retain
    }
    i = i + 1
  }
  if parts.length() == 0 {
    return Ignore
  }
  Adopt(Entry::new(Alias, name, parts.join(" ")))
}

///|
/// `set -gx NAME VALUE` in fish. Only an exported variable with exactly one
/// value is adopted; a fish list value has no equivalent in the other shells.
fn fish_set(rest : String) -> LineScan {
  let words = match split_words(rest) {
    Some(words) => words
    None => return Retain
  }
  let mut manageable = false
  let mut exported = false
  let mut i = 0
  while i < words.length() && words[i].has_prefix("-") && words[i] != "-" {
    let flag = words[i]
    if flag == "--export" {
      manageable = true
      exported = true
      i = i + 1
    } else if flag == "--global" || flag == "--universal" {
      manageable = true
      i = i + 1
    } else if flag == "--function" || flag == "--local" {
      // A variable scoped to the script or a function never outlives the
      // file that defines it.
      return Ignore
    } else if flag == "--query" || flag == "--unexport" {
      return Ignore
    } else if flag == "--append" || flag == "--prepend" {
      return Retain
    } else if flag.has_prefix("--") {
      return Retain
    } else {
      let letters = flag.view(start_offset=1).to_owned()
      let mut known = true
      for ch in letters.to_array() {
        if ch == 'x' {
          manageable = true
          exported = true
        } else if ch == 'g' || ch == 'U' {
          manageable = true
        } else if ch == 'f' || ch == 'l' || ch == 'q' || ch == 'u' {
          return Ignore
        } else if ch == 'a' || ch == 'p' {
          return Retain
        } else {
          known = false
        }
      }
      if !known {
        return Retain
      }
      i = i + 1
    }
  }
  if !manageable || i >= words.length() {
    // `set NAME VALUE` without a scope is local to the file that writes it.
    return Ignore
  }
  let name = words[i]
  if !exported && !is_env_style_name(name) {
    // A global that fish itself uses (`set -g fish_greeting ...`) is not an
    // environment variable.
    return Ignore
  }
  let values = words.exact_view(start=i + 1).to_owned()
  if values.length() == 0 || values[0].has_prefix("#") {
    return Ignore
  }
  if values.length() > 1 {
    return Retain
  }
  scan_env_value(name, values[0])
}

///|
/// Scan a line of a fish startup file (`~/.config/fish/config.fish`).
fn scan_fish(line : String) -> LineScan {
  match after_keyword(line, "set") {
    Some(rest) => fish_set(rest)
    None =>
      match after_keyword(line, "alias") {
        Some(rest) => alias_list_line(rest)
        None => Ignore
      }
  }
}

///|
/// `setenv NAME VALUE` in csh.
fn csh_setenv(rest : String) -> LineScan {
  let words = match split_words(rest) {
    Some(words) => words
    None => return Retain
  }
  if words.length() < 2 {
    return Ignore
  }
  if words.length() > 2 {
    return Retain
  }
  if words[1].has_prefix("#") {
    return Ignore
  }
  scan_env_value(words[0], words[1])
}

///|
/// Scan a line of a csh/tcsh startup file.
fn scan_csh(line : String) -> LineScan {
  match after_keyword(line, "setenv") {
    Some(rest) => csh_setenv(rest)
    None =>
      match after_keyword(line, "alias") {
        Some(rest) => alias_list_line(rest)
        None => Ignore
      }
  }
}

///|
/// A nushell environment value: `'literal'`, `"literal"`, or the
/// interpolating `$"..."` / `$'...'`.
fn nu_value(name : String, value : String) -> LineScan {
  if value.has_prefix("$'") || value.has_prefix("$\"") {
    let chars = value.to_array()
    let quote = chars[1]
    if chars.length() < 3 || chars[chars.length() - 1] != quote {
      return Retain
    }
    let inner = value
      .view(start_offset=2, end_offset=value.length() - 1)
      .to_owned()
    if inner.contains("\\") ||
      !refs_translatable(inner) ||
      inner.contains("[") ||
      inner.contains("]") ||
      inner.contains("(") ||
      inner.contains(")") {
      return Retain
    }
    Adopt(env_entry(name, translate_refs(Posix, inner), true))
  } else {
    match parse_rhs(value) {
      SingleQuoted(v) => Adopt(env_entry(name, v, false))
      DoubleQuoted(inner) =>
        if inner.contains("\\") || contains_live(inner) {
          Retain
        } else {
          Adopt(env_entry(name, inner, false))
        }
      _ => Retain
    }
  }
}

///|
/// `$env.NAME = VALUE` in nushell: `rest` is the text after `$env.`.
fn nu_env(rest : String) -> LineScan {
  match split_eq(rest) {
    None => Retain
    Some((raw_name, raw_value)) => {
      let name = raw_name.trim().to_owned()
      let value = raw_value.trim().to_owned()
      if !is_valid_env_name(name) {
        return Retain
      }
      if value.length() == 0 {
        return Ignore
      }
      nu_value(name, value)
    }
  }
}

///|
/// `alias NAME = VALUE` in nushell.
fn nu_alias(rest : String) -> LineScan {
  match split_eq(rest) {
    None => Ignore
    Some((raw_name, raw_value)) => {
      let name = raw_name.trim().to_owned()
      let value = raw_value.trim().to_owned()
      if !is_valid_alias_name(name) {
        return Retain
      }
      if value.length() == 0 {
        return Ignore
      }
      if value.contains("#") || value.contains(";") || value.contains("\\") {
        return Retain
      }
      Adopt(Entry::new(Alias, name, value))
    }
  }
}

///|
/// Scan a line of a nushell config file.
fn scan_nu(line : String) -> LineScan {
  if line.has_prefix("$env.") {
    nu_env(line.view(start_offset=5).to_owned())
  } else if line.has_prefix("${env:") {
    match line.find("}") {
      Some(end) =>
        if end > 6 {
          let name = line.view(start_offset=6, end_offset=end).to_owned()
          nu_env("\{name}=\{line.view(start_offset=end + 1)}")
        } else {
          Ignore
        }
      None => Ignore
    }
  } else {
    match after_keyword(line, "alias") {
      Some(rest) => nu_alias(rest)
      None => Ignore
    }
  }
}

///|
/// `NAME = VALUE` from a PowerShell `$env:NAME = VALUE` statement.
fn pwsh_env(rest : String) -> LineScan {
  match split_eq(rest) {
    None => Ignore
    Some((raw_name, raw_value)) => {
      let name = raw_name.trim().to_owned()
      let value = raw_value.trim().to_owned()
      if !is_valid_env_name(name) {
        return Retain
      }
      if value.length() == 0 || value == "$null" {
        return Ignore
      }
      match parse_rhs(value) {
        SingleQuoted(v) =>
          Adopt(env_entry(name, canonical_list(name, v), false))
        DoubleQuoted(inner) =>
          if inner.contains("`") || inner.contains("\\") {
            Retain
          } else {
            scan_env_text(name, canonical_list(name, inner), false)
          }
        BareWord(token) =>
          if token.contains("`") {
            Retain
          } else {
            scan_env_text(name, canonical_list(name, token), true)
          }
        Unparsed => Retain
      }
    }
  }
}

///|
/// Scan a line of a PowerShell profile.
fn scan_pwsh(line : String) -> LineScan {
  if line.has_prefix("$env:") {
    pwsh_env(line.view(start_offset=5).to_owned())
  } else if line.has_prefix("${env:") {
    match line.find("}") {
      Some(end) =>
        if end > 6 {
          let name = line.view(start_offset=6, end_offset=end).to_owned()
          pwsh_env("\{name}=\{line.view(start_offset=end + 1)}")
        } else {
          Ignore
        }
      None => Ignore
    }
  } else {
    Ignore
  }
}

///|
/// Scan one line in the syntax of `family`.
fn scan_line(family : ShellFamily, line : String) -> LineScan {
  match family {
    Posix => scan_posix(line)
    Fish => scan_fish(line)
    Csh => scan_csh(line)
    Nu => scan_nu(line)
    PowerShell => scan_pwsh(line)
  }
}

///|
/// Join the retained lines back into file text.
fn join_file_lines(lines : Array[String]) -> String {
  if lines.length() == 0 {
    ""
  } else {
    lines.join("\n") + "\n"
  }
}

///|
/// The whitespace that indents `line`.
fn indent_of(line : String) -> String {
  let chars = line.to_array()
  let mut i = 0
  while i < chars.length() && (chars[i] == ' ' || chars[i] == '\t') {
    i = i + 1
  }
  line.view(end_offset=i).to_owned()
}

///|
/// The first word of a line of shell, ignoring indentation.
fn first_word(line : String) -> String {
  match split_words(strip_leading_ws(line)) {
    Some(words) => if words.length() > 0 { words[0] } else { "" }
    None => ""
  }
}

///|
/// The first word of every `;`-separated segment of a line, so one-liners
/// like `if true; then ...; fi` count their keywords too.
fn segment_words(line : String) -> Array[String] {
  let out = []
  for segment in line.split(";") {
    let word = first_word(segment.to_owned())
    if word.length() > 0 {
      out.push(word)
    }
  }
  out
}

///|
/// The conditional nesting change of one line of POSIX shell: `if`, `for`,
/// `while`, `until`, `case` and `select` open a block, `fi`, `done` and
/// `esac` close one.
fn posix_block_delta(line : String) -> Int32 {
  let mut delta = 0
  for word in segment_words(line) {
    if word == "if" ||
      word == "for" ||
      word == "while" ||
      word == "until" ||
      word == "case" ||
      word == "select" {
      delta = delta + 1
    } else if word == "fi" || word == "done" || word == "esac" {
      delta = delta - 1
    }
  }
  delta
}

///|
/// The brace nesting change of one line of POSIX shell: a line that ends in
/// `{` opens a function body or a group, a line that starts with `}` closes
/// one.
fn brace_delta(line : String) -> Int32 {
  let trimmed = strip_leading_ws(line).trim_end().to_owned()
  let opens = if trimmed.view().has_suffix("{") { 1 } else { 0 }
  let closes = if trimmed.view().has_prefix("}") { 1 } else { 0 }
  opens - closes
}

///|
/// The fish nesting change of one line, given the current depths. An `end`
/// closes a function only when every block still open is a function, which is
/// what `depth == functions` means.
fn fish_block_delta(
  line : String,
  depth_before : Int32,
  functions_before : Int32,
) -> (Int32, Int32) {
  let mut depth = depth_before
  let mut functions = functions_before
  for word in segment_words(line) {
    if word == "function" ||
      word == "if" ||
      word == "for" ||
      word == "while" ||
      word == "switch" ||
      word == "begin" {
      depth = depth + 1
      if word == "function" {
        functions = functions + 1
      }
    } else if word == "end" && depth > 0 {
      if functions > 0 && depth == functions {
        functions = functions - 1
      }
      depth = depth - 1
    }
  }
  (depth - depth_before, functions - functions_before)
}

///|
/// The terminator of the here-document a line opens (`<<EOF`, `<<-EOF`,
/// `<<'EOF'`), or `None` when the line opens none.
fn heredoc_terminator(line : String) -> String? {
  match line.find("<<") {
    None => None
    Some(index) => {
      let rest = line.view(start_offset=index + 2).to_owned().to_array()
      let mut i = 0
      if i < rest.length() && rest[i] == '-' {
        i = i + 1
      }
      if i >= rest.length() {
        return None
      }
      if rest[i] == '\'' || rest[i] == '"' {
        let quote = rest[i]
        i = i + 1
        let out = StringBuilder()
        while i < rest.length() && rest[i] != quote {
          out.write_char(rest[i])
          i = i + 1
        }
        if i >= rest.length() || out.to_string().length() == 0 {
          return None
        }
        Some(out.to_string())
      } else if is_name_start(rest[i]) {
        let out = StringBuilder()
        while i < rest.length() && is_name_char(rest[i]) {
          out.write_char(rest[i])
          i = i + 1
        }
        Some(out.to_string())
      } else {
        // `<<<` herestrings and arithmetic shifts open no document.
        None
      }
    }
  }
}

///|
/// Scan one startup file: every line that defines an entry becomes a
/// candidate, and the file text comes back with the adopted lines removed —
/// or, where removing one would empty a conditional body or fan out a
/// helper, replaced by a no-op (`:`) so the file stays valid.
///
/// A definition inside a function body belongs to code that runs later and is
/// never touched. Lines inside a managed block are read as candidates too —
/// they let `shrc init` rebuild a manifest that was lost — but they are never
/// removed, because the block is rewritten from the manifest anyway.
pub fn scan_file(family : ShellFamily, text : String) -> FileScan {
  let kept = []
  let entries = []
  let mut retained = 0
  let mut in_block = false
  // Per-family nesting state: POSIX brace depth (function bodies), POSIX
  // conditional depth, POSIX here-document terminator, fish block depths.
  let mut braces = 0
  let mut blocks = 0
  let mut heredoc = ""
  let mut fish_depth = 0
  let mut fish_functions = 0
  for line in split_lines(text) {
    if line == block_begin {
      in_block = true
      kept.push(line)
    } else if line == block_end {
      in_block = false
      kept.push(line)
    } else {
      let indented = line.has_prefix(" ") || line.has_prefix("\t")
      let mut nested = indented
      let mut skip = false
      match family {
        Posix =>
          if heredoc != "" {
            if line.trim().to_owned() == heredoc {
              heredoc = ""
            }
            kept.push(line)
            skip = true
          } else {
            if line.contains("<<") {
              match heredoc_terminator(line) {
                Some(term) => heredoc = term
                None => ()
              }
            }
            if braces > 0 {
              // Inside a function body: never moved.
              kept.push(line)
              skip = true
            }
            nested = nested || blocks > 0
            blocks = blocks + posix_block_delta(line)
            braces = braces + brace_delta(line)
          }
        Fish => {
          let in_function = fish_functions > 0
          let (depth_delta, function_delta) = fish_block_delta(
            line, fish_depth, fish_functions,
          )
          fish_depth = fish_depth + depth_delta
          fish_functions = fish_functions + function_delta
          if in_function {
            kept.push(line)
            skip = true
          }
          nested = nested || fish_depth > 0 || fish_functions > 0
        }
        Csh | Nu | PowerShell =>
          if indented {
            // These families keep their conditional bodies unparseable enough
            // that only a top-level definition is safe to move.
            kept.push(line)
            skip = true
          }
      }
      if !skip {
        match scan_line(family, strip_leading_ws(line)) {
          Adopt(entry) => {
            entries.push(entry)
            if in_block {
              kept.push(line)
            } else if nested {
              kept.push(indent_of(line) + ":")
            }
            // At the top level the line disappears: the block carries it now.
          }
          Retain => {
            retained = retained + 1
            kept.push(line)
          }
          Ignore => kept.push(line)
        }
      }
    }
  }
  { cleaned: join_file_lines(kept), entries, retained, }
}

///|
/// The entry with the same kind and name as `wanted`, if any.
pub fn find_entry(entries : Array[Entry], wanted : Entry) -> Entry? {
  for entry in entries {
    if kind_eq(entry.kind, wanted.kind) && entry.name == wanted.name {
      return Some(entry)
    }
  }
  None
}

///|
/// Whether `items` holds `value`.
fn array_contains(items : Array[String], value : String) -> Bool {
  for item in items {
    if item == value {
      return true
    }
  }
  false
}

///|
/// Drop the shell punctuation a path token may carry (`;` after a source on
/// one line, for example).
fn trim_token_end(token : String) -> String {
  let chars = token.to_array()
  let mut end = chars.length()
  while end > 0 {
    let ch = chars[end - 1]
    if ch == ';' || ch == '&' || ch == '|' || ch == ')' {
      end = end - 1
    } else {
      break
    }
  }
  token.view(end_offset=end).to_owned()
}

///|
/// Resolve `~/...`, `$HOME/...` or `${HOME}/...` to an absolute path.
fn home_path(token : String) -> String? {
  let home = home_dir()
  if token.has_prefix("~/") {
    Some(path_join(home, token.view(start_offset=2).to_owned()))
  } else if token.has_prefix("$HOME/") {
    Some(path_join(home, token.view(start_offset=6).to_owned()))
  } else if token.has_prefix("${HOME}/") {
    Some(path_join(home, token.view(start_offset=8).to_owned()))
  } else {
    None
  }
}

///|
/// The literal text of a path word, or `None` when it is quoted with
/// expansion inside.
fn token_text(word : String) -> String? {
  match parse_rhs(word) {
    SingleQuoted(value) => Some(value)
    DoubleQuoted(inner) => if contains_live(inner) { None } else { Some(inner) }
    BareWord(token) => Some(token)
    Unparsed => None
  }
}

///|
/// The file a `.`/`source` line loads, as a path under the home directory.
/// Only `~` and `$HOME` paths are followed — shrc never walks the system
/// includes — and comments are ignored.
fn source_path_text(line : String) -> String? {
  if line.length() == 0 || line.has_prefix("#") {
    return None
  }
  for marker in [". ", "source "] {
    match line.find(marker) {
      Some(index) => {
        let before = if index == 0 { ' ' } else { line.to_array()[index - 1] }
        let at_word_start = before == ' ' ||
          before == '\t' ||
          before == ';' ||
          before == '&' ||
          before == '(' ||
          before == '|'
        if at_word_start {
          let rest = line.view(start_offset=index + marker.length()).to_owned()
          match split_words(rest) {
            Some(words) =>
              if words.length() > 0 {
                match token_text(words[0]) {
                  Some(token) =>
                    match home_path(trim_token_end(token)) {
                      Some(path) => return Some(path)
                      None => ()
                    }
                  None => ()
                }
              }
            None => ()
          }
        }
      }
      None => ()
    }
  }
  None
}

///|
/// The files a startup file loads with `.`/`source`, resolved under the home
/// directory. They are scanned like the startup file itself, so definitions
/// kept in a companion like `~/.bash_aliases` are managed too.
pub fn sourced_files(family : ShellFamily, text : String) -> Array[String] {
  let out = []
  match family {
    Nu | PowerShell => return out
    Posix | Fish | Csh => ()
  }
  for line in split_lines(text) {
    match source_path_text(strip_leading_ws(line)) {
      Some(path) =>
        if !array_contains(out, path) && @fs.path_exists(path) {
          out.push(path)
        }
      None => ()
    }
  }
  out
}

///|
/// Merge a file's candidates into `entries`, appending new ones to
/// `imported`. Returns `(duplicates, conflicts)`: a duplicate is a line that
/// repeats an existing value, a conflict a line with a different value for an
/// existing name, which keeps the existing value.
pub fn merge_candidates(
  entries : Array[Entry],
  imported : Array[Entry],
  candidates : Array[Entry],
) -> (Int32, Int32) {
  let mut duplicates = 0
  let mut conflicts = 0
  for candidate in candidates {
    match find_entry(entries, candidate) {
      Some(previous) =>
        if entry_eq(previous, candidate) {
          duplicates = duplicates + 1
        } else {
          conflicts = conflicts + 1
        }
      None => {
        entries.push(candidate)
        imported.push(candidate)
      }
    }
  }
  (duplicates, conflicts)
}
