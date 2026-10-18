///|
/// Blackbox tests for the public shrc API.
///
/// These pin the parts a user depends on: quoting that survives a shell, a
/// manifest that round-trips, a managed block that is rewritten rather than
/// duplicated, and shell detection that does not touch a shell the user does
/// not have.

///|
test "path helpers" {
  assert_eq(@shrc.path_join("/a", "b"), "/a/b")
  assert_eq(@shrc.path_join("/a/", "b"), "/a/b")
  assert_eq(@shrc.path_join("", "b"), "b")
  assert_eq(@shrc.path_join("/a", ""), "/a")
  assert_eq(@shrc.path_dirname("/a/b/c"), "/a/b")
  assert_eq(@shrc.path_dirname("/a"), "/")
  assert_eq(@shrc.path_dirname("a"), ".")
  assert_eq(@shrc.path_basename("/a/b/c"), "c")
  assert_eq(@shrc.path_basename("c"), "c")
}

///|
test "quote_posix protects spaces and single quotes" {
  assert_eq(@shrc.quote_posix("plain"), "'plain'")
  assert_eq(@shrc.quote_posix("a b"), "'a b'")
  assert_eq(@shrc.quote_posix("it's"), "'it'\\''s'")
  assert_eq(@shrc.quote_posix(""), "''")
}

///|
test "quote_fish protects backslashes and single quotes" {
  assert_eq(@shrc.quote_fish("plain"), "'plain'")
  assert_eq(@shrc.quote_fish("it's"), "'it\\'s'")
  assert_eq(@shrc.quote_fish("a\\b"), "'a\\\\b'")
}

///|
test "quote_csh escapes history expansion and single quotes" {
  assert_eq(@shrc.quote_csh("plain"), "'plain'")
  assert_eq(@shrc.quote_csh("a!b"), "'a\\!b'")
  assert_eq(@shrc.quote_csh("it's"), "'it'\\''s'")
  assert_eq(@shrc.quote_csh(""), "''")
}

///|
test "quote_nu escapes what nushell needs" {
  assert_eq(@shrc.quote_nu("plain"), "\"plain\"")
  assert_eq(@shrc.quote_nu("a\\b"), "\"a\\\\b\"")
  assert_eq(@shrc.quote_nu("a\"b"), "\"a\\\"b\"")
  assert_eq(@shrc.quote_nu("a\nb"), "\"a\\nb\"")
}

///|
test "quote_ps doubles single quotes" {
  assert_eq(@shrc.quote_ps("plain"), "'plain'")
  assert_eq(@shrc.quote_ps("it's"), "'it''s'")
}

///|
test "render_entry speaks each shell's syntax" {
  let env = @shrc.Entry::new(@shrc.Env, "FOO", "bar")
  let alias_entry = @shrc.Entry::new(@shrc.Alias, "ll", "ls -la")
  assert_eq(@shrc.render_entry(@shrc.Posix, env), "export FOO='bar'")
  assert_eq(@shrc.render_entry(@shrc.Fish, env), "set -gx FOO 'bar'")
  assert_eq(@shrc.render_entry(@shrc.Csh, env), "setenv FOO 'bar'")
  assert_eq(@shrc.render_entry(@shrc.Nu, env), "$env.FOO = \"bar\"")
  assert_eq(@shrc.render_entry(@shrc.PowerShell, env), "$env:FOO = 'bar'")
  assert_eq(@shrc.render_entry(@shrc.Posix, alias_entry), "alias ll='ls -la'")
  assert_eq(@shrc.render_entry(@shrc.Fish, alias_entry), "alias ll 'ls -la'")
  assert_eq(@shrc.render_entry(@shrc.Csh, alias_entry), "alias ll 'ls -la'")
}

///|
test "render_remove unsets and unaliases" {
  let env = @shrc.Entry::new(@shrc.Env, "FOO", "bar")
  let alias_entry = @shrc.Entry::new(@shrc.Alias, "ll", "ls -la")
  assert_eq(@shrc.render_remove(@shrc.Posix, env), "unset FOO")
  assert_eq(@shrc.render_remove(@shrc.Fish, env), "set -e FOO")
  assert_eq(@shrc.render_remove(@shrc.Csh, env), "unsetenv FOO")
  assert_true(@shrc.render_remove(@shrc.Nu, env).contains("hide-env FOO"))
  assert_true(
    @shrc.render_remove(@shrc.PowerShell, env).contains("Remove-Item Env:FOO"),
  )
  assert_true(
    @shrc.render_remove(@shrc.Posix, alias_entry).contains("unalias ll"),
  )
  assert_true(
    @shrc.render_remove(@shrc.Fish, alias_entry).contains("functions -e ll"),
  )
  assert_true(
    @shrc.render_remove(@shrc.PowerShell, alias_entry).contains(
      "Remove-Item Function:ll",
    ),
  )
}

///|
test "escape_field round-trips through unescape_field" {
  for value in ["", "plain", "a\tb", "a\nb", "a\\b", "a\rb", "mix\t\n\\end"] {
    assert_eq(@shrc.unescape_field(@shrc.escape_field(value)), value)
  }
}

///|
test "entry line round-trips" {
  let entry = @shrc.Entry::new(@shrc.Env, "FOO", "a\tb\nc")
  match @shrc.entry_of_line(@shrc.entry_to_line(entry)) {
    Some(parsed) => {
      assert_true(@shrc.kind_eq(parsed.kind, @shrc.Env))
      assert_eq(parsed.name, "FOO")
      assert_eq(parsed.value, "a\tb\nc")
    }
    None => fail("expected the line to parse")
  }
}

///|
test "entry_of_line rejects blanks, comments and garbage" {
  assert_true(@shrc.entry_of_line("") is None)
  assert_true(@shrc.entry_of_line("   ") is None)
  assert_true(@shrc.entry_of_line("# a comment") is None)
  assert_true(@shrc.entry_of_line("env\tONLY_TWO") is None)
  assert_true(@shrc.entry_of_line("nonsense\tA\t1") is None)
}

///|
test "manifest serializes and parses" {
  let entries = [
    @shrc.Entry::new(@shrc.Env, "A", "1"),
    @shrc.Entry::new(@shrc.Alias, "b", "x y"),
  ]
  let parsed = @shrc.parse_entries(@shrc.serialize_entries(entries))
  assert_eq(parsed.length(), 2)
  assert_eq(parsed[0].name, "A")
  assert_eq(parsed[0].value, "1")
  assert_eq(parsed[1].name, "b")
  assert_eq(parsed[1].value, "x y")
}

///|
test "upsert_entry replaces the same kind and name" {
  let base = [@shrc.Entry::new(@shrc.Env, "A", "1")]
  let replaced = @shrc.upsert_entry(base, @shrc.Entry::new(@shrc.Env, "A", "2"))
  assert_eq(replaced.length(), 1)
  assert_eq(replaced[0].value, "2")
  // An alias of the same name is a different entry.
  let added = @shrc.upsert_entry(base, @shrc.Entry::new(@shrc.Alias, "A", "x"))
  assert_eq(added.length(), 2)
}

///|
test "remove_by_name splits removed from remaining" {
  let entries = [
    @shrc.Entry::new(@shrc.Env, "A", "1"),
    @shrc.Entry::new(@shrc.Alias, "A", "x"),
    @shrc.Entry::new(@shrc.Env, "B", "2"),
  ]
  let (remaining, removed) = @shrc.remove_by_name(entries, "A")
  assert_eq(remaining.length(), 1)
  assert_eq(remaining[0].name, "B")
  assert_eq(removed.length(), 2)
}

///|
test "filter_entries matches exactly or by substring" {
  let entries = [
    @shrc.Entry::new(@shrc.Env, "EDITOR", "vim"),
    @shrc.Entry::new(@shrc.Env, "VISUAL", "vim"),
  ]
  assert_eq(@shrc.filter_entries(entries, "").length(), 2)
  assert_eq(@shrc.filter_entries(entries, "EDITOR").length(), 1)
  assert_eq(@shrc.filter_entries(entries, "VIS").length(), 1)
  assert_eq(@shrc.filter_entries(entries, "nope").length(), 0)
}

///|
test "sync_block appends a block to an empty file" {
  let block = @shrc.sync_block("", @shrc.Posix, [
    @shrc.Entry::new(@shrc.Env, "A", "1"),
  ])
  assert_eq(block, "# >>> shrc >>>\nexport A='1'\n# <<< shrc <<<\n")
}

///|
test "sync_block appends after existing content" {
  let block = @shrc.sync_block("echo hi\n", @shrc.Posix, [
    @shrc.Entry::new(@shrc.Env, "A", "1"),
  ])
  assert_eq(block, "echo hi\n\n# >>> shrc >>>\nexport A='1'\n# <<< shrc <<<\n")
}

///|
test "sync_block rewrites an existing block in place" {
  let once = @shrc.sync_block("", @shrc.Posix, [
    @shrc.Entry::new(@shrc.Env, "A", "1"),
  ])
  let twice = @shrc.sync_block(once, @shrc.Posix, [
    @shrc.Entry::new(@shrc.Env, "A", "2"),
  ])
  assert_eq(twice, "# >>> shrc >>>\nexport A='2'\n# <<< shrc <<<\n")
}

///|
test "sync_block keeps surrounding lines" {
  let text = "before\n# >>> shrc >>>\nexport A='1'\n# <<< shrc <<<\nafter\n"
  let updated = @shrc.sync_block(text, @shrc.Posix, [
    @shrc.Entry::new(@shrc.Env, "A", "2"),
  ])
  assert_eq(
    updated, "before\n# >>> shrc >>>\nexport A='2'\n# <<< shrc <<<\nafter\n",
  )
}

///|
test "sync_block removes the block when there are no entries" {
  let once = @shrc.sync_block("", @shrc.Posix, [
    @shrc.Entry::new(@shrc.Env, "A", "1"),
  ])
  assert_eq(@shrc.sync_block(once, @shrc.Posix, []), "")
  assert_eq(@shrc.sync_block("echo hi\n", @shrc.Posix, []), "echo hi\n")
}

///|
test "candidate_shells lays out every startup file" {
  let shells = @shrc.candidate_shells("/home/u", "/home/u/.config", "/home/u")
  assert_eq(shells.length(), 18)
  assert_eq(shells[0].name, "profile")
  assert_eq(shells[0].rc, "/home/u/.profile")
  assert_eq(shells[1].name, "bash")
  assert_eq(shells[1].rc, "/home/u/.bashrc")
  assert_eq(shells[4].name, "zsh")
  assert_eq(shells[4].rc, "/home/u/.zshrc")
  assert_eq(shells[9].name, "fish")
  assert_eq(shells[9].rc, "/home/u/.config/fish/config.fish")
  assert_true(shells[9].family is Fish)
  assert_true(shells[10].family is Csh)
  assert_eq(shells[13].name, "nu")
  assert_true(shells[13].family is Nu)
  assert_true(shells[15].family is PowerShell)
  // Every startup file is distinct, so one shell's block never shadows
  // another's.
  let seen = []
  for candidate in shells {
    assert_false(seen.contains(candidate.rc))
    seen.push(candidate.rc)
  }
}

///|
test "detect_shells follows the login shell and existing files" {
  let none = fn(_path) { false }
  let only_bashrc = fn(path) { path == "/home/u/.bashrc" }
  let bash = @shrc.detect_shells(
    "/home/u",
    "/home/u/.config",
    "/home/u",
    None,
    only_bashrc,
  )
  assert_eq(bash.length(), 1)
  assert_eq(bash[0].name, "bash")
  // A login fish with no files still gets a startup file.
  let fish = @shrc.detect_shells(
    "/home/u",
    "/home/u/.config",
    "/home/u",
    Some("/usr/bin/fish"),
    none,
  )
  assert_eq(fish.length(), 1)
  assert_eq(fish[0].name, "fish")
  // With nothing at all, the portable profile is the fallback.
  let fallback = @shrc.detect_shells(
    "/home/u",
    "/home/u/.config",
    "/home/u",
    None,
    none,
  )
  assert_eq(fallback.length(), 1)
  assert_eq(fallback[0].name, "profile")
}

///|
test "detect_shells covers every existing file without duplicates" {
  let all = fn(_path : String) { true }
  let shells = @shrc.detect_shells(
    "/home/u",
    "/home/u/.config",
    "/home/u",
    None,
    all,
  )
  assert_eq(shells.length(), 18)
  // A login shell already listed as an existing file is not added twice.
  let with_login = @shrc.detect_shells(
    "/home/u",
    "/home/u/.config",
    "/home/u",
    Some("/bin/bash"),
    all,
  )
  assert_eq(with_login.length(), 18)
}

///|
test "detect_shells prefers an existing login file" {
  let only_bash_profile = fn(path) { path == "/home/u/.bash_profile" }
  let shells = @shrc.detect_shells(
    "/home/u",
    "/home/u/.config",
    "/home/u",
    Some("/bin/bash"),
    only_bash_profile,
  )
  assert_eq(shells.length(), 1)
  assert_eq(shells[0].rc, "/home/u/.bash_profile")
}

///|
test "is_valid_env_name accepts POSIX identifiers and rejects code" {
  assert_true(@shrc.is_valid_env_name("FOO"))
  assert_true(@shrc.is_valid_env_name("_x1"))
  assert_true(@shrc.is_valid_env_name("a1_B"))
  assert_false(@shrc.is_valid_env_name(""))
  assert_false(@shrc.is_valid_env_name("1abc"))
  assert_false(@shrc.is_valid_env_name("a b"))
  assert_false(@shrc.is_valid_env_name("a=b"))
  assert_false(@shrc.is_valid_env_name("a-b"))
  assert_false(@shrc.is_valid_env_name("a.b"))
  assert_false(@shrc.is_valid_env_name("a;b"))
  assert_false(@shrc.is_valid_env_name("a$(id)"))
}

///|
test "is_valid_alias_name allows punctuation but not metacharacters" {
  assert_true(@shrc.is_valid_alias_name("ll"))
  assert_true(@shrc.is_valid_alias_name(".."))
  assert_true(@shrc.is_valid_alias_name("gs-1"))
  assert_false(@shrc.is_valid_alias_name(""))
  assert_false(@shrc.is_valid_alias_name("a b"))
  assert_false(@shrc.is_valid_alias_name("a=b"))
  assert_false(@shrc.is_valid_alias_name("a;b"))
  assert_false(@shrc.is_valid_alias_name("a|b"))
  assert_false(@shrc.is_valid_alias_name("a$(id)"))
}
