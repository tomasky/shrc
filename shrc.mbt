///|
/// shrc — manage environment variables and aliases across every shell
/// (bash, zsh, fish, ...).
///
/// The library exposes the pieces the `shrc` command builds on:
///
/// * `Entry` / `EntryKind` — what is managed.
/// * `render_entry` / `sync_block` — how it becomes shell syntax.
/// * `detect_shells` — which startup files are managed.
/// * `load_entries` / `save_entries` / `apply_to_shells` — the store.
/// * `dispatch` — the command-line entry point.
///
/// Blackbox tests exercise this surface through `@shrc`; the module's own
/// tests live in `shrc_test.mbt` and `shrc_wbtest.mbt`.
