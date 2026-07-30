# Allward design language

Status: canonical Part II specification. This file owns §§18-25. `SPEC.md` owns technical architecture and behavior in §§1-17.

The terminal grid is the primary work surface. Chrome exists only to identify a target, expose state, present a choice, or recover from failure. All shared terms retain their meanings from `SPEC.md`.

`MUST`, `SHOULD`, and `MAY` are normative.

## 18. Principles

### 18.1 Restraint outside, competence underneath

The terminal grid is the primary work surface. Chrome exists only to identify a target, expose state, present a
choice, or recover from failure. Decorative chrome, permanent cards around panes, and repeated status copy are
prohibited.

Safe, reversible work happens without ceremony: reconnect, forwarding, accepted Room mapping, digest preparation,
and known integration checks. Silent work MUST leave a receipt in the relevant detail surface. A failure replaces
silent work with a named state, target, cause, and next action; it never becomes an indefinite spinner.

The visual hierarchy is:

1. terminal content;
2. active input target and permission state;
3. failure, stale, and degraded state;
4. router and open loops;
5. Room context;
6. navigation and settings.

A lower layer MUST NOT obscure or visually outrank a higher layer during terminal operation. A user-summoned blocking surface MAY cover terminal pixels only after it takes focus, suspends terminal input, announces the focus transfer, preserves `gridFrame`, and guarantees the §23.1 dismissal target.

### 18.2 Neurodivergent-friendly operation

The interface externalizes state instead of asking the user to remember it. Open loops, blocked requests, stale
sessions, current destinations, and unseen changes remain in stable, inspectable surfaces.

The interface MUST NOT use productivity scores, streaks, motivational copy, fabricated percentages, model-generated
urgency, or time-pressure theater. Counts are neutral facts. Age is shown only when it explains freshness, ordering,
or actionability. State does not disappear merely because its source disconnected; it becomes visibly stale under
the lifecycle in `SPEC.md` §6.

Relative-age labels use bucketed thresholds (e.g., "just now", "minutes ago", "hours ago") rather than precise
elapsed time. A shared deadline scheduler wakes only when a visible label crosses its next bucket; hidden labels
schedule nothing. This rule prevents per-second or per-minute wakeups when no state has changed.

Interruptions are routed, not broadcast. Router eligibility, class, and total ordering come only from the `SurfaceEligibilityReducer` and comparator in `SPEC.md` §8. Every projection uses one normalized generation; a compact surface may omit fields only under the §23.5 projection schema and named detail path.

### 18.3 Divided-attention glanceability

Pane headers, the router strip, the board, and the ambient board are projections of one
normalized state model. They MUST NOT derive independent counts or labels.

The model accepts any set of available publishers, including none. Emptiness is scoped per source. Adapter `none` empties only adapter discovery and availability; it never empties local/direct sessions, board rows, todos, command regions, router facts, or digest facts supplied by direct OSC 133 or normalized publishers. Publisher-derived columns are empty only when no normalized publisher source has records. No empty state becomes an install prompt, warning badge, or degraded terminal status.

A glanceable state uses at least two of text, icon/shape, position, and color. Motion and sound are optional
reinforcement and never the sole carrier. Peripheral Room recognition comes from stable chrome placement and Room
tint, not from recoloring terminal content.

The ambient board answers, at second-display distance: which Room needs action, what kind of action, how many items
exist, and which destination key reaches it. It does not reproduce terminal output. System notifications are
supplemental; Allward-owned surfaces remain complete when notifications are suppressed.

### 18.4 Terminal truth and spatial stability

Room identity may change chrome, focus treatment, board surfaces, finite motion, optional material, and sound
policy. It MUST NOT remap ANSI colors, cursor color, selection semantics, text, or command output in the selected
terminal theme.

A terminal surface owns a `gridFrame`: the exact rectangle used to derive rows, columns, cell geometry, selection
geometry, and accessibility geometry. Hover, focus, attention, stale state, Room tint, attach completion, and router
updates MUST NOT move or scale that frame. A geometry change commits only after the terminal engine has a coherent
new grid generation. The previous coherent frame remains until that commit; no scaled old grid, mixed geometry, or
animated cell travel is allowed.

### 18.5 One action, one destination

Attach, teleport, dictation, paste, approval, close, and integration changes MUST name and lock their Room, session,
and pane target before work starts. Visual transition cannot imply success before target acknowledgement. Failure
MUST NOT fall through to another pane, Room, host, or credential.

### 18.6 Facts before prose

Raw state and deterministic digest facts remain authoritative. Model-generated names and digest wording MAY shorten
those facts but cannot decide state, priority, completion, permission, or action. The deterministic source remains
inspectable. Model unavailability is a normal state with complete deterministic UX, not an error-shaped empty
surface.

### 18.7 Accessibility is a rendering contract

Metal pixels and accessibility elements are parallel projections of the same immutable terminal state. Accessibility
never reads pixels, scrapes terminal output, or depends on animation. The projection mechanism and receipts are part
of G1, not deferred polish.

### 18.8 Zero-multiplexer baseline

A Room can contain local sessions, direct-SSH sessions, herdr workspaces, or any combination allowed by the product
target. Room identity, theme, tint, Focus policy, notification policy, and defaults do not depend on a multiplexer.

Local PTY (Developer ID only) and direct SSH are first-class terminal routes. They receive the full grid, selection, scrollback,
keyboard, paste, STT destination lock, theming, and accessibility projection. MCP operations address these sessions
directly. Their board, router, digest, and todo surfaces normalize whatever publishers exist; no publisher means no
published agent state, not an incomplete terminal.

The UI MAY offer herdr as an adapter in connection and discovery flows, but empty or degraded copy MUST NOT tell a
user to install, run, or reconnect herdr unless the affected session was explicitly configured as a herdr session.

### 18.9 Universal state grammar

Components use these semantic states. A component may omit states that cannot occur, but it may not rename an
existing meaning locally.

| State | Meaning | Required presentation |
|---|---|---|
| `loading` | First authoritative value has not arrived | Target label, current attempt/step, declared attempt bound, cancel when possible |
| `empty` | Authoritative value arrived and contains no items | What is empty, why that is normal, and the next useful action when one exists |
| `live` | Source is current and the component is fully capable | Ordinary presentation; no success badge merely for being healthy |
| `needs-input` | A named user action or permission is required | Explicit verb, source, target, destination action, non-color mark |
| `running` | Work is active but needs no user action | Calm state label; no pulse or elapsed-time pressure |
| `finished` | A tracked transition completed | Completion mark and inspectable result/source; no forced dismissal |
| `stale` | Last value is retained after lease loss or disconnect | Last-known label, freshness/last receipt, source, stale reason, no live action |
| `degraded` | Content or control remains usable with reduced capability | Exact mode label, missing capability, provenance, and recovery action |
| `denied` | Consent, authorization, or product policy excludes an action | Which policy denied it and how to inspect or change that policy |
| `error` | An attempted operation failed | Failed operation, exact target, bounded diagnostic, retry or alternate path |
| `disabled` | Control is unavailable by product or target capability | Reason visible on focus/hover and in accessible help; never unexplained low contrast |

`loading`, `empty`, `stale`, `degraded`, `denied`, and `error` are first-class design states. Skeletons, blank
panes, and generic “Something went wrong” copy do not satisfy this contract.

`loading` ends when the source operation reports success, cancellation, its declared attempt bound, or another
terminal lifecycle state. At that boundary the component enters the non-loading presentation produced by §18.10 composition; it cannot remain loading. A source that supplies no bounded attempt is a technical-contract
failure and presents `error` with cancel, retry, and diagnostics. Unaffected sessions and the last coherent frame
remain usable. Gate fixtures MUST include a source that never responds and assert the terminal state transition.

### 18.10 Canonical state mapping — presentation

This section is the sole canonical mapping from technical source-state composition to design presentation. `SPEC.md`
references it and MUST NOT define a second presentation map. The design vocabulary contains no `idle` or `none`
state: activity `idle` is a `live` substate, and adapter `none` is normal capability absence.

**Scope:** this section owns final design state, visible label behavior, and accessibility value. It does not decide
board actionability, router membership/class, or digest inclusion. Those outputs come only from the
`SurfaceEligibilityReducer` in `SPEC.md` §8.

#### 18.10.1 Ordered composition

Technical dimensions are independent. Compose them in this order, stopping at the first terminal rule:

1. **Source/operation and applicable adapter health:** source/operation `error` presents `error`. Adapter health participates only when the composed target route is owned by that adapter; an unrelated adapter state is ignored. For an adapter-owned target, adapter `error` presents `error`, `denied` presents `denied`, and `degraded` remains a candidate for step 7; adapter `none` continues.
2. **Connection:** pre-ready states present `loading`; trust/credential closure presents `denied`; nonretryable closure presents `error`; explicit/cancelled closure presents `empty`; `reconnecting` presents `stale` with a visible `Disconnected` or `Reconnecting` reason. Connection `degraded` remains a candidate for step 7.
3. **Publisher lifecycle:** `negotiating` presents `loading`; `rejected` presents `denied`; a live/terminal lifecycle continues to freshness.
4. **Freshness and transition phase:** `superseded` has no active presentation; `stale` presents `stale` and disables every live action. `ended` plus work-lifecycle `finished` presents `finished` only for the reducer-supplied finished-transition event; the subsequent current-state projection follows technical retention/history and otherwise presents `empty`.
5. **Permission/action:** only a live, usable source may present `needs-input`. `active` presents `needs-input`; `expired` or `denied` presents `denied` and is non-actionable; `dismissed` presents `empty`; `granted` continues.
6. **Work lifecycle:** `finished` presents `finished`; `running` presents `running`.
7. **Base capability:** source/operation, adapter, or connection degradation presents `degraded`; adapter `none` affects adapter
   discovery/availability only; otherwise the source presents `live` or its component-specific `empty` state.

**Control availability composes after the component state:** a control whose product/target capability is unavailable presents the `disabled` control substate inside its parent presentation. Disabled never replaces the parent component state, becomes actionable, or permits a local renamed state.

**Composed source usability handoff:** action, announcement, and earcon candidates MUST NOT consume a raw permission or event in isolation. Presentation composition emits the usability facts below; the technical `SurfaceEligibilityReducer` consumes the same facts and owns board actionability, router class/destination, digest inclusion, and semantic delivery eligibility. §22 and §24 consume only that reducer output.

| Composed condition | Usability contribution | Required sensory/action result |
|---|---|---|
| Applicable source/operation, adapter, connection, or publisher terminal error | `error-recovery-only` | Permission/approval action and speech suppressed; only reducer-selected error recovery may be actionable or announced |
| Applicable stale/reconnecting connection or stale publisher | `stale-nonactionable` | Approval action, approval speech, and `needs-input` earcon suppressed; stale state may be announced once |
| Explicit/cancelled normal connection close | `closed-absent` | Target removed/empty per technical policy; queued state speech and earcons cancelled; no close announcement or ghost action |
| Live source plus unavailable control | `usable-control-disabled` | Parent state remains inspectable; control has disabled trait/help; no action, actionable epoch, approval speech, or `needs-input` earcon |
| Live source plus available control | `usable-action-capable` | Permission/action may enter reducer eligibility; reducer still applies Focus, presence, subject, and transition rules |

An error/stale/closed/unavailable result cannot be re-promoted by a later permission state. The immutable generation carries presentation, accessibility value, and the technical reducer tuple together; disagreement fails G1.


Thus stale plus active permission presents `stale`, with its action disabled. Ended plus finished presents the
`finished` event before the retained/history policy removes it from the open surface. Focus filtering is not access control: directly opened retained content keeps its already-composed presentation and remains readable. The canonical unsolicited-mask list is router, digest, ambient, system notification, sound, and accessibility announcement; the technical reducer applies it. Later sections reference this list and MUST NOT redefine it.

#### 18.10.2 Source-to-presentation mapping

| Source layer | Canonical source state | Presentation contribution | Rule |
|---|---|---|---|
| Adapter health | `none` | adapter-discovery `empty` only | Normal absence; local/direct sessions and their OSC 133 or publisher data remain rendered |
| Adapter health | `available` | `live` | Adapter capabilities available |
| Adapter health | `degraded` | `degraded` candidate | Name the missing adapter capability and recovery |
| Adapter health | `denied` | `denied` | Adapter enrollment or policy denied |
| Adapter health | `error` | `error` | Adapter operation failed |
| Connection | `idle` | `loading` | Pre-connect state with bounded next attempt |
| Connection | `resolving` | `loading` | Address resolution in progress |
| Connection | `connecting` | `loading` | Transport establishment in progress |
| Connection | `authenticating` | `loading` | Trust/credential exchange in progress |
| Connection | `ready` | continue | Connection usable; later dimensions decide presentation |
| Connection | `degraded` | `degraded` candidate | Child capability reduced; unaffected capabilities remain usable |
| Connection | `reconnecting` | `stale` | Retain last frame; MUST show a visible `Disconnected` or `Reconnecting` reason; disable live actions |
| Connection | `closed` after explicit close/cancel transition in `SPEC.md` §5 | `empty` | Normal terminal state; no target remains |
| Connection | `closed` after trust/credential-denial transition in `SPEC.md` §5 | `denied` | Name denied trust/credential and recovery |
| Connection | `closed` after nonretryable-failure transition in `SPEC.md` §5 | `error` | Name failure and alternate path |
| Publisher lifecycle | `negotiating` | `loading` | Grant/major/capability negotiation in progress |
| Publisher lifecycle | `rejected` | `denied` | Authentication, target, major, or capability rejected |
| Publisher freshness | `live` | continue | Current authoritative value |
| Publisher freshness | `stale` | `stale` | Retain value and provenance; disable live actions |
| Publisher freshness | `ended` | `finished` only with work-lifecycle `finished`, then `empty`/history; otherwise `empty` | Preserve a distinct completion event only when the semantic work transition proves completion |
| Publisher freshness | `superseded` | no active element | Replacement owns presentation; prior record is absent from active AX/UI |
| Activity | `idle` | `live` substate | Optional `color.state.idle` accent; never a first-class design state |
| Permission | `active` | `needs-input` if source is live | Show exact verb, target, source, and action |
| Permission | `expired` | `denied` | Inspectable, non-actionable, renewal path; never `stale` |
| Permission | `dismissed` | `empty` | No pending action |
| Permission | `granted` | continue | Publisher-backed UI may use `granted` only after the `PermissionDecisionTransaction` outcome is `committed`; local acknowledgment, transport acceptance, or publisher acknowledgment alone cannot grant |
| Permission | `denied` | `denied` | Inspectable, non-actionable denial and appeal/retry path |
| Focus filter | `denied` | continue with `Focus-filtered` substate when directly opened | Preserve live/stale/degraded presentation and readability; `SPEC.md` masks unsolicited projections and speech |
| Source/operation health | `degraded` | `degraded` candidate | Name the reduced capability and recovery |
| Source/operation health | `error` | `error` | Name source, failed operation, and recovery |
| Work lifecycle | `running` | `running` | Active work requiring no action |
| Work lifecycle | `finished` | `finished` | Distinct completion event and inspectable result |
| Control capability | `unavailable` | `disabled` control substate | Keep parent presentation; expose exact unavailable reason and no action |

**Source-class parity — `mcp_authored` records:** `publisher_direct`, adapter-associated, and `mcp_authored` records present through this same composition; there is no MCP-specific presentation branch. An `mcp_authored` record consumes only the receiver-owned identity, order, and `live | stale | ended | superseded` freshness stamped by `SPEC.md` §6 and §11; presentation never derives freshness from invocation success, grant validity, or transport liveness on its own. When grant expiry, revocation, client disconnect, server relaunch, or replacement marks an `mcp_authored` record stale or ends its authority, that record presents its composed stale/ended/superseded result exactly as a publisher record would: never actionable, never enqueuing approval or state speech, never sounding. Replacement identity is supplied only by `SPEC.md`; a superseded `mcp_authored` record has no active presentation, and the UI MUST NOT merge, resurrect, or dedupe MCP records by visual heuristic.

**Connection-phase exit totality:** every active nonterminal connection phase (`resolving`, `connecting`, `authenticating`, `ready`, `degraded`, `reconnecting`) has typed exits for cancellation, bounded timeout, retryable failure, nonretryable failure, trust/credential denial, explicit close, and success, per the total transition table in `SPEC.md` §5. Each exit presents exactly its matching row above: cancellation and explicit close present `empty`; trust/credential denial presents `denied`; nonretryable failure and an exhausted declared attempt bound present `error` naming the failed phase, typed cause, and recovery; a retryable failure inside the bound continues `loading` or `reconnecting` with a visible attempt count. The three terminal causes are never conflated. In `idle`, success, cancel, timeout, either failure class, denial, and disconnect are the exact state-preserving `no-active-operation` no-ops defined by `SPEC.md`; they create no presentation or announcement. Only explicit close from `idle` produces the normal `empty` close result.

#### 18.10.3 Accessibility value contract

| Final presentation | Required accessibility value |
|---|---|
| `loading` | `Loading: <target>; <current bounded step>` |
| `empty` | `<component> empty: <normal reason>` |
| `live` | `<target>; live` plus a proven semantic value; idle/Focus-filtered may append their substate |
| `needs-input` | `Needs input: <verb>; <target>; <source>` |
| `running` | `Running: <target>; <work kind>` |
| `finished` | `Finished: <target>; <result kind>` |
| `stale` | `Stale: <target>; <reason>; last received <bucket>`; actions expose disabled help |
| `degraded` | `Degraded: <target>; missing <capability>` |
| `denied` | `Denied: <target>; <policy or permission reason>` |
| `error` | `Error: <target>; <failed operation>; <recovery>` |
| `disabled` control | `<control>; unavailable: <capability reason>` plus disabled trait/help |
| no active presentation | No accessibility element or queued announcement |

Visible labels may be shorter, but they MUST preserve the same target, state, and distinguishing reason.

#### 18.10.4 G1 composed-presentation fixture

The shared G1 fixture exhausts the finite product of source/operation health × adapter applicability/health × connection state/last transition × publisher lifecycle/freshness × reducer-supplied transition phase × permission/action × Focus filter × work lifecycle × control availability. Each transition-phase cell has one component output plus its enabled/disabled control outputs: the finished event cell is `finished`; the later current-state cell is its technical retained/history or `empty` presentation. Every cell carries paired expected outputs: this section's final presentation,
visible label, and accessibility value, plus `SPEC.md`'s separate eligibility tuple. Required sentinels include stale
plus active permission (`stale`, disabled action), ended plus finished (`finished` transition before retention),
source-health error plus every target state (`error`), applicable adapter-health error plus every adapter-owned target state (`error`), unrelated adapter error plus healthy local/direct state (local/direct presentation unchanged), adapter `none` plus nonempty direct OSC/publisher data (data remains visible),
and Focus-denied explicit navigation (readable detail with no unsolicited speech). Required usability sentinels are: active permission plus applicable terminal error (error recovery only; no approval action/speech), active permission plus stale (stale non-actionable; no approval action/speech), active permission plus unavailable control (disabled and non-actionable), and explicit/cancelled normal close (empty/absent; no queued or ghost speech/action). Each sentinel includes the exact paired `SurfaceEligibilityReducer` output from `SPEC.md` §8. Impossible source combinations remain explicit cells marked invalid with the violated source invariant; no cell may be omitted. Missing cells fail G1.

The fixture additionally includes: a stale `mcp_authored` permission record (stale, non-actionable, no approval action, speech, or earcon); a superseded `mcp_authored` record beside its live replacement (only the replacement holds active presentation and accessibility); for every active nonterminal connection phase, cancellation, bounded-timeout, trust-denial, and nonretryable-failure exit cells, each resolving to its exact §18.10.2 closed/`reconnecting` row with no cell remaining `loading`; and `idle` sentinels proving every no-active-operation event is presentation-neutral while explicit close alone produces `empty`.

The `SurfaceEligibilityReducer` consumes the same source states plus transition type, actionability, Focus mask,
presence, and projection winner. It does not consume presentation state, which prevents an authority cycle.

## 19. Typography

### 19.1 Type roles

Typography freezes semantic roles, not final font assets or point values. Literal faces, sizes, line heights,
tracking, and weight mappings require the owner-approved type probe in DL-OQ-01.

| Token | Role | Contract |
|---|---|---|
| `type.grid.body` | Terminal cells | User-configurable monospace; metrics derive cell geometry |
| `type.grid.bold` | Terminal bold attribute | Resolved from the grid family without changing cell advance |
| `type.grid.italic` | Terminal italic attribute | Uses a real italic mapping when available; preserves cell advance |
| `type.grid.presentation` | User-selected larger interactive grid | Same terminal semantics and geometry derivation as `type.grid.body` |
| `type.ui.caption` | Freshness, provenance, key hints | Lowest UI role; never carries the only action or failure label |
| `type.ui.label` | Pane headers, router metadata, control labels | Compact and legible at ordinary window density |
| `type.ui.body` | Board rows, settings, consent, diagnostics | Primary reading role for native UI |
| `type.ui.title` | Panel and surface titles | Establishes hierarchy without display decoration |
| `type.ui.room` | Room identity in switcher and transition context | Distinct from state; never substitutes for a target label |
| `type.ui.data` | Host aliases, pane IDs, revisions, durations, key chords | Monospaced data role with tabular numerals |
| `type.ambient.primary` | Primary actionable ambient fact | Distance-legible; targets 7:1 contrast |
| `type.ambient.secondary` | Room, age, destination, counts | Supports the primary fact; never drops below large-text contrast floor |

The provisional implementation candidates are the system monospace family for grid/data and the system UI family for
chrome. These are not approved identity assets. User-selected terminal fonts affect the grid only.

### 19.2 Scale and metric contract

The semantic scale orders roles rather than fixing points:

`caption < label < body < title < room < ambient.secondary < ambient.primary`.

The implementation token file maps each role to face, size, weight, line height, and tracking for each UI
content-size category. The map MUST preserve this order, fit the acceptance fixtures in §25, and remain
owner-approved as one type asset. No component may insert a local type step.

Grid geometry derives from resolved font ascent, descent, leading, and advance. The renderer and accessibility
projection consume the same resolved metrics. Wide glyphs, combining marks, bold, italic, and color emoji MUST be
included in the metric probe. A font fallback MUST NOT silently change the width of an occupied terminal cell. The
resolved grapheme keeps its assigned one- or two-cell span, baseline, cursor, selection, copy, and accessibility
mapping. A fallback glyph is clipped to that span; when clipping would remove its identifying form, the renderer
uses the configured replacement glyph in the same span. It never overlaps an adjacent cell, scales the grid, or
changes advance. Missing-glyph fixtures receipt both the visual result and logical text.

Grid zoom changes the explicit terminal scale and publishes one coherent geometry generation. It preserves the
logical cursor and selection anchors. Dynamic Type does not silently change terminal rows or columns; §24 defines
its UI scope.

### 19.3 Text behavior

- UI copy uses sentence case. All caps is reserved for literal protocol text the
  user must copy exactly.
- Counts, durations, revisions, and aligned board columns use tabular numerals.
- Host, workspace, pane, and session labels preserve the distinguishing segment
  when truncated. The full value remains in the accessibility label and detail
  view.
- Primary actions and failure causes reflow before truncation.
- Terminal output is never typographically normalized by the UI system.
- Text weight is not the only distinction between states.

**OWNER-APPROVAL ASSET — typography:** default v1 grid/UI/data faces and non-ambient role sizes, line heights, tracking, and weight mappings become final only after DL-OQ-01 and the G1 Design Language review. Ambient literal metrics remain reserved to DL-OQ-09.

## 20. Color and materials

### 20.1 Semantic color tokens

The design system freezes names and roles. It does not manufacture a final palette in prose. Each token resolves
separately for light and dark appearance, high-contrast settings where supported, and active Room theme. Literal
color values require DL-OQ-02 and owner approval.

| Token | Role |
|---|---|
| `color.canvas` | Terminal-adjacent app background outside a grid |
| `color.surface` | Board, settings, and ordinary summoned chrome |
| `color.surface.raised` | Menus, popovers, and active transient controls |
| `color.surface.scrim` | Focus transfer behind a blocking native surface |
| `color.text.primary` | Primary Allward-owned text |
| `color.text.secondary` | Metadata, provenance, and freshness |
| `color.text.disabled` | Unavailable control text that still meets applicable contrast |
| `color.stroke.divider` | Structural dividers unrelated to Room identity |
| `color.stroke.keyboardFocus` | Keyboard focus indication independent of Room tint |
| `color.selection.native` | Selection in native UI; separate from terminal selection |
| `color.state.permission` | Permission or approval state |
| `color.state.needsInput` | Explicit user action required |
| `color.state.error` | Error or blocked state |
| `color.state.stale` | Retained but non-live state |
| `color.state.running` | Active work needing no action |
| `color.state.finished` | Completed transition |
| `color.state.idle` | Substate accent within `live` for inactive periods; not a first-class state |

Every visible `color.state.*` use is paired simultaneously with visible text and/or a distinguishable icon, shape,
or pattern. The accessibility label is additional; it cannot substitute for a visible non-color carrier. Room tint
is never a state color.

### 20.2 Room tint roles

Each Room selects one owner-approved base tint. The theme compiler derives roles; components never adjust the base
tint ad hoc.

| Token | Role |
|---|---|
| `room.tint.seam` | Highest-strength Room identity at window/tab/pane seams |
| `room.tint.wash` | Low-strength Room context on native chrome and board grouping |
| `room.tint.focus` | Room identity adjacent to, but not replacing, keyboard focus |
| `room.tint.board` | Room grouping and selected Room row treatment |
| `room.tint.router` | Room identity within router items and their finite pulse |
| `room.tint.ambient` | Distance-legible Room label and grouping in ambient mode |
| `room.tint.material` | Optional Room influence on approved chrome material |

Tint rules are fixed:

1. A v1 window has exactly one Room; every tab and pane inherits it. Mixed-Room
   windows and pane overrides are out of scope.
2. Tint changes chrome, seams, focus adjacency, board surfaces, router treatment,
   ambient grouping, finite motion, and optional material only.
3. Tint never modifies the selected terminal theme or the grid glyph/background
   planes. Imported ANSI colors remain user-authored terminal colors.
4. Room identity remains legible without hue through name, stable placement, and
   seam shape.
5. A tint collision or contrast failure falls back to safe neutral chrome plus
   the Room name; it never mutates the grid.
6. Room crossing commits the input-target label before its tint transition.

### 20.3 Appearance and contrast

Light and dark are independent token resolutions, not algorithmic inversion. The terminal grid follows its selected
theme; Allward-owned chrome follows the resolved UI appearance. If those differ, the seam separates them without a
blended wash over cells.

Final composited output MUST meet these floors:

- Allward-owned normal text: at least 4.5:1;
- large ambient text: at least 3:1, with 7:1 targeted for ambient primary text;
- non-text state marks, focus outlines, and actionable boundaries: at least 3:1.

Receipts measure final pixels, including material, tint, hover, focus, selected, disabled, stale, and degraded
states. Token-source arithmetic alone is not a contrast receipt.

Imported terminal palettes are preserved after a specific warning if they fail a terminal contrast check. Allward MUST
NOT clamp or silently rewrite them. Allward-owned overlays on such grids use safe UI tokens and remain legible.

### 20.4 Material, stroke, spacing, and radius roles

| Token | Role |
|---|---|
| `material.grid.opaque` | Default terminal surface; no blur or tint wash |
| `material.chrome.base` | Ordinary native chrome |
| `material.chrome.raised` | Summoned transient surface with clear focus transfer |
| `material.chrome.alert` | Permission/error emphasis without urgency effects |
| `stroke.roomSeam` | Room identity boundary |
| `stroke.paneDivider` | Split topology divider |
| `stroke.keyboardFocus` | Keyboard focus boundary |
| `space.inline.tight` | Icon-label and compact metadata relation |
| `space.inline.standard` | Ordinary control and row separation |
| `space.block.compact` | Pane header and router density |
| `space.block.standard` | Board and settings rhythm |
| `space.section` | Major native-surface grouping |
| `radius.control` | Interactive controls |
| `radius.panel` | Summoned native panels |
| `radius.grid` | Always square; no card treatment around the terminal |

### 20.5 Reduce Transparency mapping

When the system Reduce Transparency setting is active, every non-opaque material resolves to its opaque fallback.


| Token | Reduce Transparency mapping |
|---|---|
| `material.chrome.base` | Opaque `color.surface` with no vibrancy or blur |
| `material.chrome.raised` | Opaque `color.surface.raised` with no vibrancy |
| `material.chrome.alert` | Opaque `color.surface` plus `color.state.permission` or `color.state.error` stroke |
| `room.tint.material` | Omitted; Room identity uses `room.tint.seam` and name only |

Reduce Transparency fixtures verify dark/light appearance, Room tint, focus, stale/degraded, permission/error, and contrast under the opaque mapping. Receipts measure final-pixel contrast on the opaque surfaces. This §20.5 table is the sole Reduce Transparency token map; no parallel `color.material.*` opaque token family exists.

### 20.6 Increase Contrast mapping

When the system Increase Contrast setting is active, tokens resolve to higher-contrast alternates. Support is
platform-probe-determined: if the pinned target platform exposes Increase Contrast, this section is mandatory and
gated by G3; if the platform does not expose the setting, this section records that result and the hedge in §20.1 is
removed.

| Token category | Increase Contrast behavior |
|---|---|
| `color.text.*` | Resolve to maximum-contrast alternates against their backgrounds |
| `stroke.keyboardFocus` | Higher contrast and/or increased stroke weight |
| `color.state.*` | Maintain state distinction while meeting elevated contrast floors |
| `room.tint.*` | Increased saturation/contrast or fallback to named Room identity |
| Disabled controls | Maintain required contrast ratio even for disabled state |

High-risk pairs for Increase Contrast coverage:

- Focus indicator on all background types (canvas, surface, raised, Room-tinted)
- Disabled control text and boundary
- Selected/focused state on Room-tinted surfaces
- Stale/degraded labels on all backgrounds
- Permission and error states
- State marks adjacent to Room tint

Increase Contrast fixtures verify that focus, state, and disabled elements remain distinguishable and meet elevated
floors. The covering array in §25.2 includes Increase Contrast as a dimension when platform support is confirmed.


Literal material recipes, stroke widths, spacing values, and radii live in the versioned token manifest. Decorative
gradients, glow fields, permanent glass, and nested card materials are outside the language. The opaque grid is the
baseline.

**OWNER-APPROVAL ASSET — color and material:** the v1 light/dark/Increase Contrast palette, Room tint derivation, material recipes, and foundational spacing/stroke/radius scale become final after DL-OQ-02 and the G1 Design Language review. Board presentation/density remains DL-OQ-05; ambient palette/density remains DL-OQ-09.

## 21. Motion grammar

### 21.1 Motion meanings and tokens

Motion communicates state change, target change, or user-invoked spatial change. It never decorates output,
simulates urgency, or masks latency. Every motion is finite, damage-bounded, and named here. Nothing loops or
bounces. The terminal grid never translates, scales, springs, or smoothly interpolates TUI output.

Duration and curve tokens freeze semantic intent, not literal timing or curve assets.

| Token | Meaning |
|---|---|
| `motion.duration.immediate` | Input target, cursor, permission availability, and Reduced Motion state commit |
| `motion.duration.quick` | Local control, icon, and focus-state change |
| `motion.duration.standard` | Attach chrome and todo state change |
| `motion.duration.context` | Room chrome/material transition |
| `motion.duration.emphasis` | One-shot router emphasis |
| `motion.curve.state` | Non-spatial state interpolation |
| `motion.curve.context` | Restrained chrome/material context interpolation |
| `motion.curve.emphasis` | One-shot outline emphasis; never spring or elastic |

### 21.2 Named transitions

| Name | Trigger | Default motion | Stable end state | Reduced Motion |
|---|---|---|---|---|
| `attach` | First coherent content from the selected content route | Room seam/material resolves using `standard/state`; grid commits atomically with no transform | Live content plus provenance; or named fallback state | Immediate seam and content commit |
| `room-crossing` | Confirmed input-target change between Rooms | Destination label commits first; chrome tint/material interpolates using `context/context`; grid frame does not move | Destination Room name, tint, and locked target | Immediate token swap; no content crossfade |
| `todo-tick` | Open loop becomes complete | Icon and text state change using `quick/state`; row holds before deterministic board reflow | Completed row or recorded removal | Immediate icon/text change and immediate reflow |
| `router-pulse` | A new router-owned `actionable_epoch_id` begins | One outward outline emphasis using `emphasis/emphasis`; never repeats for updates under that ID | Static needs-input treatment | No pulse; static needs-input treatment appears immediately |
| `chrome-summon` | User opens board, palette, detail, or settings | Native surface opacity/material and approved bounded geometry using `quick/context` | Focus and input route follow §23.1; no ambiguous terminal keystrokes | Immediate surface appearance and focus transfer |
| `stale-mark` | A live record becomes stale | No spatial motion; label, icon, and tone change using `quick/state` | Retained last-known value with stale provenance | Immediate state change |

Attach failure never loops a shimmer. Room crossing never implies a carousel. Todo completion never bounces adjacent
rows. Repeated updates do not restart a router pulse within the same router-owned `actionable_epoch_id` defined by `SPEC.md` §8. Acknowledgment or leaving actionability closes that ID; only a later ID may pulse. Stale, Focus-denied, and ambient-hidden items do not pulse.

### 21.3 Reduced Motion

When the system Reduced Motion setting is active, Allward maps every non-immediate transition to an immediate state
change. It removes translation, scale, spring, outline expansion, animated reflow, content crossfade, and repeated
pulse. It does not replace them with long fades. Text, icon, focus, destination, freshness, and provenance remain
complete.

Reduced Motion MUST reduce render work: each named transition performs one state commit and produces zero later
frames attributable to motion. Default attach and Room transitions damage chrome/material only, never `gridFrame`;
todo and router motion damage only their component bounds. A motion trace records affected bounds, frame count,
completion time, and post-completion idle frames. Motion is not required for cursor, selection, terminal output,
accessibility focus, or target confirmation.

**OWNER-APPROVAL ASSET — motion:** literal durations, curves, travel bounds, and the perceived feel of all six named
transitions require DL-OQ-03 and owner approval. The no-grid-transform and Reduced Motion rules are settled and are
not part of that approval.

## 22. Sound

### 22.1 Four-earcon vocabulary

The initial family has exactly four semantic events. A UI change may map to one of them or remain silent; adding a
fifth event requires a prior Design Language revision.

| Earcon | Event | Visible pairing | Suppression |
|---|---|---|---|
| `needs-input` | A permission or explicit user action becomes actionable | Router/header state with action verb, source, and destination | Same `actionable_epoch_id` already sounded; stale; denied Room; Room/event disabled |
| `finished` | User-addressed work completes | Finished state and inspectable result/source | Background completion outside enabled policy; duplicate transition |
| `error` | Work or a connection enters an actionable blocked/error state | Error mark, cause, target, and recovery action | Non-actionable diagnostic; duplicate transition; stale retained error |
| `digest-ready` | A meaningful unseen event boundary produces a re-entry digest | Digest-ready surface and `allowed_unseen_event_count` | Digest already visible/acknowledged; no unseen meaningful change |

`digest-ready` means the re-entry digest in `SPEC.md` §8, not a future notification-digest feature.

One normalized transaction plays at most one earcon. Candidate eligibility comes only from the composed usability result and the technical `SurfaceEligibilityReducer`, never directly from a permission/event record. Applicable terminal error suppresses `needs-input` and selects `error` recovery sound when the reducer marks that recovery actionable; stale, unavailable-control, and explicit/cancelled-close results suppress `needs-input` and produce no replacement sound unless the reducer independently selects another eligible semantic event. After Room/Focus/duplicate gating, arbitration is `error` → `needs-input` → `finished` → `digest-ready`; the first eligible event wins. A finished event that also makes a digest ready plays `finished`; the passive digest-ready state remains visible without a second sound.

### 22.2 Mechanics

Sound is globally off by default. Playback requires all of: global sound enabled, the event enabled for the resolved Room, current Focus permission, a new semantic event identity, composed usability compatible with that event, and the matching delivery eligibility from `SurfaceEligibilityReducer`. `needs-input` requires `usable-action-capable`; `error` requires selected actionable recovery; `finished` and `digest-ready` require their exact reducer-selected transitions. Stale, closed, or unavailable-control state never passes through a raw permission candidate.

Earcons are brief, non-speech, volume-consistent, and non-startling. They contain no Room name, host name, terminal
text, transcript, or other user content. A Room may choose events and enablement, not a different semantic sound for
the same event. Preview playback in settings does not create or acknowledge product state.

Earcons never replace visible state, VoiceOver announcements, keyboard focus, or router order. Sound-off is a
complete path. No launch sound, keyboard sound, ambient loop, reconnect sound, dictation tick, or idle audio engine
ships in the initial vocabulary.

Playback failure is silent in the active workflow and appears as a specific settings diagnostic. It does not retry
in a loop or substitute another earcon.

**OWNER-APPROVAL ASSET — sound:** all four v1 audio files, timbre, envelope, pitch, duration, relative loudness, and sensory character require listening approval in DL-OQ-04 before G3. The four semantic names, globally-off default, settings preview/diagnostic path, and per-Room/event gating are settled v1 requirements.

## 23. Spatial system

### 23.1 Grid and chrome invariants

The grid occupies every terminal `gridFrame`. Native chrome stays outside that frame or appears in a layer whose
focus transfer does not change terminal rows, columns, or cell coordinates. A surface that covers terminal content
MUST move input focus out of the terminal and identify that transfer; no translucent control may sit over an active
cursor while keys still reach the pane.

A single-pane healthy window shows the minimum Room seam and window/tab identity. A split topology establishes
persistent header bands as part of one coherent geometry transaction. Hover, focus, attention, recording, stale, and
fallback changes may populate those established bands or outer chrome but MUST NOT resize the grids. Pane dividers
remain structural seams, not card borders.

Toolbar capacity is limited to Room selection, board summon, router count, attach/teleport, and settings.
Diagnostics, consent, and configuration use native summoned surfaces. Controls MAY collapse by priority at compact
widths; the grid does not surrender columns to preserve every toolbar label.

#### 23.1.1 Summoned-surface focus and input — exhaustive table

This table is the sole canonical authority for summoned-surface focus, input routing, and restoration. `SPEC.md` §8
references this table rather than defining its own focus rules. Every summoned surface has exactly one row; missing
rows are implementation errors, not undefined behavior.

| Surface | Initial focus element | Terminal input during | Dismissal restoration | Accessibility announcement |
|---|---|---|---|---|
| Board overlay | Board title AX heading; next order is first row/action | Suspended | Exact invoking AX element, pane selection, and input target; safe non-input chrome if gone | `Board, <exact count> items` |
| Board side sheet | Board title AX heading; next order is first row/action | Suspended | Exact invoking AX element, pane selection, and input target; safe non-input chrome if gone | `Board, <exact count> items` |
| Detached board window | Board title AX heading; next order is first row/action | Other windows keep locked targets but receive no keys while unfocused | Exact invoking AX element, pane selection, and locked input target when present; safe non-input chrome otherwise | `Board window, <exact count> items` |
| Router strip | Never focusable; a separate toolbar/menu command may focus | Never interrupted | Not applicable | Router command retains toolbar/menu semantics; strip emits no focus transfer |
| Re-entry digest | Digest title AX heading; next order is first deterministic fact, then action | Suspended | Exact invoking AX element, pane selection, and input target; safe non-input chrome if gone | `Digest, <allowed_unseen_event_count> changes` |
| Command palette | Query field | Suspended except declared global shortcuts | Exact invoking AX element, pane selection, and locked input target without submitting text; safe non-input chrome if gone | `Command palette` |
| Detail panel | Detail title AX heading; next order is first action | Suspended | Exact invoking AX element, pane selection, and locked input target; safe non-input chrome if gone | Detail title |
| Diagnostics | Diagnostics title AX heading; next order is first action | Suspended | Exact invoking AX element, pane selection, and locked input target; safe non-input chrome if gone | `Diagnostics` |
| Settings window | Settings title AX heading; next order is first control | Other windows keep locked targets but receive no keys while unfocused | Exact invoking AX element, pane selection, and locked input target; safe non-input chrome if gone | `Settings` |
| Permission/consent | Least-destructive button | Suspended; Return cannot imply approval unless that explicit control is focused | Exact source AX element, pane selection, and locked input target; safe non-input chrome if gone | Permission subject and ordered action options |
| Concierge installer | Least-destructive button | Suspended | Exact source AX element, pane selection, and locked input target; safe non-input chrome if gone | `Install` or `Uninstall`, plus target |
| Error detail | Error-summary AX heading; next order is first recovery action | Suspended | Exact source AX element, pane selection, and locked input target; safe non-input chrome if gone | Error summary |

**Invariants:**

- The router strip itself never takes focus or suspends terminal input.
- While any summoned surface is active, test input MUST reach only its declared target.
- Every blocking surface records the invoking AX element, pane selection, and locked input target before focus moves. Dismissal restores all three only while all remain valid.
- If any recorded element, pane, or target closed, dismissal clears the saved pane selection/input lock and focuses the window's safe non-input chrome; it never partially restores or selects a different terminal pane.
- Every row has a sentinel-keystroke gate receipt: while the surface is active, test input MUST reach only the declared target.
- Escape always dismisses without destructive action and applies the exact-or-safe restoration rule above.
- Focus-transfer announcements are delivered on summon; restoration announcements name the target.


### 23.2 Pane headers

A header presents, in reading order:

1. Room identity seam/name where the window context is not otherwise clear;
2. user-facing session name;
3. host, workspace, and pane identity;
4. agent state or shell-region capability;
5. stale, content-route fallback, disconnect, or dictation state;
6. destination key when the router points to this pane.

Single-pane healthy views MAY keep identity in outer chrome and summon detail on keyboard focus or pointer intent.
Headers remain persistent when split topology creates multiple possible input targets, when state is stale/degraded,
while dictation is locked, or when a permission/action is routed there. Persistence changes content in a reserved
header band; it does not move the grid.

The header never shows model-generated urgency, unverified token counts, fabricated progress, or a capability
inferred from compositor pixels.

### 23.3 Terminal and adapter surface states

Local and direct-SSH terminals are complete primary routes. They do not inherit fallback labels or adapter
requirements. Optional herdr sessions use the exact content-route ladder from `SPEC.md` §5. Presentation
MUST name any non-primary route and MUST NOT imply capabilities that route has not proved.

| Route/state | Surface treatment | Input treatment | Required label and action |
|---|---|---|---|
| Loading first coherent frame | Stable empty `gridFrame` with target and current bounded attempt; no spinner loop | Input disabled until route and target are acknowledged | Cancel; on bound enter route-specific stale/degraded/error state |
| Local PTY | Complete Developer ID terminal surface | Ordinary terminal input, including locked STT insertion without Return | Normal local provenance in detail; no adapter or fallback badge |
| Direct SSH PTY | Complete remote terminal surface | Ordinary terminal input, including locked STT insertion without Return | Host/session provenance in detail; no multiplexer or fallback badge |
| Full remote herdr client | Primary route for an explicitly configured herdr workspace after OQ-03 qualification (`G2-herdr-adapter`) | Interactive only after exact target focus is acknowledged | Normal herdr provenance in detail; no fallback badge |
| Per-agent `herdr agent attach` | Known agent pane only | Interactive only if the separate bidirectional probe passes | Persistent `Agent-only attach`; action to return to workspace route |
| `pane.read` snapshot | Rendered recovery snapshot fetched only on open, focus, reconnect, manual refresh, or verified relevant event | Read-only | Persistent `Read-only snapshot — not live`; captured-at freshness bucket, source, revision/truncation state, manual refresh with declared bound |
| Ordinary SSH terminal running herdr | Interactive herdr TUI without native control-plane synchronization | Ordinary terminal input | Persistent `Native herdr board and teleport unavailable`; reconnect optional control plane action |
| Disconnected/stale | Last coherent frame retained | Input disabled; no queued-input exception exists | `Disconnected — last received …`; reconnect state and diagnostics |
| Route error | No coherent content for the selected local, SSH, or adapter route | No fallthrough input | Failed route, exact Room/session/pane, route-specific retry or alternate action |
| No session | No target exists | No input destination | `No sessions yet`; create local terminal (Developer ID only), connect SSH, or choose a configured adapter |

For an explicitly configured herdr session, the fallback order is exact: full client, proven agent-only attach,
read-only `pane.read`, then ordinary SSH herdr without native synchronization. No periodic pane polling, screen
scraping, raw inner OSC 133 claim, or silent route change is allowed.

The fallback ladder never appears in plain local or direct-SSH flows. A failure of an optional herdr control plane
cannot downgrade an unrelated terminal, Room, STT path, MCP operation, theme, or accessibility projection.

Snapshot honesty: a snapshot route is stale by definition. It presents retained read-only content with captured-at freshness, provenance, and revision/truncation state; refresh happens only on the listed triggers, each under a declared bound, never periodically. A snapshot surface never presents `live`, never arms live actions, and never satisfies a live-route claim: attach-latency demonstrations, live board/focus synchronization, teleport confirmation, and the selected-live-route rows in `SPEC.md` §16 are satisfiable only by a live interactive route. Copy MUST NOT imply currency; the freshness bucket stays visible for the life of the snapshot view.

Fallback qualification is per signed product: whenever a signed product ships the four-route herdr ladder, that product's own passing `G2-herdr-ordinary-ssh` receipt — launch, input targeting, resize, reconnect, the exact persistent `Native herdr board and teleport unavailable` label, and the negative native board/focus/teleport claims — is a design-gate requirement regardless of which route that product selects at qualification time. The persistent disclosure ships only in the wording its receipt exercised; §25.3 item 17 rejects a bundle claiming this ladder without the receipt for each signed product.

### 23.4 Session board

The board is a native summonable surface, never a terminal pane. It aggregates local, direct-SSH, and adapter-backed
sessions plus whatever publisher records exist. It groups by Room, then host/workspace, and uses aligned columns for
state, session identity, open-loop count, freshness, and destination. Board row order follows the total comparator and eligibility output in `SPEC.md` §8; unrelated Rooms do not reorder when one item changes.

Sessions without publishers remain ordinary session rows. Publisher-derived todos and agent state are additive
columns/details, not admission requirements. An empty publisher set MUST NOT produce an integration warning or herdr
CTA.

Keyboard actions cover Room jump, next actionable item, details, acknowledge, and teleport. Teleport shows and locks
the exact destination before terminal input resumes. The presentation choice among overlay, side sheet, and
detachable window is probe-gated by DL-OQ-05. Every candidate MUST preserve the grid frame, explicit focus transfer,
and keyboard path.

| Board state | Required content | Primary action |
|---|---|---|
| Loading | Room/connection target and current inventory step; existing terminals remain usable | Cancel or inspect the affected connection |
| Empty: no sessions | Room name and `No sessions yet` | Create local terminal (Developer ID only), connect SSH, or choose a configured adapter |
| Empty: no published open loops | Session counts and `No open loops published` | Show all sessions; no integration required |
| Zero publishers | Complete local/direct-SSH session rows with publisher columns absent, not disabled | Open or focus session |
| Populated | Stable grouped rows, exact state, provenance, freshness, destination | Next actionable / teleport |
| Stale/degraded | Retained rows with per-source stale or capability label; unaffected sessions stay live | Reconnect or inspect only the affected source |
| Permission | Request verb, requesting publisher, target, expiry when supplied | Review; never implicit approve |
| Error | Failed board source or operation without erasing retained rows | Retry source / diagnostics |
| Maximum content | Bounded visible rows, deterministic navigation, no count truncation | Search/filter/next actionable |

#### 23.4.1 Local acknowledgment and publisher decisions

Local router acknowledgment and a publisher-backed permission decision are different operations and MUST use different labels, receipts, and state. `Acknowledge locally` closes or demotes only Allward's router attention epoch; it never sends an approval, mutates publisher state, or changes permission to `granted`. Publisher option buttons appear only when composed usability is `usable-action-capable` and `SurfaceEligibilityReducer` marks the exact decision actionable.

Publisher-backed permission UI consumes only the technical `PermissionDecisionTransaction` in `SPEC.md` §6. No visible or accessibility decision state may derive from transport delivery events, terminal output, publisher frames outside that transaction, or local inference. `committed` alone renders `granted`; `accepted` is in-flight; `acknowledged` confirms delivery of a final outcome and is distinct from both commit and local router acknowledgment.

| Decision/UI state | Required presentation | Action rule |
|---|---|---|
| Local router acknowledgment available | `Acknowledge locally`; local-only explanation in accessible help | Never styled or announced as approve/allow; receipt names only local router epoch |
| Publisher decision ready | Exact publisher option verbs, publisher, Room/session/pane target, and expiry when supplied | One option dispatch; target/generation locked; separate local acknowledgment remains visibly distinct |
| Dispatching | `Sending <decision> to <publisher>` with exact target; no success copy | Option controls disabled; cancel only while the `PermissionDecisionTransaction` remains cancellable |
| `accepted` | `Decision accepted — awaiting publisher commit` | No redispatch; no `granted` state, approval success announcement, or success earcon |
| `committed` | `Decision committed` plus publisher effect receipt and exact target | This is the only publisher-backed transition that may render permission `granted` |
| `rejected` | `Decision rejected by publisher` plus supplied reason and safe retry/review path | No grant; reducer-selected error/denied recovery only |
| `cancelled` | `Decision cancelled — not committed` | No grant; return to current publisher permission state only if a fresh actionable record remains |
| `acknowledged` | `Publisher acknowledged <final outcome>` with correlated receipt | Acknowledgment confirms delivery only; it cannot promote accepted/rejected/cancelled to committed or `granted` |
| Outcome unknown / response loss | `Decision result unknown — checking publisher` with transaction/target detail | No redispatch, grant, or optimistic success; recovery is the transaction's lookup-only outcome retrieval, presented as the recorded outcome or still unknown; the UI never offers a redispatch action for an unknown outcome |
| Stale/error/closed during decision | Composed stale/error/empty presentation and retained transaction receipt | Approval controls and approval speech removed; only reducer-selected recovery remains |

Visual and accessibility values update from the same `PermissionDecisionTransaction` generation. A publisher commit arriving for a stale target/generation is never shown as current granted state, and any transaction outcome carrying a wrong target or non-current generation leaves every current record's visible state unchanged — it lands only in the transaction receipt. G1 publisher-action receipts exercise accepted→committed, accepted→rejected, cancellation before commit, acknowledgment of each final outcome, response loss, stale generation, and wrong target.

#### 23.4.2 Credential rotation, revocation, and authority-loss presentation

Rotation and revocation present with exact-target isolation. The visible effect of rotating or revoking a publisher credential attaches only to the records, streams, and pending decisions of the exact targets that `SPEC.md` §5 places in that transaction's scope. A neighbor Room, session, pane, or target never changes visible state, freshness, or actionability because a different target rotated; fixtures pair one affected target with one unaffected neighbor and assert the neighbor's presentation and accessibility values are identical before, during, and after.

A rotation or revocation with unknown outcome presents on the affected targets only: `Rotation result unknown` with the affected target set and a lookup-only recovery path. It never presents as publisher-wide stale, never marks unrelated targets, and never shows old and new authority as simultaneously valid; recovery presents the one authoritative post-recovery credential state supplied by `SPEC.md`, and the UI offers no action that could dispatch a second rotation while the first is unknown.

There is no new credential UX. Surfaces, diagnostics, exports, and receipts show only the references or fingerprints `SPEC.md` §14 permits — never secret material, tokens, audiences, or nonces. Authority loss after an MCP server, launcher, or channel replacement follows the same rules: the retired grant presents as ended authority — non-actionable and visibly invalid — and the recovery surface is lookup-only: it may retrieve and present a recorded outcome or `outcome_unknown` for a prior invocation, and it never offers redispatch of that invocation.

### 23.5 Attention router

The v1 router is a glanceable strip outside the terminal `gridFrame`. It never covers an input cursor and never
changes grid geometry when counts update. Its compact form shows the highest-priority class, total actionable count,
Room identity, freshness, and one destination key. Expanded detail is the board, not a nested card strip.

| Router state | Required presentation |
|---|---|
| Loading | Target/source and bounded first-value attempt; distinct from authoritative zero; on bound enter degraded/error |
| No actionable items / zero publishers | Quiet zero state or absent strip; a persistent Board command with visible shortcut and accessible key equivalent remains in the app menu/toolbar; no adapter CTA |
| Needs input | Explicit action class, count, Room, destination; one `router-pulse` per new epoch |
| Error selected by `SPEC.md` §8 | Present the reducer-selected error class; cause and recovery remain available in detail |
| Stale only | Stale count and source; no pulse or earcon |
| Focus-filtered | Allowed count only plus inspectable indication that policy filtered other Rooms; no hidden urgency |
| Degraded source | Count provenance and capability limit; never merged as equivalent to rich publisher state |
| Maximum content | Aggregate by class/Room; compact count may abbreviate visually, while accessible value and board detail retain the exact total; long targets preserve distinguishing text without marquee or auto-scroll |

**1.x reserved contract — menu-bar count:** The menu-bar count is a compact projection of the same immutable router generation. Zero publishers/actionable items show no count; Focus-filtered data uses the allowed count; stale-only data uses a stale mark rather than an actionable badge; degraded data identifies its source in the menu; overflow may abbreviate visually while the accessible value and menu detail retain the exact total. This contract is reserved for 1.x; it is not a v1 implementation or G1/G2/G3 gate requirement.

Cross-surface comparison uses this versioned projection schema:

| Surface | Required exposed fields | Optional/omitted-field path |
|---|---|---|
| Pane header | Session/target; Room when not otherwise fixed; live/stale/degraded; routed class and destination when this pane is routed | Aggregate count stays in router/board; source detail opens from header |
| Router strip | Actionable count, highest class, Room, freshness, one destination | Remaining targets and provenance open in board |
| Menu-bar projection (1.x) | Actionable count or stale/degraded mark; accessible state value | Class, Room, target, destination, and provenance open in its menu/board command |
| Board | Count, class, freshness, Room, source target, destination, and provenance | No required router field omitted; row detail may expand long values |
| Ambient view, when implemented | Count, class, freshness, Room, and destination for shown items | Full target and provenance open in board |

The gate compares each rendered and accessibility-exposed field with the same normalized generation, checks that omitted fields are reachable through the declared detail path, and rejects extra fields prohibited by privacy or Focus policy. It does not require compact surfaces to render every board field.

### 23.6 Re-entry digest

A meaningful unseen state change makes a digest ready; elapsed time alone does not. Readiness may expose only a passive, non-blocking indicator and the Focus-gated announcement below. The blocking digest surface opens only by user action, then follows §23.1 focus/input rules. It starts with deterministic facts and source links; optional model wording cannot hide them.

`allowed_unseen_event_count` is the sole digest count: the number of meaningful unseen normalized source events remaining after current Focus filtering in one reducer generation. Facts may expand one event into several lines, but every digest surface, earcon pairing, and announcement uses this event count.

| Digest state | Required presentation |
|---|---|
| Preparing | The only digest `loading` presentation: `allowed_unseen_event_count` visible, bounded preparation attempt, cancel when supported; on bound show source-specific error while retaining available facts |
| Rewriting (optional) | A `live` substate that begins only after deterministic facts are ready; facts remain visible/actionable; bounded attempt falls back to facts-only without returning to Preparing |
| Focus-filtered | Allowed-Room facts and `allowed_unseen_event_count` only, plus `Filtered by Focus`; explicit navigation to retained source detail remains readable |
| Absent / no eligible unseen facts | No meaningful unseen change from any normalized source; no placeholder card, warning, or integration CTA |
| Ready, deterministic | Ordered facts, Room/session targets, source links |
| Ready, rewritten | Bounded prose plus direct access to the same source facts |
| Intelligence unavailable | Deterministic digest unchanged; no error banner |
| Source stale | Facts retained with source freshness and stale reason |
| Partial source error | Available facts plus named missing source; no invented completion |
| Acknowledged | Leaves the active re-entry position but remains in bounded history per `SPEC.md` |

`Preparing` is the sole digest loading state. `Rewriting` never hides facts, disables actions, changes reducer state, or creates a second preparing path.

### 23.7 Ambient board

The ambient board is a 1.x second-display or unfocused-window presentation of the same router model. Its semantic roles, state model, and grid-stability rules are fixed now; literal type metrics, palette, density, card cap, and final presentation belong only to reserved DL-OQ-09. Implementation and capture are absent from v1 G1/G2/G3.

It presents one primary actionable fact per row/card with Room, state verb, age or freshness when relevant, and
destination key. It omits terminal output, commands, transcripts, permission detail, and Focus-denied Room content.
The background is static. Only the finite `router-pulse` may animate, and Reduced Motion removes it.

| Ambient state | Required presentation |
|---|---|
| Loading | Bounded source attempt and target; distinct from no-action; on bound enter source-specific degraded/error |
| Actionable | Highest-priority items in stable order plus allowed-Room counts |
| No action needed | Allowed live/stale counts and last acknowledged completion; no motivational copy |
| Stale/degraded | Explicit stale/degraded labels and source; no sound or pulse |
| Focus-filtered | Only allowed Rooms; visible policy state without revealing hidden content |
| Error | Ambient source failure and route back to the in-app board |
| Maximum content | Bounded list plus remaining count; no auto-scroll or rotating carousel |

The exact card cap, distance type, palette, and density remain in reserved DL-OQ-09. The 2560×1440 fixture applies only after ambient implementation begins or to an explicitly ambient-only prototype; it is absent from v1 G1/G2/G3 bundles.

### 23.8 Dictation states

Push-to-talk presentation is honest about acquisition: the interface never claims listening before capture truly runs. Every state below names the locked destination from `SPEC.md` §10. Focus, VoiceOver, and Reduced Motion behavior are deterministic per state: no dictation state pulses, loops, or animates under Reduced Motion; recording state stays visible without sound; keyboard focus never moves as a side effect of a dictation state change, and the composer takes focus only when it appears, restoring per §23.1.1. Partial or final transcript text appears only inside the locked composer — never in headers, announcements, logs, diagnostics, or any other surface.

| Dictation state | Required presentation | Exit rule |
|---|---|---|
| Checking access | `Checking microphone and speech access` with the locked target; no listening or captured-audio claim | Bounded; resolves to listening, denied, or unavailable; release or Escape during checking captures nothing |
| Denied | `denied`: names the denied permission (microphone or speech) and its System Settings path | Non-actionable until policy changes; no retry loop, no capture |
| Unavailable | `disabled` control substate: speech model/assets unavailable with the exact reason and any asset action | No listening claim; typed text input remains complete |
| Acquiring | Bounded analyzer acquisition after authorization | Acquisition failure presents `error` with typed cause; never a silent return to ready |
| Listening | Recording indicator plus locked Room/session/pane target | Ends by release (finalizing), analyzer final callback (transcript ready), Escape (cancelled), or interruption |
| Interrupted | Names the interruption: input route lost, device change, or system interruption | Capture ends immediately; a retained partial goes to the composer; otherwise explicit `No transcript captured` |
| Finalizing | Bounded finalization after release | Failure presents `error`; a retained partial goes to the composer; otherwise explicit `No transcript captured` |
| Cancelled | `Dictation cancelled — transcript discarded` | No injection; discarded artifacts follow the §24.7 retention states |
| Transcript retained | Composer bound to the locked destination with copy, retry, and discard | Destination closed/stale/generation-changed sends nothing; retry revalidates the exact original target only |
| Injected | Ordinary input insertion at the locked destination; never Return | Returns to ready; no success ceremony |

An adapter disconnect or route/lease generation change during any state ends capture or blocks injection through `SPEC.md` §10 revalidation and presents the transcript-retained or no-transcript state — never silent discard, never injection into a different pane. Dictation end states announce through the §24.2.1 dictation rows; payloads carry target and typed cause, never transcript content.

### 23.9 Concierge shell-integration lane

The v1 shell-integration lane is zsh only, by evidence. Setup is a consented transaction presented through the §23.1.1 concierge surface: the plan view shows the exact single line to be added and the exact file it lands in before consent; dry run is available; nothing edits a shell rc file silently or as a side effect of another action. Removal shows the same exact line and file and removes only the recorded owned line. Reapply and re-removal are idempotent and say so rather than claiming new work.

| Lane state | Meaning | Required presentation |
|---|---|---|
| Not installed | No recorded shell-lane entry for this host | Offer appears only after `SPEC.md` §6 detects a supported remote interactive zsh for the exact host/account; no harness detection is required; no warning badge |
| Installed | Recorded owned rc line present; publications not yet observed | `Installed — awaiting first shell session`; recipe version and owned file/line inspectable |
| Active | Recorded install plus live lane-1 shell publications with current freshness | Normal shell-region capability in the pane header; no badge ceremony |
| Stale | Recorded install whose recipe version, owned content, or observed publications no longer match (`SPEC.md` §6 conflict/damaged state or lane silent) | Exact mismatch named — `recorded v2, expected v3`, `owned line changed`, or `no publications this session`; recovery is the §6 plan/upgrade/repair path, never a silent reinstall |
| Unsupported shell | Detected shell has no supported recipe (Bash, fish, and others pending probes) | `Shell integration is not yet supported for <shell>` — no toggle, no fake install path, no degradation badge; the pane remains a complete lane-0 terminal |

These presentation states derive from the `SPEC.md` §6 shell-installer states plus normalized lane-1 freshness; this section adds no second state machine. Bash and fish MUST NOT be presented as supported, togglable, or imminent until their probes pass and a recipe version exists. Command regions, cwd, exit status, and shell freshness are claimed in UI only for panes whose lane is Active.

The design gate requires real-shell receipts in each signed product: a consented one-line setup on a real remote zsh host; visible A/B/C/D command regions with cwd, exit status, and freshness; survival across reconnect; idempotent reapply; and verified removal restoring the user's file. Wire-valid fixture frames do not satisfy this requirement.

## 24. Accessibility

### 24.1 Terminal-grid projection mechanism

The terminal engine publishes immutable logical state to two consumers: Metal and `TerminalAccessibilityProjection`.
The projection does not inspect the drawable. It receives the same snapshot generation, stable logical-line
identifiers, grapheme offsets, cursor, selection, visible range, scroll position, and terminal mode used to
construct the visual frame.

The projection exposes only parser-produced terminal output. Locally sent input MUST NOT be projected, logged, or
captured before the remote host echoes it. This rule applies regardless of terminal echo mode or inferred password
prompts; there is no authoritative remote secure-input signal, and inferring one risks either redacting ordinary
output or leaking secrets.

The terminal surface projects a text-area parent with lazily materialized logical line children. Materialization is
limited to visible lines plus a bounded navigation margin. Additional scrollback lines materialize on accessibility
navigation or scroll action and are released outside the bound. This prevents a large scrollback buffer from
becoming an equally large AppKit element tree.

Each projected line maps accessibility character offsets to `(logicalLineID, graphemeOffset)` rather than screen
coordinates. Reflow changes geometry while preserving logical text, cursor, and selection anchors. Alternate-screen
entry switches the projected screen generation; exit restores the primary projection. Wide and combining glyphs
remain one grapheme-level navigation unit.

The projection exposes, through the exact macOS 26 interfaces selected by DL-OQ-06:

- logical text and line boundaries;
- cursor/insertion location and visibility;
- selected text and selection range;
- visible character/line range and scroll position;
- line, page, top, bottom, and selection scroll actions;
- grounded links, command regions, prompts, permission actions, and router
  destinations when their source model proves them;
- role, label, value, hint, action, and deterministic focus order for native
  board, router, digest, consent, Room, and settings surfaces.

Locally sent input (before echo) is never exposed, logged, or captured. This rule replaces any assumed
"secure-input state" signal. Accessibility logs, snapshots, videos, and crash artifacts apply the same privacy
rule.

### 24.2 Change and announcement policy

Terminal damage marks affected logical lines dirty in the projection. The projection coalesces one output burst into
a bounded update after the coherent snapshot arrives; it does not announce per byte, glyph, frame, or cursor blink.
Cursor movement and selection changes emit their own semantic updates. Resize publishes only the new coherent
geometry generation.

#### 24.2.1 Announcement matrix

This matrix is the exhaustive v1 announcement policy. Every row defines trigger, payload, acknowledgment/end, delivery-time Focus recheck, and suppression; implementations MUST NOT add a `when relevant` branch outside it. Announcements never rely on an earcon. Exact APIs and coalescing bounds remain gated by DL-OQ-06.

A state-lane row becomes eligible only when composed usability permits it and `SurfaceEligibilityReducer` selects the matching semantic delivery. Raw permission/action state cannot enqueue speech. Applicable terminal error selects only error-recovery speech; stale may enqueue the stale row but cancels approval speech; unavailable control and explicit/cancelled normal close enqueue no approval/state action speech.

| Trigger | Payload | Priority | Replacement/dedupe | Acknowledgment/end | Delivery-time Focus | Suppression |
|---|---|---|---|---|---|---|
| Permission becomes active | Target, permission type, ordered publisher actions; local acknowledgment separately labeled | High | Replace same target/permission within 2s | Explicit decision or local acknowledgment as distinct outcomes | Recheck Room and reducer eligibility before delivery | Source not `usable-action-capable`; control unavailable; stale/error/closed; dismissed/granted/denied before delivery |
| Non-permission needs-input transition | Target, exact required action | High | Replace same target/action within 2s | Action completion or explicit acknowledge | Recheck Room and reducer eligibility before delivery | Source not `usable-action-capable`; control unavailable; stale/error/closed; action ended; permission uses row above |
| Error transition | Target, failure, reducer-selected recovery; never approval options | High | Replace same target/failure within 5s | Resolution; closing detail does not clear error | Recheck Room and reducer eligibility before delivery | Error resolved or recovery no longer eligible before delivery |
| Live to stale | Target, stale reason, last-received bucket; no approval options | Medium | One per record transition; replace same target within 10s; cancel queued approval speech | Live restoration; manual acknowledge never makes stale live | Recheck Room and reducer eligibility before delivery | Restored before delivery |
| Reconnect attempt starts | Target, bounded attempt number | Low | Replace same target within 30s | Connected, cancelled, or terminal failure | Recheck Room before delivery | Attempt ended before delivery |
| Stale to live | Target | Low | One per transition; replace same target within 2s | One-shot after delivery | Recheck Room before delivery | None |
| Finished transition | Target, completion/result kind | Medium | One per semantic event identity | Digest/event acknowledgment does not erase result history | Recheck Room before delivery | Duplicate or Focus-denied before delivery |
| Digest becomes ready | `Digest, <allowed_unseen_event_count> changes` | Medium | Replace same digest generation; never repeat after visible/acknowledged | Opening or acknowledging that digest generation | Recompute allowed count and recheck every included Room before delivery | Count becomes zero, already visible/acknowledged, or denied before delivery |
| Dictation lock acquired | Exact target | Medium | Replace same lock within 2s | Lock release | User-invoked; no Room-content suppression | Lock released before delivery |
| Dictation lock released | Exact target | Low | Replace same lock within 2s | One-shot after delivery | User-invoked; no Room-content suppression | None |
| Dictation ends without injection | Exact target, typed cause (denied, unavailable, analyzer failure, interrupted, cancelled, finalization failure, destination lost, injection rejected, or injection outcome unknown), and the exact `SPEC.md` §10 retention result; cancellation always says `transcript discarded`/`no transcript captured`, while only causes that retain nonempty text say `partial retained in composer`; never transcript content | Medium | Replace same lock within 2s | One-shot after delivery; composer focus follows §23.1.1 | User-invoked; no Room-content suppression | Injection succeeded |
| Content route changes | Target, new route, capability delta | Medium | Replace same target within 2s | One-shot after delivery | Recheck Room before delivery | Superseded route before delivery |
| Digest surface summoned | Recompute immediately before speech: `Digest, <allowed_unseen_event_count> changes`; if zero, `Digest, no allowed unseen changes` | High | Never dedupe distinct summons | Dismissal | Recompute count despite user invocation; focus-transfer announcement always delivers | Never suppress after focus moves |
| Other surface summoned | Exact §23.1.1 announcement payload for that surface | High | Never dedupe distinct summons | Dismissal | User-invoked; always deliver | Digest uses the row above |
| Focus restored | Exact restored AX target | Medium | Never dedupe distinct dismissals | One-shot after delivery | User-invoked; always deliver | None |

**Announcement arbitration:** composed usability and `SurfaceEligibilityReducer` first discard ineligible rows. One normalized transaction then emits at most one state-lane announcement per target/generation, in this order: error recovery, stale, permission, non-permission needs-input, finished, digest-ready, reconnect, content-route change, live restoration. The winner subsumes lower rows; its payload MUST include any lower-row target-safety fact. Error suppresses simultaneous approval speech; stale suppresses approval and subsumes route change; finished subsumes digest-ready speech while the passive digest indicator remains. A user-invoked safety/focus lane (dictation lock and dictation end, surface summon, focus restoration) emits at most one announcement per user action and subsumes a simultaneous state-lane announcement when its §23.1.1 payload carries that state. Permission activation during permission-surface summon uses the summon payload once.

**Delivery rules:**

- Queued unsolicited announcements for a Room are cancelled on allow→deny before delivery; delivery rechecks Focus after dequeue and immediately before speech.
- Focus filtering uses the canonical unsolicited-mask list in §18.10.1. User-invoked navigation to visible retained board/digest/detail content exposes the same text, actions, and focus order as pixels.
- An applicable error or stale transition cancels queued approval speech before enqueuing its own eligible recovery/stale row. Control becoming unavailable cancels approval speech without replacement. Explicit/cancelled normal close cancels all queued state speech and produces no close announcement.
- Rapid state changes inside the replacement window produce only the final payload. Queue depth is bounded and never blocks UI.
- VoiceOver goldens cover rapid change, stale/reconnect/live, duplicate events, queue-while-allowed then deny, passive silence, and explicit reading after deny.

### 24.3 Dynamic Type and keyboard

Dynamic Type applies to native chrome, board, router, digest, consent, diagnostics, settings, and ambient labels.
Layout reflows before truncating a primary action. The terminal grid uses explicit grid zoom because row/column
geometry is terminal behavior. A setting MAY link UI and grid scale, but it MUST show both values and allow them to
separate. The exact macOS AppKit mechanism, supported content-size categories, notification/update behavior,
persistence, and automation fixtures are evidence-gated by DL-OQ-07.

Every summoned surface is operable by keyboard with visible focus. Focus order matches reading order and remains
deterministic as state updates. Board teleport, router triage, permission review, Room switching, digest inspection,
sound preview, and concierge consent/uninstall have keyboard paths. Local and direct-SSH terminal creation,
connection, STT, MCP-addressed focus, and recovery also work with no multiplexer. No action requires hover, color
discrimination, motion, sound, or pointer precision.

### 24.4 Contrast and non-color receipts

Each design-gate run records final-pixel contrast for primary/secondary text, keyboard focus, Room seams, state
marks, native selection, disabled controls, stale labels, and degraded labels in dark and light appearance. These
Allward-owned pixels MUST meet §20 floors. The run also measures terminal glyph, cursor, and terminal selection
contrast. A failing user-authored terminal theme produces the §20 warning and inspection receipt, not a gate failure
or palette rewrite. Color-vision simulations cover Room tints and state pairs. Visible text/icon/shape and focus
order MUST preserve meaning without hue.

### 24.5 G1 terminal-projection receipts

The terminal-grid accessibility projection spike passes only when all rows below have linked artifacts from the same
build and fixture revision. Missing evidence is failure, not "manual verification pending." G1 proves the terminal
grid alone, not full-product accessibility.

| Scenario | Acceptance mechanism | Required receipt |
|---|---|---|
| Visible read | VoiceOver reads visible logical lines in order without OCR | Accessibility Inspector tree export plus screen-and-audio capture |
| Read all / navigation | Character, word, line, page, top, and bottom navigation traverses logical text and bounded scrollback | Scripted action transcript plus capture |
| Cursor and selection | Cursor and selected range match the visual grid before and after movement | Tree snapshot, visual capture, copied-text checksum |
| 100k-line scrollback | Element count stays bounded while navigation reaches non-materialized lines on request | Element-count trace, memory trace, successful distant-line capture |
| Reflow and resize | Logical reading/selection anchors survive coherent resize; no mixed generation is exposed | Before/after tree snapshots and selection receipt |
| Alternate screen | Projection switches and restores with the terminal screen model | Transition capture and tree-generation trace |
| Wide/combining/emoji | Grapheme navigation and spoken/copy text match the grid | Glyph fixture capture and expected/actual text artifact |
| Flood | Announcements coalesce; parser and renderer remain within G1 bars | Announcement-order log, parser/render/accessibility performance trace |
| Terminal-sourced announcements | Every affected OSC 133/publisher terminal trigger matches §24.2.1 payload, order, dedupe, acknowledgment/end, and Focus behavior | VoiceOver golden diff plus queue/replacement trace |
| AX generation sync | Metal and AX publish the same immutable generation under output, cursor/selection change, flood/coalescing, resize, and alternate-screen switches | Generation IDs at renderer commit and AX publication; assert equality and monotonic order; stale, skipped-semantic, or out-of-order AX fails |
| Semantic actions (OSC 133) | Grounded links, command regions, prompts expose correct role, label, value, hint, focus order, and action result | OSC 133 fixture with role/action verification; stale/unsupported absence path |
| Semantic actions (publisher) | Publisher permission UI separates local acknowledgment from decision dispatch; accepted/committed/rejected/cancelled/acknowledged/outcome-unknown states expose exact role/value/action; only committed renders granted; error/stale/unavailable/closed expose no approval action | Real `PermissionDecisionTransaction` with target/generation/action-result receipts and the §18.10.4 usability sentinels |
| Privacy canary — echo-off/delayed | Proven outbound canary bytes reach no product AX tree, VoiceOver transcript, log, capture/metadata, diagnostic, receipt, or induced crash artifact while parser output contains zero match | Isolated endpoint harness stores only case ID and boolean fixed-length-write success, never bytes or content-derived hash; zero parser-output match; automated scan of controlled unredacted product artifacts |
| Privacy canary — echo-on control | Returned parser echo IS correctly exposed in AX | Echo-on endpoint; verify echoed canary appears in AX normally |

The G1 performance receipt compares projection enabled and disabled under idle, ordinary output, flood, 100k-line
navigation, and resize. It records parser p99, render p99, main-thread time, allocations, element count, and
announcement count. The projection MUST add no polling, no idle frame source, and no per-cell steady-state
allocation. DL-OQ-06 first runs a calibration fixture and writes numeric regression limits for these metrics into a
versioned acceptance manifest. That manifest is frozen before the candidate implementation's G1 run; results cannot
move its limits.

### 24.6 G3 full-product accessibility receipts

G3 adds complete native-surface and keyboard-path receipts. These rows are not part of G1 but remain accessibility
requirements during implementation and must pass before public release.

G3 requires a versioned `g3-accessibility-manifest` that enumerates both products (Developer ID and MAS); local,
direct-SSH, herdr primary, and selected fallback routes; every v1 primary/recovery/permission flow; applicable
component states; expected keyboard sequence, focus checkpoints, tree/value/action, VoiceOver transcript, and
artifact hashes. Missing manifest entries are failure, not "not applicable." Entries with reasoned N/A explanations
are permitted.

| Scenario | Acceptance mechanism | Required receipt |
|---|---|---|
| Native surfaces | Board/router/digest/consent expose labels, values, actions, and stable focus order | Accessibility Inspector snapshots for each component state table |
| Reduced Motion | Full operation and focus remain with motion removed | Reduced Motion capture and frame-activity trace |
| Keyboard only | Every primary and recovery path completes without pointer input, including zero-multiplexer local/direct-SSH operation | Action transcript and end-state screenshots |
| Focus-transfer announcement | Each summoned surface produces one focus-transfer announcement; restoration names the target | VoiceOver transcript and tree transition capture |
| Native-surface announcements | Digest-ready, permission, error, and summon/restore triggers match §24.2.1 with no out-of-matrix event | Full VoiceOver golden set, delivery-time policy trace, replacement/acknowledgment log |
| Focus-filtered speech | Unsolicited Focus-denied Room content/targets are not announced or queued; user-invoked navigation, dictation-lock confirmation, and focus restoration may name the exact target | Policy-change transcript with denied-Room passive events plus explicit navigation/target-confirmation gates |
| Dynamic Type | Every supported category on every v1 native surface; live setting update; relaunch persistence; primary actions/targets preserved; terminal grid remains unchanged until explicit grid zoom | Frozen DL-OQ-07 category/surface manifest, reflow captures, update/relaunch receipt, grid-independence trace |
| Earcons and sound | For each of `needs-input`, `finished`, `error`, and `digest-ready`, an enabled real normalized event passes composed usability/reducer eligibility and reaches runtime playback before any suppression case runs; owner-approved assets, preview/diagnostic, Focus/duplicate/stale/unavailable/closed suppression, and sound-off path also pass | Four positive event IDs with reducer tuple, audio-engine delivery/playback capture, and asset hash; then suppression log, preview/diagnostic receipt, DL-OQ-04 approval, and sound-off energy trace |
| Apple Focus filters | Foreground/background/terminated delivery; relaunch reprojection; notification/sound filtering; queued-speech cancellation | Focus-state fixture; relaunch receipt; notification trace; speech queue verification |
| Increase Contrast | High-contrast token resolution when supported; focus/state contrast preserved | Contrast fixture with Increase Contrast enabled; token-resolution identity; final-pixel contrast |
| Dictation states | Every §23.8 state is reachable and announced per §24.2.1 on local, direct-SSH, and the selected adapter route, including denied, unavailable, interruption, cancellation, retained-partial, no-partial, and destination-lost outcomes; no transcript content leaves the composer | State-by-state capture, VoiceOver transcript, keyboard and Reduced Motion traces, and a transcript-leak scan across AX, logs, and announcements |
| Shell-integration lane | Real remote zsh setup, active regions (A/B/C/D, cwd, exit, freshness), reconnect, idempotent reapply, and verified removal in each signed product; stale and unsupported-shell states present per §23.9 | Per-product session captures with rc-file before/after diffs; unsupported-shell copy capture |
| Privacy surfaces | Diagnostics, crash opt-in/preview, and speech-artifact states match §24.7 and the versioned both-product privacy manifest in `SPEC.md`; no terminal, prompt, protocol, or speech content renders in any diagnostic or crash view | Forbidden-content canary scan of rendered diagnostic/crash/preview surfaces plus privacy-manifest cross-reference |

**OPEN QUESTION DL-OQ-06 — macOS 26 accessibility projection:** Which exact AppKit accessibility roles,
parameterized attributes, custom actions, and notification APIs implement the mechanism above with bounded speech
and no material parse/render cost? Build the projection spike; exercise every row in the acceptance table; record
latency, speech order, element count, memory, and API behavior. Evidence decides the API and bounds. Owner approval
is not required unless the mechanism would change a settled design rule.

### 24.7 Privacy surfaces and the privacy manifest

Design surfaces bind to the versioned both-product privacy manifest owned by `SPEC.md` §14/§16. This section owns what those surfaces may render; the manifest owns scanning and enforcement mechanics.

- Diagnostics, in-app logs, crash views, and their previews render no terminal content, command text, prompt text, protocol payloads, transcripts, or credential material. Bounded diagnostics identify targets through the same references/fingerprints as every other surface.
- Crash reporting presents as off until explicitly enabled. The opt-in flow shows the exact payload categories and a real payload preview before enablement; a per-report preview remains inspectable, and redacted fields display as redacted rather than silently absent.
- Speech artifacts have exactly three presented retention states: retained in the composer (visible, user-owned); discarded — copy says `discarded`, and completed removal is asserted by the manifest scan, never by UI claim; and never captured (`No transcript captured`). Failure copy never claims deletion the manifest scan has not verified and never implies retention that does not exist.
- Adding any diagnostic or crash field is a Design Language revision plus a privacy-manifest version change, never a silent copy update.

## 25. Design-gate mechanics

### 25.1 Standing design review gate

Every UI-touching change receives an independent design reviewer review against this file before merge.
“UI-touching” includes pixels, layout, text, interaction, focus, accessibility, sound, motion, terminal cell
geometry, native surface state, token resolution, and any publisher/transport change that creates a new visible
state. Maintainer review is required for G1, G2, G3, and approval assets.

The gate input bundle MUST contain:

1. change identifier and affected user-flow identifiers;
2. before/after token manifest and unused-token report;
3. fixture manifest with state, provenance, Room, appearance, and motion policy;
4. screenshots and, for motion/interaction changes, capture video or frame trace;
5. contrast report from final composited pixels;
6. accessibility tree snapshots and keyboard action transcript;
7. Reduced Motion trace;
8. sound-event mapping and preview receipt when sound changes;
9. cross-surface projection comparison from one immutable state generation;
10. announcement/VoiceOver transcript diffed against §24.2.1 for every affected trigger;
11. the implementation's own restraint note: what it removed or declined to add.

The reviewer returns a machine-readable result with `pass`, numbered findings, severity, rule reference, affected
receipt, and required correction. Prose praise is not a gate result.

The implementation repo MUST provide one required CI entry point named `allward-design-gate`. Its contract is:

- `allward-design-gate --base <revision> --bundle <manifest> --output <directory>`;
- a versioned change detector marks UI code, tokens, copy, accessibility, motion,
  sound, terminal geometry, and visible publisher/transport state as UI-touching;
  an unclassified changed path fails closed for classification;
- the command validates every declared receipt, runs automated checklist steps,
  invokes a fresh design reviewer that did not author the change, and validates
  its result against a versioned schema;
- the result contains gate/schema version, build, base, changed flows, fixture IDs,
  receipt hashes, each checklist result, each finding, severity, rule, disposition,
  reviewer identity class, and final pass value;
- exit 0 means complete bundle and no open P0/P1; exit 1 means missing/failed
  evidence or open P0/P1; exit 2 means gate infrastructure failure and also blocks;
- the required branch check uses that exit status; local success cannot waive CI;
- self-tests prove that a missing receipt, UI-path miss, literal token, open P1,
  malformed review, and stale baseline each produce a blocking exit.

Until this entry point and its blocking check exist, no UI implementation change can claim the standing gate. The
checklist below is the command's normative rule set, not a substitute for execution.

### 25.2 Breakpoint and state matrix

The stable width spine is 375, 768, 1024, and 1440 points where applicable. Mac- specific fixtures add:

- 900×600 default window;
- split-heavy topology with four terminal surfaces;
- 2560×1440 ambient/second-display presentation (1.x only; absent from v1 G1/G2/G3 and captured only after ambient implementation begins or for an ambient-only prototype).

Each changed flow covers these dimensions using a versioned covering array, not the full Cartesian
product:

- light and dark appearance;
- Reduce Transparency;
- Increase Contrast (when platform support is confirmed by DL-OQ-02);
- keyboard focus;
- Reduced Motion end state;
- loading and empty;
- live and maximum content;
- stale and degraded;
- reconnecting with visible `Disconnected`/`Reconnecting` reason;
- needs-input, including permission;
- running and finished;
- denied and error;
- disabled controls;
- active permission plus applicable error;
- active permission plus stale;
- active permission plus unavailable decision control;
- explicit/cancelled normal close with no ghost action/speech;
- `mcp_authored` stale and superseded records;
- decision `outcome_unknown` with lookup-only recovery;
- rotation/revocation on one target with an unaffected neighbor target visible;
- read-only snapshot route with captured-at freshness and refresh bound;
- connection cancel/timeout/failure exit from each nonterminal phase;
- each §23.8 dictation end cause with every partial-retention result permitted for that cause by `SPEC.md` §10;
- shell lane installed, active, stale, and unsupported states.

The covering array guarantees every dimension appears at least once. Mandatory high-risk pairs are appearance × state, focus × permission, Reduced Motion × motion-using transition, rotation/revocation outcome-unknown × unaffected neighbor target, each dictation end cause × every partial-retention result permitted for that cause by `SPEC.md` §10, and every Increase Contrast pair enumerated in §20.6; impossible cause/result pairs are explicit exclusions; remaining combinations use declared pairwise coverage with explicit exclusions. The array version is part of the fixture manifest and changes
only through Design Language revision.

The transport fixture set always includes a zero-multiplexer Room, a local PTY where the target supports it, a
direct-SSH session, and zero publishers. A herdr-touching change adds each affected herdr route without replacing
those baselines.

A state is "not applicable" only when the fixture manifest names why the component cannot enter it. Ambient changes
include no-action, stale/degraded, Focus-filtered, error, and maximum-content fixtures. Terminal changes include
primary screen, alternate screen, coherent resize, flood, wide/combining glyphs, and color emoji.

The capture manifest pins these parameters for reproducible visual receipts:

| Parameter | Required value |
|---|---|
| Point/pixel size | Mac fixture point size; device pixel ratio from fixture |
| Backing scale | 1× or 2× per fixture manifest |
| Color profile | sRGB or Display P3 as declared |
| Color space | Linear or gamma-encoded as declared |
| HDR state | Off unless fixture explicitly exercises HDR |
| Appearance | Light or dark per covering-array row |
| Material backdrop | Fixture-specified solid color or system wallpaper |
| Screenshot API | Platform-probe-selected and pinned; macOS uses ScreenCaptureKit (candidate DL-OQ-08); deprecated `CGWindowListCreateImage` is not acceptable evidence |
| Sampling geometry | Full window or declared viewport crop |
| Alpha handling | Premultiplied; opaque comparison against declared backdrop |
| Diff metric | Per-channel RMSE with declared tolerance |
| Tolerance | 0 for deterministic fixtures; declared per-component threshold otherwise |

Receipts failing contrast under the capture manifest require a semantic explanation and token or rule change, not
blind baseline replacement.

### 25.3 Executable gate checklist

The gate runs these checks in order. A missing required input fails at step 1; later manual review cannot waive
missing evidence.

- [ ] **1. Bundle completeness:** all affected flows, applicable fixtures, and
  required receipt types are declared.
- [ ] **2. Token integrity:** every color, font, type role, spacing, radius,
  stroke, material, duration, curve, and earcon resolves through the versioned
  token manifest; no new UI literal or unused token remains.
- [ ] **3. Grid stability:** `gridFrame`, rows, columns, cell coordinates,
  selection, and accessibility geometry remain unchanged across non-geometry
  states. Geometry fixtures show one coherent generation with no scaling or
  mixed frame.
- [ ] **4. Terminal truth:** Room tint and native state never rewrite the
  terminal palette or infer command/agent state from compositor pixels.
- [ ] **5. State completeness:** each changed component implements its applicable
  loading, empty, live, needs-input, running, finished, stale, degraded, denied,
  error, disabled, and maximum-content states with a target and next action where relevant.
- [ ] **6. Target safety:** every attach, teleport, paste, dictation, permission,
  close, and recovery action identifies and preserves one destination.
- [ ] **7. Spatial hierarchy:** grid remains dominant during terminal operation; router does not cover input; headers appear only when identity/action prevents mistakes. A user-summoned blocking surface may cover pixels only with §23.1 input suspension, focus announcement, stable `gridFrame`, and exact-focus restoration.
- [ ] **8. Motion grammar:** every transition maps to §21, ends, creates bounded
  damage, and has no loop, bounce, grid transform, or ad hoc curve.
- [ ] **9. Reduced Motion:** translation, scale, spring, outline expansion,
  animated reflow, crossfade, and repeated pulse are absent; frame trace settles
  immediately.
- [ ] **10. Sound grammar:** sound remains globally off by default; each of four §22 earcons has one enabled real-event runtime-delivery receipt before suppression tests; composed usability, reducer eligibility, arbitration, Room, Focus, stale, unavailable, closed, duplicate, and visible-state rules pass.
- [ ] **11. Contrast:** Allward-owned final-pixel reports meet §20 floors for every
  applicable appearance and interaction state; user-authored terminal failures
  produce warnings and receipts without mutation.
- [ ] **12. Non-color semantics:** every visible state has visible non-color
  semantics and remains distinguishable in grayscale/color-vision simulations and
  with sound/motion disabled.
- [ ] **13. Accessibility mechanism and input privacy:** terminal state comes from the logical projection; native elements have role/label/value/action; focus order is stable; §24.5 echo-off/delayed absence and echo-on positive-control receipts prove pre-echo outbound input is absent while returned parser output is present.
- [ ] **14. Announcement matrix:** every affected trigger matches §24.2.1 payload, replacement window, acknowledgment/end, delivery-time Focus recheck, and suppression; no out-of-matrix announcement exists.
- [ ] **15. Dynamic Type and overflow:** native UI reflows at content-size
  extremes; primary actions and distinguishing target labels remain available;
  grid zoom remains explicit.
- [ ] **16. Keyboard completion:** the main flow, recovery flow, and permission
  flow complete without a pointer; focus is visible at every step.
- [ ] **17. Provenance and degradation:** local and direct-SSH routes remain
  complete with zero multiplexer and zero publishers. Each optional-adapter
  fallback names route, freshness, source, missing capability, and recovery. The
  exact four-step herdr ladder is preserved when herdr is configured, and no
  polling is introduced. A bundle shipping that ladder carries a passing
  `G2-herdr-ordinary-ssh` receipt per signed product, and snapshot surfaces
  present §23.3 non-live honesty.
- [ ] **18. Model restraint:** deterministic facts remain available; no generated
  urgency, priority, permission, progress, or completion appears.
- [ ] **19. Erasure:** remove any visual element, token, asset, baseline, or state
  convention made obsolete by the change. If an element can disappear without
  information loss, remove it before pass.
- [ ] **20. Cross-surface consistency:** one immutable normalized-state generation satisfies the §23.5 per-surface projection schema. Every rendered/accessibility-exposed field matches; each omitted field has its declared detail path; Focus/privacy-prohibited fields stay absent.
- [ ] **21. Independent review:** the fresh non-author design reviewer's findings
  are resolved and the final bundle points to corrected receipts.
- [ ] **22. Decision-transaction fidelity:** publisher permission states derive only
  from the `PermissionDecisionTransaction`; `committed` alone renders granted;
  `outcome_unknown` blocks redispatch and offers lookup-only recovery; `acknowledged`
  remains distinct from commit and from local router acknowledgment; wrong-target and
  stale-generation outcomes leave visible state unchanged.
- [ ] **23. Authority isolation:** rotation/revocation and MCP authority-loss receipts
  show exact-target effect with an unaffected neighbor target unchanged; recovery
  surfaces are lookup-only; no credential, token, audience, or nonce detail appears anywhere.
- [ ] **24. Dictation honesty:** no listening claim before real acquisition; every
  §23.8 end cause presents its typed state with retained-partial or no-partial result;
  transcript content appears only in the locked composer.
- [ ] **25. Shell-lane honesty:** shell-integration claims match §23.9 lane state;
  unsupported shells are labeled unsupported with no install path; rc changes are
  consented, previewed, and owned; per-product real-shell receipts exist when the lane ships.
- [ ] **26. Privacy surfaces:** changed diagnostics, crash, preview, or speech-artifact
  views pass the §24.7 rendering rules and reference the current privacy-manifest version.

### 25.4 Drift detection

Design tokens are the single source for type, color, material, stroke, spacing, radius, motion, and sound. A literal
scanner rejects implementation values outside approved token modules. The token-manifest diff reports additions,
deletions, role changes, and unused tokens. Superseded tokens and assets are deleted in the same change.

Visual verification uses two layers:

1. deterministic terminal fixtures remain unmasked for grid and geometry diffs;
2. dynamic terminal data may be masked only in chrome comparisons, while all
   chrome, seams, headers, focus, board, router, and state marks remain visible.

Baselines are indexed by breakpoint, Mac fixture, appearance, Room, motion policy, and state. Pixel changes require
a semantic reason and the matching token or rule revision. Blind baseline replacement fails. Accessibility baselines
include role, label, value, action, logical text range, and focus order. Unexpected tree changes fail even when
pixels match.

### 25.5 Severity and decision authority

| Severity | Definition | Gate effect |
|---|---|---|
| P0 | Wrong target/action, hidden permission risk, privacy leak, inaccessible primary flow, or grid corruption | Blocks merge and gate; owner escalation if a settled decision must change |
| P1 | Missing required state, contrast failure, keyboard/VoiceOver failure, grid motion, dishonest degradation, token drift, or unexplained baseline change | Blocks merge and gate |
| P2 | Local visual or wording defect that does not break a required mechanism | Recorded; correction may be scheduled, but owner gate review sees it |

Evidence decides platform API, transport, library, and performance questions. The owner approves product identity
assets and any proposal that reopens a settled decision. Reversible engineering defaults do not wait for owner
review.

### 25.6 Open design probes and owner approvals

| ID | Status and question | Probe and required receipt | Authority |
|---|---|---|---|
| DL-OQ-01 | **OPEN QUESTION — blocks G1:** Which default v1 grid/UI/data font assets and literal metrics satisfy grid correctness and native UI hierarchy? | Glyph/metric matrix across non-ambient v1 roles, wide/combining/emoji, bold/italic, all supported UI categories, 375–1440 widths, and 900×600; overflow and accessibility captures | Owner approves v1 font identity and scale after evidence |
| DL-OQ-02 | **OPEN QUESTION — blocks G1:** Which v1 light/dark/Increase Contrast palette, Room tint set, derivation, material, spacing, stroke, and radius values satisfy contrast, Room distinction, and restraint? | Determine Increase Contrast support; freeze token-resolution identity; run final-pixel normal/Increase Contrast matrix, mandatory focus/disabled/selected/stale/degraded/permission/error pairs, color-vision simulations, Room collisions, dark/light splits, and imported-theme warning | Owner approves v1 palette, Room tints, material, and foundational spacing/stroke/radius scale |
| DL-OQ-03 | **OPEN QUESTION — blocks G1:** Which literal durations and curves give the six named transitions the intended restrained feel without affecting grid stability or idle energy? | Pre-register token timing and component-damage bounds; frame traces record frame count, completion time, damaged bounds, and post-completion idle frames at reference-hardware refresh rates for ordinary, flood, idle, and Reduced Motion paths | Owner approves motion feel, durations, and curves |
| DL-OQ-04 | **OPEN QUESTION — blocks G3:** Which four v1 audio assets form a coherent, brief, non-startling, volume-consistent family? | Loudness-normalized previews in context/isolation, asset hashes, settings preview/diagnostic path, duplicate/stale/Focus suppression, sound-off energy trace, accessibility pairing | Owner listening approval required before G3 |
| DL-OQ-05 | **OPEN QUESTION — blocks G3:** Which v1 board presentation and density best preserve grid dominance, focus clarity, keyboard speed, and maximum-content scanning? | Overlay/side-sheet/detached prototypes at v1 fixtures; sentinel input routing, keyboard, VoiceOver, split-heavy, and extreme-label/count tests | Owner approves v1 board presentation/density; settled grid/input invariants cannot change |
| DL-OQ-06 | **OPEN QUESTION — blocks G1:** Which macOS 26 accessibility APIs and bounded virtualization/announcement parameters implement §24 without material parse/render cost? | Calibration first freezes a versioned numeric acceptance manifest for parser/render/main-thread p99, allocations, element and announcement counts; then run the full §24.5 matrix and enabled/disabled comparison without moving limits | Evidence decides; owner only if a settled rule would change |
| DL-OQ-07 | **OPEN QUESTION — blocks G3:** Which macOS AppKit mechanism implements Dynamic Type for native chrome, what content-size categories are supported, and how are notification/update/persistence behaviors exercised? | Document exact NSFontDescriptor/UIContentSizeCategory APIs or AppKit equivalent; fixture each supported category; record notification handling, persistence across launches, and automation accessibility; manifest frozen before G3 | Evidence decides; blocks G3; owner only if a settled rule would change |
| DL-OQ-08 | **OPEN QUESTION — blocks G1:** Which platform screenshot/capture API produces reproducible visual receipts without deprecated interfaces? | Document exact API (ScreenCaptureKit candidate on macOS), color-space handling, HDR behavior, backing-scale correctness, and performance; verify against covering-array fixtures; pin selection in capture manifest before G1 | Evidence decides; blocks G1; owner only if a settled rule would change |
| DL-OQ-09 | **1.x RESERVED — does not block v1 G1/G2/G3:** Which ambient type metrics, palette resolution, density, card cap, and distance presentation satisfy the fixed ambient roles? | Begin only with ambient implementation/prototype; 2560×1440 captures record display/scaling/distance/acuity assumptions, task accuracy/time, Reduce Motion, Increase Contrast, and Focus-filtered states | Owner approves 1.x ambient identity/density after evidence |

A probe closes only when its receipt bundle names the build, fixture manifest, hardware/OS where relevant, outcome,
approved token revision, and approver when required. Approval of a literal asset does not reopen its semantic role.

### 25.7 Gate output

A passing change leaves these receipts linked from one gate result:

- fixture manifest and before/after screenshots;
- visual diff report;
- token manifest diff and literal/unused-token scan;
- final-pixel contrast and color-vision reports;
- accessibility snapshots, §24.5 pre-echo canary/control scan, announcement-matrix transcript, and keyboard transcript;
- Reduced Motion capture and frame trace;
- motion or earcon receipts when affected;
- privacy-surface scan receipt when diagnostics, crash, or speech-artifact views changed;
- cross-surface projection comparison;
- `allward-design-gate` machine result with zero open P0/P1 findings;
- owner approval reference when an owner-approval asset changed.

The gate passes only when every applicable checklist item is true, every required receipt exists, and no P0/P1
finding remains. Design Language revisions precede implementation when a change needs a new role or rule. Code
cannot establish a second convention by example.
