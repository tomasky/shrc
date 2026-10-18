///|
/// Whitebox tests for shrc internals. The public behaviour is covered by
/// `shrc_test.mbt`; what is interesting here is the small parsing and
/// rendering helpers those functions are built from.

///|
test "split_lines drops the trailing empty line" {
  assert_eq(split_lines(""), [])
  assert_eq(split_lines("a"), ["a"])
  assert_eq(split_lines("a\nb"), ["a", "b"])
  assert_eq(split_lines("a\nb\n"), ["a", "b"])
}

///|
test "find_line finds the first match" {
  assert_eq(find_line(["a", "b", "a"], "a"), Some(0))
  assert_eq(find_line(["a", "b"], "b"), Some(1))
  assert_eq(find_line(["a"], "z"), None)
}

///|
test "block_lines brackets the entries with markers" {
  let lines = block_lines(Posix, [Entry::new(Env, "A", "1")])
  assert_eq(lines, [block_begin, "export A='1'", block_end])
}

///|
test "kind_matches treats None as both kinds" {
  assert_true(kind_matches(None, Env))
  assert_true(kind_matches(None, Alias))
  assert_true(kind_matches(Some(Env), Env))
  assert_false(kind_matches(Some(Env), Alias))
}

///|
test "split_eq splits on the first equals sign" {
  assert_eq(split_eq("A=1"), Some(("A", "1")))
  assert_eq(split_eq("A=b=c"), Some(("A", "b=c")))
  assert_eq(split_eq("=x"), Some(("", "x")))
  assert_eq(split_eq("A"), None)
}

///|
test "parse_common separates flags from operands" {
  let (flags, positional) = parse_common(["-a", "-q", "X", "Y"])
  assert_true(kind_matches(flags.kind, Alias))
  assert_true(flags.quiet)
  assert_eq(positional, ["X", "Y"])
  let (plain, operands) = parse_common(["X"])
  assert_true(plain.kind is None)
  assert_false(plain.quiet)
  assert_eq(operands, ["X"])
}

///|
test "prefer_existing picks the file that exists" {
  let only_login = fn(path) { path == "/l" }
  let only_primary = fn(path) { path == "/p" }
  let neither = fn(_path) { false }
  assert_eq(prefer_existing("/p", "/l", only_login), "/l")
  assert_eq(prefer_existing("/p", "/l", only_primary), "/p")
  assert_eq(prefer_existing("/p", "/l", neither), "/p")
}

///|
test "parse_kind accepts the manifest spellings" {
  assert_eq(kind_label(Env), "env")
  assert_eq(kind_label(Alias), "alias")
  assert_true(kind_matches(parse_kind("env"), Env))
  assert_true(kind_matches(parse_kind("alias"), Alias))
  assert_true(parse_kind("nonsense") is None)
}

///|
/// The one test that touches the environment: it points `HOME` and `SHRC_HOME`
/// at a scratch directory, drives the whole set/ls/rm cycle and restores the
/// environment afterwards. Every other test is pure, so a failure here cannot
/// leak into them.
test "dispatch drives set, ls, rm and all" {
  let saved_home = @env.get_env_var("HOME")
  let saved_shrc = @env.get_env_var("SHRC_HOME")
  let saved_shell = @env.get_env_var("SHELL")
  let home = "/tmp/shrc-moonbit-test-home"
  let shrc_home = home + "/.shrc"
  let profile = home + "/.profile"
  let _ = ensure_dir(home)
  let _ = ensure_dir(shrc_home)
  @fs.write_string_to_file(profile, "") catch {
    _ => fail("cannot prepare the scratch home")
  }
  @fs.write_string_to_file(manifest_path(), "") catch {
    _ => ()
  }
  @env.set_env_var("HOME", home)
  @env.set_env_var("SHRC_HOME", shrc_home)
  @env.set_env_var("SHELL", "/bin/bash")
  // set prints the statement to eval
  let set = dispatch(["set", "FOO", "bar"])
  assert_eq(set.code, 0)
  assert_eq(set.out, "export FOO='bar'")
  // and writes the block into the detected startup file
  let written = @fs.read_file_to_string(profile) catch { _ => "" }
  assert_true(written.contains("# >>> shrc >>>"))
  assert_true(written.contains("export FOO='bar'"))
  // ls reports it
  let listed = dispatch(["ls", "FOO"])
  assert_eq(listed.code, 0)
  assert_eq(listed.out, "env\tFOO=bar")
  // all shows the manifest and the file
  let all = dispatch(["all"])
  assert_eq(all.code, 0)
  assert_true(all.out.contains("FOO=bar"))
  assert_true(all.out.contains(profile))
  // rm removes it and prints the statement to eval
  let removed = dispatch(["rm", "FOO"])
  assert_eq(removed.code, 0)
  assert_eq(removed.out, "unset FOO")
  let after = @fs.read_file_to_string(profile) catch { _ => "" }
  assert_false(after.contains("FOO"))
  // a second ls no longer finds it
  let gone = dispatch(["ls", "FOO"])
  assert_eq(gone.code, 1)
  // restore the environment
  match saved_home {
    Some(v) => @env.set_env_var("HOME", v)
    None => @env.unset_env_var("HOME")
  }
  match saved_shrc {
    Some(v) => @env.set_env_var("SHRC_HOME", v)
    None => @env.unset_env_var("SHRC_HOME")
  }
  match saved_shell {
    Some(v) => @env.set_env_var("SHELL", v)
    None => @env.unset_env_var("SHELL")
  }
}
