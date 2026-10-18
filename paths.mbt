///|
/// Filesystem path helpers and the shrc directory layout.
///
/// shrc keeps its own tiny path layer rather than pulling in a platform path
/// library: every file it manages is a POSIX-style dotfile path.

///|
/// Return the directory part of `path` (everything before the last `/`).
/// Returns `"."` when there is no separator.
pub fn path_dirname(path : String) -> String {
  let view = path.view()
  match view.rev_find("/") {
    Some(index) =>
      if index == 0 {
        "/"
      } else {
        view.view(start_offset=0, end_offset=index).to_owned()
      }
    None => "."
  }
}

///|
/// Return the final component of `path`.
pub fn path_basename(path : String) -> String {
  let view = path.view()
  match view.rev_find("/") {
    Some(index) =>
      view.view(start_offset=index + 1, end_offset=view.length()).to_owned()
    None => path
  }
}

///|
/// Join two path segments with a single `/`.
pub fn path_join(left : String, right : String) -> String {
  if left.length() == 0 {
    return right
  }
  if right.length() == 0 {
    return left
  }
  if left.view().has_suffix("/") {
    "\{left}\{right}"
  } else {
    "\{left}/\{right}"
  }
}

///|
/// The user's home directory. On Windows `HOME` is often unset, so fall back
/// to `USERPROFILE` and then to `HOMEDRIVE`+`HOMEPATH`; `/` is the last resort
/// so the pure path helpers stay total.
pub fn home_dir() -> String {
  match @env.get_env_var("HOME") {
    Some(h) if h.length() > 0 => h
    _ =>
      match @env.get_env_var("USERPROFILE") {
        Some(h) if h.length() > 0 => h
        _ =>
          match (@env.get_env_var("HOMEDRIVE"), @env.get_env_var("HOMEPATH")) {
            (Some(drive), Some(path)) if drive.length() > 0 && path.length() > 0 =>
              drive + path
            _ => "/"
          }
      }
  }
}

///|
/// `$XDG_CONFIG_HOME`, or `$HOME/.config` when it is unset.
pub fn xdg_config_home() -> String {
  match @env.get_env_var("XDG_CONFIG_HOME") {
    Some(p) if p.length() > 0 => p
    _ => path_join(home_dir(), ".config")
  }
}

///|
/// The directory zsh keeps its dotfiles in (`$ZDOTDIR`), or `$HOME`.
pub fn zdotdir() -> String {
  match @env.get_env_var("ZDOTDIR") {
    Some(p) if p.length() > 0 => p
    _ => home_dir()
  }
}

///|
/// The shrc home directory. Honours `SHRC_HOME`, otherwise `$HOME/.shrc`.
pub fn shrc_home() -> String {
  match @env.get_env_var("SHRC_HOME") {
    Some(p) if p.length() > 0 => p
    _ => path_join(home_dir(), ".shrc")
  }
}

///|
/// Path of the manifest that records every managed entry.
pub fn manifest_path() -> String {
  path_join(shrc_home(), "entries")
}

///|
/// Create `dir` and any missing parents. `@fs.create_dir` only makes the last
/// component, and `SHRC_HOME` is user-supplied, so walk the path.
pub fn ensure_dir(dir : String) -> Result[Unit, String] {
  if dir.length() == 0 || dir == "/" || dir == "." || @fs.path_exists(dir) {
    return Ok(())
  }
  let parent = path_dirname(dir)
  if parent != dir && parent.length() > 0 {
    match ensure_dir(parent) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
  }
  @fs.create_dir(dir) catch {
    _ =>
      // A concurrent creator, or a directory that appeared meanwhile, is fine.
      if !@fs.path_exists(dir) {
        return Err("cannot create directory '\{dir}'")
      }
  }
  Ok(())
}
