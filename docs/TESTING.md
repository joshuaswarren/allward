# Testing allward

Allward is pre-alpha. It is already installed on macstudio and JW14M2 at
`/Applications/Allward.app`. This page covers what to try. It also covers
what should happen, and how to report what does not.

## Build it yourself

Requires macOS 26, Xcode 26, Swift 6.2 or newer.

```sh
git clone https://github.com/joshuaswarren/allward
cd allward
swift build
swift test                          # 111 tests
CONFIG=release bash scripts/make-app.sh
ditto .build/Allward.app /Applications/Allward.app
```

The app is ad-hoc signed. Gatekeeper blocks a downloaded copy. Clear the
quarantine flag first:

```sh
xattr -dr com.apple.quarantine /Applications/Allward.app
```

## First run

Launch it. You get one window, one Room named Personal, one local shell.
First launch seeds `~/.config/allward/allward.toml`. Fonts, themes, hosts,
and Rooms all live in that file.

Set a Nerd Font before anything else. Agent output is full of powerline
and icon glyphs:

```toml
font-family = "MesloLGS NF"
font-size = 13.0
theme = "Allward Night"
```

Delete the file to get the defaults back.

## What to exercise

The terminal itself. Run your real shell, your real prompt, and your real
editor. Powerline segments, box drawing, wide CJK, bold, underline, and
reverse video all have to land on the grid. None of them may smear into a
neighbouring cell. Resize the window while output floods.

Panes and tabs. `⌘D` splits right and `⇧⌘D` splits down. `⌘W` closes a
pane and `⇧⌘W` closes a tab. `⌘T` opens a tab and `⌥⌘T` adds a pane to the
one you are in. `⌥⌘←` and `⌥⌘→` move focus. `⌃⇥` cycles tabs and `⌘1` through `⌘9` jump straight to one. Each
pane keeps its own shell, scrollback, and title.

Rooms. `⇧⌘M` switches. A Room owns its theme, its hosts, and its sessions.
So Personal and Work can look and behave differently. Themes follow the
Room, never the system appearance.

SSH. Add a host to the config and open it with `⇧⌘O`. The connection is direct. No
multiplexer is installed on the far end, and nothing is required there.

Find. `⌘F` searches the scrollback; `⌘G` and `⇧⌘G` walk the matches.

The Board. `⇧⌘B`. The command palette is `⇧⌘P`; `⌘K` clears the screen. With no agents connected it says so plainly. Point an
agent at the socket and it fills with that agent's live state and open
tasks. Any permission request waiting on you shows up there too.

Dictation. Hold the push-to-talk key. The Mac transcribes on device and
inserts the text at the cursor. Nothing leaves the machine.

## Connecting an agent

Allward listens on an AF_UNIX socket and exports its path to every
session:

```sh
echo $ALLWARD_SOCKET
```

Anything that can write a line of JSON to that socket can publish to the
Board. [SPEC.md](SPEC.md) §7 has the wire format.

The MCP server is a separate executable that speaks to the same socket:

```sh
claude mcp add allward -- /Applications/Allward.app/Contents/MacOS/allward-mcp
```

An [optional herdr adapter](evidence/HERDR.md) discovers panes from a
herdr server. It is genuinely optional. `scripts/no-adapter-clean-build-test.sh`
proves no core target links it.

## Capturing evidence

Two harnesses exist so a defect can be shown rather than described.

`allward-qa` renders every surface offscreen through the same
`SceneBuilder` the app uses. It needs no display and no permission
grant:

```sh
.build/debug/allward-qa artifacts/visual-qa
```

The app itself can photograph its own live window, drive a real shell,
and report its layout:

```sh
/Applications/Allward.app/Contents/MacOS/Allward \
    --capture /tmp/shot.png \
    --exercise split-right \
    --type "clear; echo hello"
```

`scripts/inspect-capture.swift` reads a capture back as pixels. It reports
where content and seams actually sit. That is how a layout claim gets
checked without trusting a screenshot by eye.

## Reporting a defect

Open an issue with the capture, the command that produced it, and what
you expected instead. A PNG makes a layout or rendering report far easier
to act on than a description.

Known gaps, so you do not report them twice. There is no sandboxed Mac
App Store build. There is no pinned esctest or vttest conformance
manifest. Nobody has run the flood and soak benchmarks in
[SPEC.md](SPEC.md) §21.
