# Allward

A native Mac terminal for people who run coding agents on many machines.

Most terminals sort work by process and window. Allward groups local and remote sessions into Rooms. It shows the work that needs you: live agents, plans, open tasks, and permission requests. It also points to the pane that owns each item.

The terminal works without a multiplexer. Local shells and direct SSH are core paths. Optional adapters add discovery and durable workspace identity. [herdr](https://herdr.dev/) is the first deep adapter, not a runtime need.

## Status

Allward is pre-alpha. You cannot install the app yet.

The public specs are done. Code has begun with the identity layer. The first type is `RoomID`, a stable ID that does not depend on a window, process, transport, or multiplexer. Rooms will bind themes, hosts, sessions, alert rules, and saved state.

## What Allward will do

- Run a new terminal engine with AppKit input, a Metal grid, and SwiftUI chrome.
- Support local shells in the signed direct build.
- Support direct SSH in both the direct and Mac App Store builds.
- Add optional multiplexer adapters, starting with herdr.
- Show native plans, tasks, prompts, command state, and agent views.
- Group work in Rooms across windows, hosts, and sessions.
- Show an open-loop board, alert router, return digest, and one-key pane jump.
- Insert on-device speech as text without sending the command.
- Ship an MCP server for panes, boards, views, and Rooms.
- Gate each release on access, speed, energy use, and privacy.

## Product rules

1. Local shells and direct SSH work without herdr.
2. Adapters add discovery and layout. They do not own the terminal.
3. The main thread never parses terminal bytes.
4. The app never scrapes pixels for meaning.
5. Models run on the device by default.
6. Allward collects no usage data. Crash reports require opt-in and remove terminal text.
7. Specs define the contract. Tests and receipts prove it.

## Build the current package

You need macOS 26, Xcode 26, and Swift 6.2 or later.

```sh
swift test
```

The package now builds `AllwardCore` and its tests. App, terminal, SSH, render, protocol, and adapter targets will follow the module map in the spec.

## Read the design

- [Technical specification](docs/SPEC.md)
- [Design language](docs/DESIGN-LANGUAGE.md)
- [Architecture position](docs/ARCHITECTURE.md)
- [Accepted decisions](docs/DECISIONS.md)
- [Apple platform and MCP evidence](docs/evidence/PLATFORM.md)
- [herdr 0.7.5 evidence](docs/evidence/HERDR.md)

The specs use `MUST`, `SHOULD`, and `MAY` as rule words. Open questions stay marked until a repeatable test closes them.

## License

Apache License 2.0. See [LICENSE](LICENSE).
