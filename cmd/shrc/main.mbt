///|
/// shrc executable entry point. All real work lives in `kupas/shrc`.

///|
fn main {
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
