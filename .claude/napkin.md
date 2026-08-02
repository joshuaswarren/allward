# Napkin

## Corrections
| Date | Source | What Went Wrong | What To Do Instead |
|------|--------|-----------------|-------------------|
| 2026-08-02 | self | A hashline edit briefly duplicated a declaration because the replacement range stopped before a trailing constructor call. | Re-read the exact edited range before the next hunk and include the structural boundary only once. |
| 2026-08-02 | self | Replacing a stale comment range also removed the `isSwitchable` property declaration at the range boundary. | Include adjacent declarations in the fresh read and verify that the replacement preserves every structural member. |
| 2026-08-02 | self | A narrow test hunk replaced an assertion at the edge and duplicated the neighboring assertion. | Treat test assertions as structural lines too; reread the full test method after each hunk. |

## Patterns That Work
- Room herdr settings must update the active Room by ID, not the first Room with an adapter.
- A typed herdr host also needs a HostConfiguration because Room.connectedToHerdr claims the host alias and configuration validation requires it to be configured.

## Domain Notes
- Allward is built on macOS; this Linux checkout is source-only. Build and test
  through `scripts/sync-to-mac.sh` and run Swift on the build host, never here.
  (An earlier note said Swift was "prohibited" - that was one subagent's
  instruction while the orchestrator owned the shared build dir, not a repo rule.)
