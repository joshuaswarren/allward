# Allward

A native Mac terminal for people who run coding agents on many machines.

Most terminals sort work by process and window. Allward groups local and remote sessions into Rooms. It shows the work that needs you: live agents, plans, open tasks, and permission requests. It points to the pane that owns each item.

The terminal works without a multiplexer. Local shells and direct SSH are core paths. Adapters are optional. They add discovery and durable workspace identity. [herdr](https://herdr.dev/) is the first deep adapter, not a runtime need.

## Status

Allward v1 builds and runs. It is a young app, not a finished one. Expect rough edges. Read the open questions in the specs before you rely on a behaviour.

What works today, verified on real hardware:

- A from-scratch VT engine with a Metal grid. It covers truecolor, bold, italic, underline, strike, inverse, wide CJK cells, colour emoji, alternate screen, scroll regions, and OSC 133 command regions.
- Local shells through a real PTY, including complex prompts such as powerlevel10k.
- Direct SSH with a typed connection state machine and named failure causes.
- Rooms with their own tint, theme, hosts, and notification rules.
- The session board, attention router strip, and re-entry digest. One normalized record store feeds all three.
- The optional herdr adapter with its four-route fallback ladder.
- An MCP server (`allward-mcp`) that drives the same control layer the UI uses.
- Push-to-talk dictation. It inserts text at a locked destination and never presses Return.

Not in this build: the sandboxed Mac App Store target, inline images, and the roadmap items in `docs/SPEC.md` §1.

## Install

You need macOS 26 on Apple silicon.

```sh
git clone https://github.com/joshuaswarren/allward
cd allward
swift test                 # 111 tests
bash scripts/make-app.sh   # builds and signs .build/Allward.app
ditto .build/Allward.app /Applications/Allward.app
open -a Allward
```

`scripts/make-app.sh` ad-hoc signs by default. To sign with your own identity:

```sh
CODESIGN_IDENTITY="Apple Development: You (TEAMID)" bash scripts/make-app.sh
```

## Try it

| Action | Key |
| --- | --- |
| New tab | `⌘T` |
| New pane in this tab | `⌥⌘T` |
| New window | `⌘N` |
| Close pane / tab / window | `⌘W` / `⌥⌘W` / `⇧⌘W` |
| Split right / down | `⌘D` / `⇧⌘D` |
| Move focus between panes | `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` |
| Connect to a configured SSH host | `⇧⌘O` |
| Session board | `⇧⌘B` |
| Attention router | `⇧⌘R` |
| Re-entry digest | `⇧⌘E` |
| Clear screen | `⌘K` |
| Command palette | `⇧⌘P` |
| Switch Room | `⇧⌘M` |
| Teleport to the routed destination | `⇧⌘T` |
| Cycle tabs | `⌃⇥` / `⌃⇧⇥` |
| Select tab 1-8, last | `⌘1`…`⌘8`, `⌘9` |
| Copy / paste / select all | `⌘C` / `⌘V` / `⌘A` |
| Find / next / previous | `⌘F` / `⌘G` / `⇧⌘G` |
| Bigger / smaller / actual text | `⌘+` / `⌘-` / `⌘0` |
| Scroll top / bottom / page | `⌘↖` / `⌘↘` / `⌘⇞` `⌘⇟` |
| Previous / next shell prompt | `⇧⌘↑` / `⇧⌘↓` |
| Settings | `⌘,` |
| Diagnostics | `⇧⌘/` |

Configuration is a plain TOML file at `~/.config/allward/allward.toml`. Allward writes it on first launch. It reloads when the file changes on disk. Settings writes the same file.

## Connect the MCP server

`allward-mcp` ships inside the bundle and talks to the running app over an owner-only socket.

```sh
claude mcp add allward -- /Applications/Allward.app/Contents/MacOS/allward-mcp
```

It exposes pane control, screen and history reads, board and router queries, Room operations, and teleport. `allward_run` types a command, waits for the OSC 133 marker, then returns the exit code and output.

## Product rules

1. Local shells and direct SSH work without herdr.
2. Adapters add discovery and layout. They do not own the terminal.
3. The main thread never parses terminal bytes.
4. The app never scrapes pixels for meaning.
5. Models run on the device by default.
6. Allward collects no usage data and has no crash reporter.
7. Specs define the contract. Tests and receipts prove it.

## Privacy

These are facts about how Allward works, not things to configure:

- No telemetry, no analytics, no crash reporter. Nothing is sent anywhere.
- Dictation is transcribed on the device. The audio is discarded immediately
  and is never written to disk.
- A program running in a pane can *set* the clipboard, and cannot read it.
- A program cannot ask the terminal to write a file.

The last two are the only ones that can be changed, because xterm defines
sequences for both and some tools expect them. They are off, and they live in
Settings under Privacy:

- **Let programs read the clipboard** (`OSC 52` read). On, any program can read
  whatever you last copied, without asking.
- **Let programs write a log file** (`OSC 46`). On, a program chooses the path
  as well as the contents.

## Develop

```sh
swift build
swift test
.build/debug/allward-qa artifacts/visual-qa   # renders every surface to PNG
```

`allward-qa` draws the real terminal scene through the same `SceneBuilder` the app uses. It draws the real SwiftUI surfaces through `NSHostingView`. The PNGs are production pixels. The app also accepts `--capture <path>` and `--type <command>` to photograph its own live window.

## Read the design

- [Technical specification](docs/SPEC.md)
- [Design language](docs/DESIGN-LANGUAGE.md)
- [Architecture position](docs/ARCHITECTURE.md)
- [Accepted decisions](docs/DECISIONS.md)
- [Testing](docs/TESTING.md)
- [Apple platform and MCP evidence](docs/evidence/PLATFORM.md)
- [herdr 0.7.5 evidence](docs/evidence/HERDR.md)

The specs use `MUST`, `SHOULD`, and `MAY` as rule words. Open questions stay marked until a repeatable test closes them.

## License

Apache License 2.0. See [LICENSE](LICENSE).
