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
test "sync_block drops an opening marker that has no closing one" {
  let text = "before\n# >>> shrc >>>\nexport A='1'\nafter\n"
  let updated = sync_block(text, Posix, [Entry::new(Env, "B", "2")])
  assert_eq(
    updated, "before\nexport A='1'\nafter\n\n# >>> shrc >>>\nexport B='2'\n# <<< shrc <<<\n",
  )
  // The rewritten file carries exactly one complete block.
  let again = sync_block(updated, Posix, [Entry::new(Env, "B", "3")])
  assert_eq(
    again, "before\nexport A='1'\nafter\n\n# >>> shrc >>>\nexport B='3'\n# <<< shrc <<<\n",
  )
}

///|
test "sync_block drops a closing marker that has no opening one" {
  let text = "before\n# <<< shrc <<<\nafter\n"
  let updated = sync_block(text, Posix, [Entry::new(Env, "B", "2")])
  assert_eq(
    updated, "before\nafter\n\n# >>> shrc >>>\nexport B='2'\n# <<< shrc <<<\n",
  )
}

///|
test "sync_block treats a nested opening marker as the real block" {
  let text = "# >>> shrc >>>\nbefore\n# >>> shrc >>>\nexport B='1'\n# <<< shrc <<<\nafter\n"
  let updated = sync_block(text, Posix, [Entry::new(Env, "C", "3")])
  assert_eq(
    updated, "before\n# >>> shrc >>>\nexport C='3'\n# <<< shrc <<<\nafter\n",
  )
}

///|
test "sync_block collapses duplicate blocks into the first one" {
  let text = "# >>> shrc >>>\nexport A='1'\n# <<< shrc <<<\nbetween\n# >>> shrc >>>\nexport B='1'\n# <<< shrc <<<\n"
  let updated = sync_block(text, Posix, [Entry::new(Env, "C", "3")])
  assert_eq(updated, "# >>> shrc >>>\nexport C='3'\n# <<< shrc <<<\nbetween\n")
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
test "first_existing picks the first file that exists" {
  let only_second = fn(path) { path == "/l" }
  let only_first = fn(path) { path == "/p" }
  let neither = fn(_path : String) { false }
  assert_eq(first_existing(["/p", "/l"], only_second), "/l")
  assert_eq(first_existing(["/p", "/l"], only_first), "/p")
  // Nothing exists: the first path is the one to create.
  assert_eq(first_existing(["/p", "/l"], neither), "/p")
}

///|
test "pick_shell carries the preferred file and the family" {
  let only_login = fn(path) { path == "/l" }
  let picked = pick_shell("bash", Posix, ["/p", "/l"], only_login)
  assert_eq(picked.rc, "/l")
  assert_eq(picked.name, "bash")
  assert_true(picked.family is Posix)
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
/// environment before asserting. Every other test is pure, so a failure here
/// cannot leak into them.
test "dispatch drives set, ls, rm and all" {
  let saved_home = @env.get_env_var("HOME")
  let saved_shrc = @env.get_env_var("SHRC_HOME")
  let saved_shell = @env.get_env_var("SHELL")
  let tmp = match @env.get_env_var("TMPDIR") {
    Some(dir) if dir.length() > 0 => dir
    _ => "/tmp"
  }
  let home = path_join(tmp, "shrc-moonbit-test-home")
  let shrc_home = path_join(home, ".shrc")
  let profile = path_join(home, ".profile")
  let _ = ensure_dir(shrc_home)
  // Point the environment at the scratch home *before* touching the manifest,
  // or the writes would land in the real user's ~/.shrc.
  @env.set_env_var("HOME", home)
  @env.set_env_var("SHRC_HOME", shrc_home)
  @env.set_env_var("SHELL", "/bin/bash")
  let manifest = manifest_path()
  @fs.write_string_to_file(profile, "") catch {
    _ => fail("cannot prepare the scratch home")
  }
  @fs.write_string_to_file(manifest, "") catch {
    _ => fail("cannot prepare the scratch manifest")
  }
  // run the cycle, collecting results
  let set = dispatch(["set", "FOO", "bar"])
  let written = @fs.read_file_to_string(profile) catch { _ => "" }
  let listed = dispatch(["ls", "FOO"])
  let all = dispatch(["all"])
  let removed = dispatch(["rm", "FOO"])
  let after = @fs.read_file_to_string(profile) catch { _ => "" }
  let gone = dispatch(["ls", "FOO"])
  // restore the environment first, so a failed assertion cannot leak it
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
  // set prints the statement to eval, and writes the block into the detected
  // startup file
  assert_eq(set.code, 0)
  assert_eq(set.out, "export FOO='bar'")
  assert_true(written.contains("# >>> shrc >>>"))
  assert_true(written.contains("export FOO='bar'"))
  // ls reports it
  assert_eq(listed.code, 0)
  assert_eq(listed.out, "env\tFOO=bar")
  // all shows the manifest and the file
  assert_eq(all.code, 0)
  assert_true(all.out.contains("FOO=bar"))
  assert_true(all.out.contains(profile))
  // rm removes it, prints the statement to eval and leaves no trace
  assert_eq(removed.code, 0)
  assert_eq(removed.out, "unset FOO")
  assert_false(after.contains("FOO"))
  // a second ls no longer finds it
  assert_eq(gone.code, 1)
  // leave no scratch files behind
  @fs.remove_file(profile) catch {
    _ => ()
  }
  @fs.remove_file(path_join(home, ".bashrc")) catch {
    _ => ()
  }
  @fs.remove_file(manifest) catch {
    _ => ()
  }
}
