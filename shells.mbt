///|
/// The shells shrc knows how to write to, and where their startup files live.
///
/// shrc treats each shell as a *family* (POSIX, fish, csh, nushell) plus a
/// startup file. Environment variables and aliases mean the same thing in
/// every shell; only the syntax differs, so the entry list is shared and the
/// rendering is not.

///|
/// The syntax family a startup file is written in.
pub(all) enum ShellFamily {
  Posix
  Fish
  Csh
  Nu
  PowerShell
}

///|
/// One startup file: the shell it belongs to, its syntax family and its path.
pub(all) struct Shell {
  name : String
  family : ShellFamily
  rc : String
}

///|
/// Build a shell record.
fn shell(name : String, family : ShellFamily, rc : String) -> Shell {
  { name, family, rc, }
}

///|
/// Every startup file shrc knows about, given the relevant base directories.
/// Pure, so tests can pin the layout.
pub fn candidate_shells(
  home : String,
  xdg : String,
  zdotdir : String,
) -> Array[Shell] {
  [
    shell("profile", Posix, path_join(home, ".profile")),
    shell("bash", Posix, path_join(home, ".bashrc")),
    shell("bash_profile", Posix, path_join(home, ".bash_profile")),
    shell("bash_login", Posix, path_join(home, ".bash_login")),
    shell("zsh", Posix, path_join(zdotdir, ".zshrc")),
    shell("zprofile", Posix, path_join(zdotdir, ".zprofile")),
    shell("zshenv", Posix, path_join(zdotdir, ".zshenv")),
    shell("ksh", Posix, path_join(home, ".kshrc")),
    shell("mksh", Posix, path_join(home, ".mkshrc")),
    shell("fish", Fish, path_join(xdg, "fish/config.fish")),
    shell("csh", Csh, path_join(home, ".cshrc")),
    shell("tcsh", Csh, path_join(home, ".tcshrc")),
    shell("csh_login", Csh, path_join(home, ".login")),
    shell("nu", Nu, path_join(xdg, "nushell/config.nu")),
    shell("nu_env", Nu, path_join(xdg, "nushell/env.nu")),
    // PowerShell 7 on Linux and macOS reads its profile from the config dir.
    shell(
      "pwsh",
      PowerShell,
      path_join(xdg, "powershell/Microsoft.PowerShell_profile.ps1"),
    ),
    // PowerShell 7 and Windows PowerShell 5.1 on Windows keep theirs under
    // Documents; `home` is %USERPROFILE% there.
    shell(
      "powershell",
      PowerShell,
      path_join(home, "Documents/PowerShell/Microsoft.PowerShell_profile.ps1"),
    ),
    shell(
      "windows_powershell",
      PowerShell,
      path_join(
        home, "Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1",
      ),
    ),
  ]
}

///|
/// The first path that exists, or the first one as the file to create.
fn first_existing(paths : Array[String], exists : (String) -> Bool) -> String {
  for path in paths {
    if exists(path) {
      return path
    }
  }
  paths[0]
}

///|
/// Build the startup file for a login shell, preferring a file that already
/// exists so a login file is never shadowed by a new interactive one.
fn pick_shell(
  name : String,
  family : ShellFamily,
  paths : Array[String],
  exists : (String) -> Bool,
) -> Shell {
  shell(name, family, first_existing(paths, exists))
}

///|
/// The startup file for the login shell, or `None` for a shell shrc does not
/// know.
fn login_primary(
  login : String,
  home : String,
  xdg : String,
  zdotdir : String,
  exists : (String) -> Bool,
) -> Shell? {
  match login {
    "bash" =>
      Some(
        pick_shell(
          "bash",
          Posix,
          [
            path_join(home, ".bashrc"),
            path_join(home, ".bash_profile"),
            path_join(home, ".bash_login"),
          ],
          exists,
        ),
      )
    "zsh" =>
      Some(
        pick_shell(
          "zsh",
          Posix,
          [
            path_join(zdotdir, ".zshrc"),
            path_join(zdotdir, ".zprofile"),
            path_join(zdotdir, ".zshenv"),
          ],
          exists,
        ),
      )
    "ksh" =>
      Some(
        pick_shell(
          "ksh",
          Posix,
          [path_join(home, ".kshrc"), path_join(home, ".profile")],
          exists,
        ),
      )
    "mksh" =>
      Some(
        pick_shell(
          "mksh",
          Posix,
          [path_join(home, ".mkshrc"), path_join(home, ".profile")],
          exists,
        ),
      )
    "sh" | "dash" | "ash" =>
      Some(pick_shell("profile", Posix, [path_join(home, ".profile")], exists))
    "fish" =>
      Some(
        pick_shell("fish", Fish, [path_join(xdg, "fish/config.fish")], exists),
      )
    "csh" =>
      Some(
        pick_shell(
          "csh",
          Csh,
          [path_join(home, ".cshrc"), path_join(home, ".login")],
          exists,
        ),
      )
    "tcsh" =>
      Some(
        pick_shell(
          "tcsh",
          Csh,
          [
            path_join(home, ".tcshrc"),
            path_join(home, ".cshrc"),
            path_join(home, ".login"),
          ],
          exists,
        ),
      )
    "nu" =>
      Some(
        pick_shell(
          "nu",
          Nu,
          [
            path_join(xdg, "nushell/config.nu"),
            path_join(xdg, "nushell/env.nu"),
          ],
          exists,
        ),
      )
    "pwsh" | "powershell" | "pwsh.exe" | "powershell.exe" =>
      Some(
        pick_shell(
          "pwsh",
          PowerShell,
          [
            path_join(xdg, "powershell/Microsoft.PowerShell_profile.ps1"),
            path_join(
              home, "Documents/PowerShell/Microsoft.PowerShell_profile.ps1",
            ),
            path_join(
              home, "Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1",
            ),
          ],
          exists,
        ),
      )
    _ => None
  }
}

///|
/// Whether `rc` is already represented in `shells`.
fn has_rc(shells : Array[Shell], rc : String) -> Bool {
  for entry in shells {
    if entry.rc == rc {
      return true
    }
  }
  false
}

///|
/// Detect the startup files shrc should manage.
///
/// A file is managed when it already exists, so every shell the user has
/// configured is covered. The login shell's startup file is always included,
/// creating it when the shell has never been configured, and `~/.profile` is
/// the portable fallback when nothing else is found. `exists` is injected so
/// the decision is testable.
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
  let out = []
  for candidate in candidate_shells(home, xdg, zdotdir) {
    if exists(candidate.rc) && !has_rc(out, candidate.rc) {
      out.push(candidate)
    }
  }
  match login_primary(login, home, xdg, zdotdir, exists) {
    Some(primary) => if !has_rc(out, primary.rc) { out.push(primary) }
    None => ()
  }
  if out.length() == 0 {
    out.push(shell("profile", Posix, path_join(home, ".profile")))
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
/// Every startup file shrc knows about, existing or not. Used to describe the
/// full surface shrc can manage.
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
        "csh" | "tcsh" => Csh
        "nu" => Nu
        "pwsh" | "powershell" | "pwsh.exe" | "powershell.exe" => PowerShell
        _ => Posix
      }
    None => Posix
  }
}

///|
/// The family of the shell shrc is running under. `$SHELL` is authoritative
/// where it is set (Unix, Git Bash); otherwise `PSModulePath` identifies
/// PowerShell, and anything else is treated as POSIX.
pub fn current_eval_family() -> ShellFamily {
  match @env.get_env_var("SHELL") {
    Some(s) => eval_family(Some(s))
    None =>
      if @env.get_env_var("PSModulePath") is Some(_) {
        PowerShell
      } else {
        Posix
      }
  }
}
