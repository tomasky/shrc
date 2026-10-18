///|
/// shrc executable entry point. All real work lives in `kupas/shrc`.

///|
fn main {
  // Self-configure on every run, but cheaply: shell integration is only
  // written where its marker is missing, and the one-time import only happens
  // when there is no manifest yet. This makes `npm install -g` and other
  // install paths self-configuring without an install script.
  @lib.install_shell_integration()
  if !@fs.path_exists(@lib.manifest_path()) {
    let _ = @lib.dispatch(["init", "-q"])
  }
  let argv = @env.args()
  let args = if argv.length() > 0 {
    argv.exact_view(start=1).to_owned()
  } else {
    []
  }
  let result = @lib.dispatch(args)
  if result.out.length() > 0 {
    println(result.out)
  }
  if result.err.length() > 0 {
    eprintln(result.err)
  }
  @sys.exit(result.code)
}
