# Allward decisions

Status: accepted product and architecture decisions. The canonical behavior lives in `SPEC.md` and `DESIGN-LANGUAGE.md`.

## Settled (Round 1, 2026-07-29)

| # | Decision | Call |
|---|---|---|
| 1 | ICP | Public polish from day one; ICP = operator driving agents via herdr on multiple remote containers, wanting work/personal separation (per-context theming). Neurodivergent-friendly UX is a first-class design pillar. |
| 2 | Multiplexer scope | Never builds its own. herdr first; tmux adapter later → integration is an adapter layer. |
| 3 | v1 demo | Open app → live herdr sessions across containers → attach <1s → agent todo/state surfaces → dictate via STT. |
| 4 | License | Apache-2.0. |
| 5 | Targets | Dev ID (local PTY) + MAS (sandboxed, remote-only) built from day one; MAS *submission* deferred. |
| 6 | Governance | Open source, public repo from first commit, BDFL. |
| 8 | OS floor | macOS 26 only (Foundation Models, SpeechAnalyzer, modern Metal everywhere). |
| 9 | Stack | AppKit terminal surface + Metal grid + SwiftUI chrome/settings/panels. Swift 6. |
| 10 | Engine | From scratch, agent-ground, conformance CI (esctest/vttest) from week 1. infinitty/ghostty are design references, not code. |
| 11 | Design | Obsess from day one. Design-language work precedes and gates code. Text stack reserves a shaping stage: correct combining chars + color emoji v1; ligatures architecturally reserved. |
| 12 | Transports | SSH + herdr attach. No mosh (herdr server-side persistence covers it). |
| 13 | OSC 133 | Client-side AND server-side (herdr) from the start. Deep herdr integration is a signature, not a feature. |
| 14 | Agent protocol | Versioned, address-agnostic socket transport with a session dimension. The environment carries the endpoint; the protocol makes no fixed-path assumption. |
| 15 | Intelligence | Foundation Models on-device default; BYO endpoint opt-in; nothing leaves the device by default. |
| 16 | STT | v1: push-to-talk dictation into any pane (local or remote), on-device SpeechAnalyzer. |
| 17 | Product name | **Allward.** Clean repository, protocol, and Swift-module cutover with no compatibility aliases. |
| 19 | Gates | G1 engine conformance subset + flood perf on reference hardware · G2 the #3 demo end-to-end · G3 public/MAS polish bar. Kill/continue at each. |
| 20 | Privacy | Zero telemetry; opt-in crash reports only. |
| 21 | Config | Plain-text file, live reload, GUI writes the file. Import: ghostty, wezterm, other common formats. |

## Settled (Round 2 walkthrough, 2026-07-29)

| # | Decision | Call |
|---|---|---|
| 13-rev | Command tracking, three lanes | (1) Direct-SSH + local PTY: engine parses OSC 133 natively. (2) herdr agent panes: harness publishes over Allward protocol (superset of OSC 133). (3) herdr shell panes: Allward shell integration publishes out-of-band. herdr tokens = compact projection; upstream herdr PR later, never load-bearing. Degradation ladder is spec-mandatory: zero-install = herdr-parity status via socket API; +1 rc line/host = shell regions; +1 shim/harness = rich surfaces. PTY-wrapper held in reserve. |
| 23 | Protocol vocabulary = ACP's | ACP (Zed+JetBrains, SDKs 1.0, v2 draft 2026-07) owns agent↔client structured state but only for client-OWNED subprocess agents. Allward's sideband reuses ACP schema shapes (plan entries, session updates, permission requests) over its own transport: "ACP for agents your editor doesn't own." Later door: Allward as native ACP client (spawn-agent chat panes). |
| 24 | Harness concierge | Allward detects harness per pane (via herdr agent detection), offers one-keystroke shim install over its existing SSH connection. Consent-first, idempotent, versioned, uninstallable, remembered per host+harness. omp = plugin install; Claude Code = hooks merge; Codex = manual-trust step, honestly labeled. |

| 25 | Rooms | First-class primitive binding theme, tint, hosts, adapter servers, notification rules, and defaults. Workspaces map to Rooms; windows and tabs inherit. Apple Focus filters may allow or deny each Room. |
| 26 | ND-friendly cut | v1: (a) re-entry digest, (b) attention router, (c) open-loop board. Roadmap, not dropped: (d) focus mode, (e) time anchors (never scores), (f) notification digests. New requirement: divided-attention glanceability — ambient board presentation of the router (big type, second display, unfocused-window), menu-bar count; notifications are NOT the reliable channel (macOS Game Mode suppresses them). Router strip v1; ambient board first fast-follow. |
| 27 | Aesthetic direction | Restraint + expressive micro-interactions; grid is the hero, chrome invisible until summoned. Depth mandate: "restraint outside, competence underneath" — anything the user would have had to do should already have happened, silently (keys, forwards, shim offers, reconnects, digests). Effortlessness is budgeted as a feature, not assumed. |
| 28 | Design gates + sound | The design language precedes interface code and gates every visual change. Sound belongs to the language from day one: designed earcons, off by default globally, enabled per-Room notification rules. |
| 29 | herdr flagship moments | Initial build: (a) instant board, (b) one-key teleport, (c) native todo surfaces — one continuous demo. herdr's verified socket API supplies discovery, coarse agent state, focus, and teleport targets; Allward protocol publishers supply rich plans/todos/permissions. In spec as roadmap: (d) cross-CT scrollback search (v1.x headliner), (e) session hand-off (protocol must anticipate; herdr server-side persistence makes it plausible). |
| 30 | MCP surface | Allward ships an MCP server for pane control, board queries, surfaces, and Rooms-aware operations. It implements the legacy and modern protocol paths defined in `SPEC.md`; MCP client behavior is outside v1. |
| 31 | Performance + reliability bars | G1 requires a 2M-line flood under 1s on reference hardware, input latency below 8 ms p99, 120 Hz behavior, zero idle GPU frames and near-zero idle CPU, coherent resize, strict Swift 6 concurrency, parser fuzzing, and a 24-hour flood-and-idle soak without crashes, hangs, or leaks. Rendering stays event-driven. |
| 32 | Inline images | v1.x, not v1 (kitty graphics + iTerm2 OSC 1337). Renderer architecture reserves the image layer (second texture plane behind glyphs) from day one so it lands as an addition, not a rework — same pattern as the reserved shaping stage. |
| 33 | Intelligence cut | v1: (a) session/tab auto-naming, (b) away-digest language layer. Roadmap: (c) error triage via guided generation, (d) NL->command — ships only when it can beat the Warp comparison. All on-device per decision 15. |
| 34 | Theme import | Day one: iTerm2 .itermcolors, Ghostty themes, base16/base24 YAML — convert-and-keep into Allward's own format (attributed, editable), never a live foreign-format dependency. v1.x: kitty configs, VS Code terminal palettes. Others = community converters (open-source dividend). |
| 35 | Cadence | Momentum-based; G1, G2, and G3 are quality bars, not dates. Specifications and executable gates preserve state between work bursts. |
| 36 | Primitive name | **Rooms.** ("Context" collides with context windows; Realms/Flyways declined.) |
| 37 | Sidecar | Deferred to 1.x (first consumer: cross-CT scrollback search indexing). v1 publishers talk straight to Allward over ssh-forwarded sockets; Collie-pattern supervised sidecar is the documented escape hatch. Concierge's thin herdr plugin = optional sugar. |
| 38 | herdr dependency boundary | herdr is **optional**, not a runtime or product requirement. Allward is a complete local terminal (Developer ID) and direct-SSH terminal (both targets) with Rooms, OSC 133, STT, MCP, themes, panes/tabs/splits, and open protocol publishers. Multiplexer integration is an adapter seam: herdr is the first/deepest v1 adapter and flagship demo; tmux follows in 1.x; no adapter is a supported mode. Without herdr, only herdr-specific automatic fleet discovery, persistent workspace mapping, and herdr-backed teleport are absent. |

## Settled product identity (2026-07-30)

- Product name: **Allward**.
- Repository and protocol vocabulary use Allward without compatibility aliases.
- Swift modules use the `Allward` prefix.
- Naming research screened current developer tools, package registries, public repositories, the Mac App Store, and obvious domains before the maintainer accepted the name.
