# Allward architecture position

Status: accepted architecture behind the canonical technical and design specifications.

**Product boundary:** Allward is complete without herdr. Local PTY and direct-SSH
sessions, Rooms, OSC 133, STT, MCP, themes, panes/tabs/splits, and protocol
publishers are core. Multiplexers enter through adapters: herdr is the deepest
v1 adapter and flagship demo; tmux follows in 1.x; no adapter is a supported
mode.

## Convergences

1. **Actor-owned state.** Each session has one owner for byte ingestion,
   parsing, grid mutation, scrollback, and damage. UI receives immutable
   snapshots. Main never touches terminal bytes.
2. **Link-time target isolation.** `AllwardLocalPTY` links only into the Developer
   ID product. The shared core remains sandbox-clean; the MAS product cannot
   call local PTY code because that code is absent from its graph.
3. **Typed terminal pipeline.** Incremental decoder -> bounded escape
   recognizer -> typed operations -> reducer -> damage -> snapshot. Malformed
   recovery is bounded and parser mutation remains session-owned.
4. **Coherent renderer.** Metal consumes one coherent snapshot generation,
   uses ordered scene passes, separate monochrome/RGBA atlases, damage-scoped
   uploads, and newest-generation coalescing. The image plane and shaping seam
   exist in v1 but do no feature work.
5. **Shared SSH facade.** Remote PTYs, herdr client channels, control channels,
   and socket forwarding sit behind one in-process SSH interface and one
   supervised connection state machine in both products.
6. **Provenance-bearing state.** Publisher and herdr inputs normalize into
   immutable records carrying source, session, sequence, freshness, and lease
   state. Disconnect preserves visibly stale state; it never invents deletion.
7. **Facts before language.** Raw state and deterministic digests remain
   authoritative. Foundation Models only rewrite bounded facts. BYO inference
   is opt-in and goes through one outbound broker.
8. **Dictation never executes.** Push-to-talk locks a destination, sends the
   final transcript through that pane's ordinary input encoder, and never adds
   Return.
9. **MCP server only in v1.** Allward exposes its control plane. MCP-client work
   waits for a real consumer such as native ACP chat panes.
10. **Lossless config editing.** Canonical UTF-8 TOML preserves comments,
    ordering, and unknown keys. Invalid reload retains the last-good config.
    Imported themes convert into Allward-owned editable files.
11. **Accessibility mirrors state, not pixels.** A lazy AppKit accessibility
    tree projects the same logical lines, cursor, selection, and scroll state
    used by Metal. It is virtualized to visible lines plus a bounded margin.

## Reconciled decisions

12. **herdr is trusted remote session infrastructure.** herdr owns the remote
    PTYs, workspace layout, focus, and multiplexing. Allward does not reconstruct
    or scrape that composition. This trust is scoped: Allward still validates all
    herdr protocol input and keeps crashes/stalls outside its terminal-state
    owner. Supporting untrusted third-party servers would require a later
    isolation threat model.
13. **Primary herdr content route.** Run one full herdr client per visible
    workspace under an Allward-owned SSH PTY and render its compositor stream as
    one terminal surface. Allward's independent socket client remains authority
    for verified inventory, workspace/focus state, coarse agent metadata, and
    teleport targets. Rich plans, todos, permissions, session updates, command
    regions, board entries, and attention facts come from Allward protocol
    publishers; herdr may associate those records with its verified identities.
    A disposable probe must prove shell and agent rendering,
    keyboard, mouse, paste, cursor, selection, alt-screen, resize, reconnect,
    focus routing, and sub-second LAN attach before G2 adapter qualification.
14. **Fallback ladder.** If the full-client probe fails: (1) bidirectional
    `herdr agent attach` for a known agent pane, clearly labeled agent-only;
    (2) `pane.read` on open/focus/reconnect/manual refresh or a verified event,
    clearly labeled read-only and possibly stale; (3) ordinary SSH terminal
    running herdr without native control-plane synchronization. No periodic
    pane polling. No fallback claims raw inner OSC 133.
15. **Command semantics stay sideband.** Direct SSH/local PTY panes parse OSC
    133. herdr agent panes receive harness-published regions/state through the
    Allward protocol. herdr shell panes receive shell-integration publications.
    herdr metadata is a compact projection for other clients.
16. **Scrollback model.** Use a packed active grid and fixed-capacity logical
    line blocks with stable line identifiers, interned attributes, allocation-
    free steady-state append, and bounded retention. Benchmarks decide block
    size/compression; representation must preserve reflow, selection anchors,
    accessibility, and future cross-session search.
17. **Conformance manifest.** G1 pins exact upstream commits and case IDs in a
    checked-in manifest. It combines named esctest behavior classes, vttest
    visual sections, fuzz corpora, and explicit non-goals. Freeze the manifest
    for the gate; later additions create a new revision rather than moving it.
18. **Idle and resize.** No perpetual cursor timer and no scaled-old-grid frame.
    Cursor blink may batch with existing work or stop at true idle. Resize
    presents only coherent new geometry; accessibility cannot depend on blink.
19. **Renderer scheduler stays measurable.** `CAMetalDisplayLink` is a
    candidate, not a promise. Select the scheduler and frame-pacing strategy
    from reference-hardware measurements against latency, ProMotion, resize, and
    idle-energy bars.
20. **SSH implementation stays behind the facade.** SwiftNIO SSH and libssh2
    are spike candidates. Selection needs Developer ID and MAS receipts for
    PTY channels, forwarding, host-key trust, credentials, cancellation,
    concurrency, reconnect, and packaging.
21. **Connection lifecycle.** One connection identity supervises states
    `idle -> resolving -> connecting -> authenticating -> ready -> degraded ->
    reconnecting/closed`. Room state does not own connections. Credentials,
    ssh-agent behavior, and MAS key access are never assumed.
22. **Lease semantics.** Publisher records carry epoch and monotonic sequence.
    Publishers negotiate bounded leases; disconnect or expiry marks stale
    immediately. Permission expiry, visible stale retention, and digest history
    are separate policies. Initial durations are measured defaults, not
    architecture constants.
23. **Protocol evolution.** Allward protocol uses a semantic major plus declared
    capabilities. Unknown in-major messages are ignored safely and counted;
    unsupported majors fail per publisher. Supporting adjacent majors is
    permitted, not promised for v0.
24. **Room mapping precedence.** Explicit pane/session mapping wins, then
    accepted workspace mapping, then accepted host mapping, then default Room.
    First sight proposes a mapping; it never silently moves work. Accepted and
    dismissed choices persist by host+harness/workspace identity.
25. **One Room per window in v1.** Tabs and panes inherit the window's Room.
    Mixed-Room windows and pane-level overrides are out of v1.
26. **Room tint does not recolor the grid.** Room identity changes chrome,
    focus rings, board surfaces, motion, and optional material; the terminal
    palette remains theme-true. State is never color-only.
27. **Attention precedence.** Permission/approval and explicit needs-input
    outrank error, disconnected/stale, running, finished, then idle. Stable
    ordering breaks ties. Router policy is deterministic and inspectable.
28. **Re-entry boundary is event-based.** A digest appears after meaningful
    unseen state change, not merely after a timer. It starts as deterministic
    facts and may gain a bounded language layer. The user can always inspect
    source events.
29. **Ambient board scope.** The in-app router strip and instant board ship in
    the initial build. The big-type, second-display ambient presentation and
    menu-bar count are 1.x, but their tokens and layout contract live in the
    design language now.
30. **Intelligence availability.** Auto-naming and digest rewriting use
    `SystemLanguageModel` only when available. Unsupported devices/regions or
    unavailable assets retain complete deterministic UX. BYO endpoints are
    opt-in by feature and Room; prompts contain only bounded derived facts.
31. **MCP is dual-era, not version echo.** Implement the real legacy
    `2024-11-05` initialize/initialized lifecycle and modern `2026-07-28`
    per-request versioning plus required `server/discover`. Follow official
    stdio/HTTP probing and fallback rules. Pin schemas and conformance clients.
    Do not claim every intermediate revision until it has a passing fixture.
32. **MCP v1 surface.** Read operations: Rooms, sessions/panes, current screen,
    history/regions, board, attention, digest, todos, activity. Mutations:
    focus/teleport, send text/keys, run with OSC-133 completion, split/open/
    close, todo publication, surface publication. Each operation exposes exact
    target and stale/provenance state. Focus filters govern notifications and
    ambient UI, not hidden authorization of explicit MCP reads; Room access
    control is a separate future policy.
33. **Concierge is transactional.** Detect the actual harness per pane. Offer
    one targeted install over the existing SSH connection. Recipes are
    versioned, consent-first, idempotent, dry-run capable, conflict-aware, and
    uninstallable; they preserve user files and record only the changes they
    own. OMP uses its extension/plugin path; Claude merges hooks; Codex labels
    the manual trust step.
34. **STT destination lock.** Capture stores session+pane identity at press.
    Focus changes do not retarget. If the destination closes or becomes stale,
    show the transcript in the composer and send nothing. Escape cancels;
    release finalizes.
35. **Config transaction.** Watch -> read whole file -> parse -> validate ->
    compute semantic diff -> apply atomically -> publish generation. GUI edits
    use compare-and-swap on the loaded generation and surface external-edit
    conflicts rather than overwriting.
36. **Grapheme ownership.** Decode Unicode, form grapheme clusters, calculate
    display width, then pass clusters through the reserved shaping stage.
    v1 shaping may be identity, but combining characters and real emoji are
    correct before it.
37. **Release targets.** Developer ID build supports local+remote and may use
    a signed update feed only after update security is specified. MAS build is
    remote-only and sandboxed. Every tagged build compiles, signs, and exercises
    both targets; MAS submission remains after G3.
38. **G1 content.** Frozen conformance corpus; parser fuzz; 2M-line flood;
    <8 ms p99 keypress-to-glyph on owner hardware; 120 Hz behavior; coherent
    resize; zero idle GPU frames/~zero idle CPU; terminal-grid VoiceOver spike;
    both-target SSH/credential probe; first Design Language review; 24-hour
    flood+idle soak with zero crash/hang/leak.
39. **G2 content.** One-take, no-fixture demo against at least two real remote
    containers: discover sessions, show instant board/todos/router, attach in
    <1 s on LAN, teleport once, dictate into a remote pane without submitting,
    complete/reconnect without manual recovery. Deterministic fallbacks remain
    visible if intelligence is unavailable.
40. **G3 content.** Public-product polish: design gate clean, Accessibility
    Inspector/VoiceOver/keyboard receipts, theme imports, concierge install+
    uninstall, signed/notarized Developer ID release, MAS archive/validation
    dry run, privacy copy, first-run UX, no open P0/P1 findings.
41. **Semantic design tokens first.** Freeze type roles, color roles, material
    roles, motion meanings, and sound meanings now. Literal fonts, point sizes,
    palette values, curves, and audio assets remain design probes requiring
    owner approval at the Design Language review.
42. **Contrast floors.** Allward-owned normal text >=4.5:1; large ambient text and
    non-text state marks >=3:1; ambient primary text targets 7:1. Imported
    terminal palettes are preserved after a warning, never silently clamped.
43. **Motion never moves the grid gratuitously.** Attach and Room changes use
    chrome/material transitions; terminal cells remain spatially stable.
    Reduced Motion removes translation, scale, spring, and repeated pulse —
    not merely replacing them with long fades.
44. **Earcon vocabulary.** Initial semantic family: needs-input, finished,
    error, digest-ready. Globally off by default; user enables per Room/event.
    Earcons are brief, non-speech, volume-consistent, and paired with visible
    state. Assets require owner listening approval.
45. **Spatial hierarchy.** Grid remains dominant. Pane headers appear when
    identity/action is useful, not as permanent card chrome around every pane.
    Board is a native summonable surface; router remains glanceable without
    covering input. Ambient contracts cover distance legibility now, ship 1.x.
46. **Accessibility acceptance.** The mirror exposes logical text, cursor,
    selection, visible range, scroll actions, and change notifications without
    material parse/render cost. Accessibility Inspector and VoiceOver probes
    are G1 work, not G3 cleanup.
47. **Visual receipts.** Stable spine: 375/768/1024/1440 widths where
    applicable, plus 900x600 default Mac window, split-heavy fixture, and
    2560x1440 ambient fixture. Changed flows capture dark/light, keyboard
    focus, Reduced Motion, empty, stale/degraded, permission/error, and maximum
    content states where applicable.
48. **Decision authority.** Evidence decides transport/library/API questions.
    Owner approves product identity assets (font, palette, Room tints, motion
    feel, earcons) at G1 and any change that would reopen a settled decision.
    Reversible engineering defaults do not block implementation.

49. **Multiplexer independence.** The core never imports herdr types. A
    `MultiplexerAdapter` supplies discovery, durable workspace identity,
    attach targets, metadata, and adapter-specific actions. With no adapter,
    board/router/digests aggregate local/direct-SSH sessions and any Allward
    protocol publishers. Onboarding presents herdr as an enhancement, never a
    prerequisite. G1 must pass with no herdr installed; G2 proves the herdr
    flagship path.
