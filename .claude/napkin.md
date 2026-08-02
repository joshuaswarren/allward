# Napkin

## Corrections
| Date | Source | What Went Wrong | What To Do Instead |
|------|--------|-----------------|-------------------|
| 2026-08-02 | self | A hashline edit briefly duplicated a declaration because the replacement range stopped before a trailing constructor call. | Re-read the exact edited range before the next hunk and include the structural boundary only once. |
| 2026-08-02 | self | Replacing a stale comment range also removed the `isSwitchable` property declaration at the range boundary. | Include adjacent declarations in the fresh read and verify that the replacement preserves every structural member. |
| 2026-08-02 | self | A narrow test hunk replaced an assertion at the edge and duplicated the neighboring assertion. | Treat test assertions as structural lines too; reread the full test method after each hunk. |
| 2026-08-02 | self | Deleted an unused `import struct` by line number without re-reading, and removed `from dataclasses import ...` instead. Third edit of this exact shape; the two notes above did not prevent it. | Never trust a remembered line number for a one-line CUT. Re-read the exact line first and confirm its text, every time, even for a one-line deletion. |
| 2026-08-02 | self | Wrote three dependency paths into MAS-PLAN.md from what the receipt "would" report, then found the real output listed different ones. | Terminal truncation is not the file. Extract the untruncated text before quoting tool output in a doc. |

## Patterns That Work
- Room herdr settings must update the active Room by ID, not the first Room with an adapter.
- A typed herdr host also needs a HostConfiguration because Room.connectedToHerdr claims the host alias and configuration validation requires it to be configured.
- A negative compile fixture must assert WHY it failed. Requiring the diagnostic
  to report a forbidden name as unresolved caught two fixtures that were failing
  on a missing `CAllwardPTY` modulemap and proving nothing.
- A shortest dependency path can hide the edge you care about. `AllwardSSH ->
  AllwardLocalPTY` never appears in one, because `AllwardControl` names
  `AllwardLocalPTY` directly. Report every declaring target, not just a path.
- Importing a Swift module that wraps a C target needs that target's generated
  modulemap: `-Xcc -fmodule-map-file=<bin>/<name>.build/module.modulemap`.

## Domain Notes
- Allward is built on macOS; this Linux checkout is source-only. Build and test
  through `scripts/sync-to-mac.sh` and run Swift on the build host, never here.
  (An earlier note said Swift was "prohibited" - that was one subagent's
  instruction while the orchestrator owned the shared build dir, not a repo rule.)
