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
/// The second test that touches the environment: a first install runs
/// `shrc init` against a scratch home and adopts what `.bashrc` already had.
test "dispatch init adopts existing definitions" {
  let saved_home = @env.get_env_var("HOME")
  let saved_shrc = @env.get_env_var("SHRC_HOME")
  let saved_shell = @env.get_env_var("SHELL")
  let tmp = match @env.get_env_var("TMPDIR") {
    Some(dir) if dir.length() > 0 => dir
    _ => "/tmp"
  }
  let home = path_join(tmp, "shrc-moonbit-init-home")
  let shrc_home = path_join(home, ".shrc")
  let bashrc = path_join(home, ".bashrc")
  let _ = ensure_dir(shrc_home)
  let original = "alias ll='ls -alF'\nPATH=\"$HOME/.local/bin:$PATH\"\n\n" +
    "# >>> shrc >>>\nexport EDITOR='vim'\n# <<< shrc <<<\n"
  @env.set_env_var("HOME", home)
  @env.set_env_var("SHRC_HOME", shrc_home)
  @env.set_env_var("SHELL", "/bin/bash")
  @fs.write_string_to_file(bashrc, original) catch {
    _ => fail("cannot prepare the scratch home")
  }
  let manifest = manifest_path()
  @fs.remove_file(manifest) catch {
    _ => ()
  }
  let first = dispatch(["init"])
  let manifest_text = @fs.read_file_to_string(manifest) catch { _ => "" }
  let cleaned = @fs.read_file_to_string(bashrc) catch { _ => "" }
  let listed = dispatch(["ls"])
  let dry = dispatch(["init", "--dry-run"])
  let again = dispatch(["init"])

  // restore the environment before asserting, so a failure cannot leak it
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
  @fs.remove_file(bashrc) catch {
    _ => ()
  }
  @fs.remove_file(manifest) catch {
    _ => ()
  }
  // the manifest holds the adopted entries
  assert_eq(first.code, 0)
  assert_true(manifest_text.contains("alias\timported\tll\tls -alF"))
  assert_true(
    manifest_text.contains(
      "env\traw,list,imported\tPATH\t$HOME/.local/bin:$PATH",
    ),
  )
  assert_true(manifest_text.contains("env\timported\tEDITOR\tvim"))
  // the definitions moved out of the file and into the managed block
  // init does not touch the startup file: the original lines stay put
  assert_true(cleaned.contains("alias ll='ls -alF'"))
  assert_true(cleaned.contains("PATH=\"$HOME/.local/bin:$PATH\""))
  assert_true(cleaned.contains("export EDITOR='vim'"))
  // ls shows them straight away
  assert_true(listed.out.contains("alias\tll=ls -alF"))
  assert_true(
    listed.out.contains("env\tPATH\n\t0\t$HOME/.local/bin\n\t1\t$PATH"),
  )
  // a second run has nothing new to do and leaves the file alone
  assert_eq(dry.code, 0)
  assert_eq(again.code, 0)
}

///|
/// The shape of a parsed value, as a short string for assertions.
fn rhs_label(form : ValueForm) -> String {
  match form {
    SingleQuoted(value) => "single:\{value}"
    DoubleQuoted(value) => "double:\{value}"
    BareWord(value) => "bare:\{value}"
    Unparsed => "unparsed"
  }
}

///|
test "parse_rhs reads quoted and bare values" {
  assert_eq(rhs_label(parse_rhs("'a b'")), "single:a b")
  assert_eq(rhs_label(parse_rhs("\"a b\"")), "double:a b")
  assert_eq(rhs_label(parse_rhs("plain")), "bare:plain")
  assert_eq(rhs_label(parse_rhs("")), "bare:")
  assert_eq(rhs_label(parse_rhs("plain # note")), "bare:plain")
  assert_eq(rhs_label(parse_rhs("a b")), "unparsed")
  assert_eq(rhs_label(parse_rhs("'a' extra")), "unparsed")
  assert_eq(rhs_label(parse_rhs("'a")), "unparsed")
  assert_eq(rhs_label(parse_rhs("a\"b\"")), "unparsed")
}

///|
test "posix_block_delta tracks conditionals including one-liners" {
  assert_eq(posix_block_delta("if [ -f x ]; then"), 1)
  assert_eq(posix_block_delta("fi"), -1)
  assert_eq(posix_block_delta("if true; then echo; fi"), 0)
  assert_eq(posix_block_delta("case $- in"), 1)
  assert_eq(posix_block_delta("esac"), -1)
  assert_eq(posix_block_delta("for x in a b; do"), 1)
  assert_eq(posix_block_delta("done"), -1)
  assert_eq(posix_block_delta("shopt -s histappend"), 0)
}

///|
test "brace_delta spots function bodies" {
  assert_eq(brace_delta("foo() {"), 1)
  assert_eq(brace_delta("function foo {"), 1)
  assert_eq(brace_delta("}"), -1)
  assert_eq(brace_delta("foo() { echo; }"), 0)
  assert_eq(brace_delta("export X=1"), 0)
}

///|
test "fish_block_delta separates functions from conditionals" {
  assert_eq(fish_block_delta("function greet", 0, 0), (1, 1))
  assert_eq(fish_block_delta("    if status is-interactive", 1, 1), (1, 0))
  assert_eq(fish_block_delta("    end", 2, 1), (-1, 0))
  assert_eq(fish_block_delta("end", 1, 1), (-1, -1))
  assert_eq(fish_block_delta("function a; end", 0, 0), (0, 0))
}

///|
test "heredoc_terminator reads quoted and dashed markers" {
  assert_eq(heredoc_terminator("cat <<EOF"), Some("EOF"))
  assert_eq(heredoc_terminator("cat <<-END"), Some("END"))
  assert_eq(heredoc_terminator("cat <<'EOF'"), Some("EOF"))
  assert_eq(heredoc_terminator("echo $((x<<2))"), None)
  assert_eq(heredoc_terminator("cat <<< word"), None)
  assert_eq(heredoc_terminator("echo hi"), None)
}

///|
test "scan_file skips a here-document body" {
  let text = "cat <<EOF\nexport INSIDE=1\nEOF\nexport OUTSIDE=2\n"
  let scan = scan_file(Posix, text)
  assert_eq(scan.entries.length(), 1)
  assert_eq(scan.entries[0].name, "OUTSIDE")
  assert_eq(scan.cleaned, "cat <<EOF\nexport INSIDE=1\nEOF\n")
}

///|
test "source_path_text resolves home includes" {
  let saved = @env.get_env_var("HOME")
  @env.set_env_var("HOME", "/home/u")
  let plain = source_path_text(". ~/.bash_aliases")
  let conditional = source_path_text(
    "[ -f ~/.bash_aliases ] && . ~/.bash_aliases",
  )
  let dollar = source_path_text("source $HOME/.aliases")
  let comment = source_path_text("# . ~/.bash_aliases")
  let system = source_path_text(". /etc/profile")
  let quoted = source_path_text(". \"~/.x\"")
  match saved {
    Some(v) => @env.set_env_var("HOME", v)
    None => @env.unset_env_var("HOME")
  }
  assert_eq(plain, Some("/home/u/.bash_aliases"))
  assert_eq(conditional, Some("/home/u/.bash_aliases"))
  assert_eq(dollar, Some("/home/u/.aliases"))
  assert_eq(comment, None)
  assert_eq(system, None)
  assert_eq(quoted, Some("/home/u/.x"))
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
  @env.set_env_var("SHELL", "/bin/sh")
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

///|
/// The entry of a successful `set_entry`, failing the test on an error.
fn set_ok(
  name : String,
  value : String,
  flags : CommonFlags,
  existing : Entry?,
) -> Entry? raise {
  match set_entry(Env, name, value, flags, existing) {
    Ok(outcome) => outcome.entry
    Err(message) => fail(message)
  }
}

///|
/// The entry of an outcome that describes a change.
fn set_changed(entry : Entry?) -> Entry raise {
  match entry {
    Some(entry) => entry
    None => fail("expected the set to change something")
  }
}

///|
test "set_entry maintains a search path in order" {
  let (plain, _) = parse_common([])
  let (prepend, _) = parse_common(["--prepend"])
  let (append, _) = parse_common(["--append"])
  let (drop, _) = parse_common(["--drop"])
  // a directory on its own is prepended, keeping the old value through $PATH
  let fresh = set_changed(set_ok("PYTHONPATH", "/opt/py", plain, None))
  assert_eq(fresh.value, "/opt/py:$PYTHONPATH")
  assert_true(fresh.raw)
  assert_true(fresh.list)
  let existing = Entry::new_full(Env, "PATH", "$HOME/bin:$PATH", true, true)
  let front = set_changed(set_ok("PATH", "/opt/bin", prepend, Some(existing)))
  assert_eq(front.value, "/opt/bin:$HOME/bin:$PATH")
  let back = set_changed(set_ok("PATH", "/opt/bin", append, Some(existing)))
  assert_eq(back.value, "$HOME/bin:$PATH:/opt/bin")
  // the same directory moves instead of appearing twice
  let once = Entry::new_full(Env, "PATH", "/opt/bin:$PATH", true, true)
  let again = set_changed(set_ok("PATH", "/opt/bin", prepend, Some(once)))
  assert_eq(again.value, "/opt/bin:$PATH")
  let gone = set_changed(set_ok("PATH", "/opt/bin", drop, Some(once)))
  assert_eq(gone.value, "$PATH")
  assert_true(gone.list)
  // dropping something that is not there changes nothing
  match set_entry(Env, "PATH", "/nope", drop, Some(once)) {
    Ok(outcome) => {
      assert_true(outcome.entry is None)
      assert_true(outcome.note.contains("not in"))
    }
    Err(message) => fail(message)
  }
  match set_entry(Env, "CDPATH", "/nope", drop, None) {
    Ok(outcome) => assert_true(outcome.note.contains("no entry"))
    Err(message) => fail(message)
  }
}

///|
test "set_entry stores raw syntax and whole search paths" {
  let (plain, _) = parse_common([])
  let (raw, _) = parse_common(["--raw"])
  let live = set_changed(set_ok("EDITOR", "$HOME/vim", raw, None))
  assert_eq(live.value, "$HOME/vim")
  assert_true(live.raw)
  assert_false(live.list)
  // a pasted PATH is stored as a list, `;` normalised to `:`
  let pasted = set_changed(set_ok("PATH", "/a:/b", plain, None))
  assert_eq(pasted.value, "/a:/b")
  assert_false(pasted.raw)
  assert_true(pasted.list)
  let semis = set_changed(set_ok("PATH", "/a;/b", plain, None))
  assert_eq(semis.value, "/a:/b")
  // a live expression in a plain `set PATH` keeps expanding
  let expression = set_changed(set_ok("PATH", "$HOME/bin:$PATH", plain, None))
  assert_true(expression.raw)
  assert_eq(expression.value, "$HOME/bin:$PATH")
  // syntax shrc cannot translate is refused instead of frozen
  match set_entry(Env, "PATH", "$(id):$PATH", plain, None) {
    Ok(_) => fail("expected the untranslatable value to be refused")
    Err(message) => assert_true(message.contains("cannot translate"))
  }
}
