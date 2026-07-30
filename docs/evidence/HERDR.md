# herdr 0.7.5 evidence

Sources: official herdr documentation and reproducible herdr 0.7.5 CLI/schema inspection, checked 2026-07-29.

## Verified capability matrix

| Surface | Capability | Boundary |
|---|---|---|
| Contract | Installed `herdr 0.7.5`; protocol 17; JSON Schema 2020-12, schema version 1. | Version/schema identity is settled. |
| Full client | `herdr`, `session attach`, and `--remote` attach the full persistent UI; remote is documented as a native thin client. | Hidden-PTY byte stream, mouse, resize, paste, clipboard, and bridge behavior need a disposable probe. |
| Agent attach | `herdr agent attach <target>` attaches one live agent; `--takeover` replaces the current direct client. | CLI-only, agent-only, exclusive input. Prior probe shows a compositor/grid-diff stream, not raw inner PTY bytes. |
| Pane read | `pane.read`/`agent.read` return rendered snapshots (`text` or `ansi`) with revision and truncation metadata. | No raw PTY output stream; OSC 133 preservation in `ansi` is unpromised and unverified. |
| Pane input | `pane.send_text`, `pane.send_keys`, atomic `pane.send_input`; `agent.prompt` combines submission with wait. | Logical input API, not raw terminal bytes. |
| Subscriptions | `events.subscribe` covers lifecycle plus scoped `pane.output_matched`, `pane.agent_status_changed`, and `pane.scroll_changed`. | Generic `pane_output_changed` is not subscribable; arbitrary custom events and publish methods are absent. |
| Workspace | `session.snapshot` bootstraps workspaces, tabs, panes, layouts, focused IDs, and agents. | Point-in-time; clients resnapshot after reconnect/staleness. |
| Agent state | Facade exposes list/get/read/explain/focus/start/prompt/wait and status/session metadata. | No structured todo resource or todo event. |
| Integrations | Built-in install targets include omp, Claude, Codex, and others. | No structured todo resource or todo event is evidenced. |
| Plugins | Executable argv workflow packages may declare actions/events/panes and call the fixed CLI/socket API. | Cannot add raw socket methods or raw PTY taps; long-lived work needs a separately supervised process. |

## Rendering-path evidence

1. Full client under an Allward-owned PTY preserves herdr's whole workspace
   compositor and interaction model. Embedding behavior is not yet probed.
2. Per-agent attach yields one interactive agent terminal but remains a herdr
   compositor stream and cannot display shell panes.
3. `pane.read` supports every pane and native control-plane access, but it is a
   rendered snapshot, not a live byte stream. Freshness cannot rely on a
   generic output-change subscription in protocol 17.

Receipts:

- `herdr --help`
- `herdr agent attach --help`
- `herdr api schema --json`
- <https://herdr.dev/docs/socket-api/>
- <https://herdr.dev/docs/agents/>
- <https://herdr.dev/docs/plugins/>

## Unverified boundaries

1. Full-client PTY behavior: shell and agent content, keyboard, mouse, paste,
   cursor, selection, alternate screen, resize, reconnect, focus routing.
2. Agent-attach bidirectional interaction and reconnect behavior.
3. 0.7.5 revision monotonicity and actual output-change events.
4. `pane.read format:"ansi"` and direct-attach OSC 133 preservation.
