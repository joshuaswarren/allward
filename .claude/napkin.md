# Napkin

## Corrections
| Date | Source | What Went Wrong | What To Do Instead |
|------|--------|-----------------|-------------------|
| 2026-08-02 | self | A hashline edit briefly duplicated a declaration because the replacement range stopped before a trailing constructor call. | Re-read the exact edited range before the next hunk and include the structural boundary only once. |
| 2026-08-02 | self | Replacing a stale comment range also removed the `isSwitchable` property declaration at the range boundary. | Include adjacent declarations in the fresh read and verify that the replacement preserves every structural member. |
| 2026-08-02 | self | A narrow test hunk replaced an assertion at the edge and duplicated the neighboring assertion. | Treat test assertions as structural lines too; reread the full test method after each hunk. |
| 2026-08-02 | self | Deleted an unused `import struct` by line number without re-reading, and removed `from dataclasses import ...` instead. Third edit of this exact shape; the two notes above did not prevent it. | Never trust a remembered line number for a one-line CUT. Re-read the exact line first and confirm its text, every time, even for a one-line deletion. |
| 2026-08-02 | self | Wrote three dependency paths into MAS-PLAN.md from what the receipt "would" report, then found the real output listed different ones. | Terminal truncation is not the file. Extract the untruncated text before quoting tool output in a doc. |
| 2026-08-02 | Joshua | Argued against installing `cbindgen` on two bad grounds: called it a "build dependency" when it is a dev tool that generates a committed artifact, and called the SSH C ABI "small" without enumerating it. Installing it took 16 seconds. | Price the objection before making it. A tool that generates a reviewable, committed artifact is not a dependency of the build that reads it. And do not call a surface small without listing it. |
| 2026-08-02 | self | Suppressed cbindgen's stderr with `2> /dev/null` in a new script, and a real failure became a silent no-op that took three runs to diagnose. Same shape as hiding a check's own failure. | Never redirect a tool's stderr to /dev/null in a script whose job is to detect a problem. Let it print. |
| 2026-08-02 | self | Assumed russh's external signer returns just the signature. It returns the buffer it was handed with the signature appended and wrapped in one more SSH string; the server rejected everything until then. | For a foreign callback contract, read the library's own reference implementation of that trait before writing yours. `AgentClient` was right there. |

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
- Dead dependency edges hide in Package.swift. `AllwardControl` declared
  `AllwardLocalPTY` and `AllwardSSH`, and `AllwardChrome` declared
  `AllwardLocalPublisherEndpoint`, all unused. Deleting three lines took receipt
  findings from 23 to 14 before any real work. Check actual imports before
  planning a refactor around a dependency.
- A receipt with a persistent scratch directory reads stale `.swiftmodule` files
  and reports violations that no longer exist. Rebuild it from empty.
- The sandbox cannot read `~/.ssh`, so a MAS session needs its key inside the
  container or in the Keychain. A key path from config fails silently otherwise.
- `sync-to-mac.sh` overwrites the generated C header on the build host with this
  checkout's copy. Regenerate on the Mac, copy it back, then sync.

## Domain Notes
- Allward is built on macOS; this Linux checkout is source-only. Build and test
  through `scripts/sync-to-mac.sh` and run Swift on the build host, never here.
  (An earlier note said Swift was "prohibited" - that was one subagent's
  instruction while the orchestrator owned the shared build dir, not a repo rule.)
