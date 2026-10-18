///|
/// The shells shrc knows how to write to, and where their startup files live.
///
/// shrc treats each shell as a *family* (POSIX or fish) plus a startup file.
/// Environment variables and aliases mean the same thing in every shell; only
/// the syntax differs, so the entry list is shared and the rendering is not.

///|
/// The syntax family a startup file is written in.
pub(all) enum ShellFamily {
  Posix
  Fish
}

///|
/// One shell: its short name, its syntax family and its startup file.
pub(all) struct Shell {
  name : String
  family : ShellFamily
  rc : String
}

///|
/// The canonical startup files for every supported shell, given the relevant
/// base directories. Pure, so tests can pin the layout.
pub fn candidate_shells(
  home : String,
  xdg : String,
  zdotdir : String,
) -> Array[Shell] {
  [
    { name: "profile", family: Posix, rc: path_join(home, ".profile"), },
    { name: "bash", family: Posix, rc: path_join(home, ".bashrc"), },
    { name: "zsh", family: Posix, rc: path_join(zdotdir, ".zshrc"), },
    { name: "fish", family: Fish, rc: path_join(xdg, "fish/config.fish"), },
  ]
}

///|
/// Pick the startup file for a shell that has both an interactive and a login
/// spelling. The interactive file wins when it exists; otherwise an existing
/// login file is used, and the interactive path is the fallback to create.
fn prefer_existing(
  primary : String,
  login : String,
  exists : (String) -> Bool,
) -> String {
  if exists(primary) {
    primary
  } else if exists(login) {
    login
  } else {
    primary
  }
}

///|
/// Detect the shells shrc should manage.
///
/// A shell is managed when its startup file already exists or it is the user's
/// login shell; when nothing at all is found, `~/.profile` is used as the
/// portable baseline. `exists` is injected so the decision is testable.
pub fn detect_shells(
  home : String,
  xdg : String,
  zdotdir : String,
  login_shell : String?,
  exists : (String) -> Bool,
) -> Array[Shell] {
  let login = match login_shell {
    Some(s) => path_basename(s)
    None => ""
  }
  let profile : Shell = {
    name: "profile",
    family: Posix,
    rc: path_join(home, ".profile"),
  }
  let bash : Shell = {
    name: "bash",
    family: Posix,
    rc: prefer_existing(
      path_join(home, ".bashrc"),
      path_join(home, ".bash_profile"),
      exists,
    ),
  }
  let zsh : Shell = {
    name: "zsh",
    family: Posix,
    rc: prefer_existing(
      path_join(zdotdir, ".zshrc"),
      path_join(zdotdir, ".zprofile"),
      exists,
    ),
  }
  let fish : Shell = {
    name: "fish",
    family: Fish,
    rc: path_join(xdg, "fish/config.fish"),
  }
  let out = []
  for shell in [profile, bash, zsh, fish] {
    if exists(shell.rc) || shell.name == login {
      out.push(shell)
    }
  }
  if out.length() == 0 {
    out.push(profile)
  }
  out
}

///|
/// Detect shells against the real filesystem and `$SHELL`.
pub fn current_shells() -> Array[Shell] {
  detect_shells(
    home_dir(),
    xdg_config_home(),
    zdotdir(),
    @env.get_env_var("SHELL"),
    @fs.path_exists,
  )
}

///|
/// All candidate shells against the real filesystem, regardless of detection.
/// Used by `shrc all` to report every file shrc could manage.
pub fn all_candidate_shells() -> Array[Shell] {
  candidate_shells(home_dir(), xdg_config_home(), zdotdir())
}

///|
/// The syntax family to use for the shell that will evaluate shrc's output.
/// `$SHELL` names the login shell; anything unknown is treated as POSIX.
pub fn eval_family(login_shell : String?) -> ShellFamily {
  match login_shell {
    Some(s) =>
      match path_basename(s) {
        "fish" => Fish
        _ => Posix
      }
    None => Posix
  }
}
