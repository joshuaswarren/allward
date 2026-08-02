# Agent notes

Allward is a macOS terminal emulator. Swift 6, macOS 26 floor, Apache-2.0.

This file is the entry point. Read it, then read what it points at. Nothing here
depends on any other repository.

## This is a public repository

Open source from the first commit. Anything committed is world-readable: no
personal data, no employer or client names, no internal hostnames or IP
addresses, no absolute home paths. `scripts/validate-publication.py` enforces
some of this for `README.md` and `docs/**.md`; the rest is your judgement.

## Read the design before proposing one

The architecture is written down and settled in places you may assume are open:

- [docs/SPEC.md](docs/SPEC.md) - the normative specification
- [docs/DECISIONS.md](docs/DECISIONS.md) - accepted decisions, numbered
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - position and invariants
- [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md) - visual and interaction rules
- [docs/TESTING.md](docs/TESTING.md) - how to verify, and the known gaps

`MUST`, `SHOULD`, and `MAY` are rule words. Open questions carry an `OQ-NN`
marker and stay open until a repeatable test closes them.

A worked failure, so it is not repeated: an agent spent a long session reasoning
from the source about whether a sandboxed App Store target was feasible and what
its SSH design should be. Both answers were already in `DECISIONS.md` and
`SPEC.md`. It also inferred a "no external dependencies" policy from
`Package.swift` and argued from it; no such decision exists. **Grep the docs
before forming an architectural opinion, and do not promote an observation about
the code into a rule.**

## What to do next

[docs/MAS-PLAN.md](docs/MAS-PLAN.md) is the current plan. **Phase 1 has landed:**
the `allward-mas` product exists, and `scripts/mas-isolation-receipts.py` emits
the four link-negative receipts against `scripts/mas-isolation.json`. All four
fail on purpose. Run them before you argue about the MAS graph, because they
report it.

**Both owner decisions are made**, so nothing is blocked. Decisions 39 and 40 in
[docs/DECISIONS.md](docs/DECISIONS.md):

- **D-A** the SSH library is **`russh`**. Apache-2.0, RSA, and a `Signer` trait so
  private keys stay inside Security.framework. First external dependency, and
  first Rust. The seam is verified: it builds as a `staticlib` for
  `aarch64-apple-darwin`, Swift calls it over a C ABI, and it adds no linked
  library the MAS manifest does not already permit. Pin a **stable** toolchain.
- **D-B** MAS credentials are **Keychain items marked `kSecAttrSynchronizable`**,
  so keys sync over iCloud. The Secure Enclave cannot import an existing key and
  forfeits sync, so it is an alternative for a fresh key, never an upgrade path.

**Phase 3 is the best next work**, because it clears the most receipt findings and
does not touch the new dependency: move local PTY spawning, the process-table
herdr discovery, the process herdr executor, and the AF_UNIX control socket host
out of shared modules and behind injected protocols. Receipts 1 and 2 name every
offending edge and line. Phase 2 then replaces the transport itself, and
`AllwardLocalPTY` stays reachable through `AllwardSSH` until it does.

Do not weaken a decision above to make a phase easier. Ask instead.

## Build and test

Sources are authored on Linux. **The build runs on a macOS machine.** Do not run
`swift` in this checkout; it will fail, and a failure here proves nothing.

```sh
scripts/sync-to-mac.sh          # mirrors the tree to the build host
```

The host and directory come from `ALLWARD_BUILD_HOST` and `ALLWARD_BUILD_DIR`,
with defaults in the script. Run Swift there:

```sh
ssh "$ALLWARD_BUILD_HOST" 'cd "$ALLWARD_BUILD_DIR" && swift build && swift test'
```

**One build at a time.** The build directory is shared; concurrent `swift build`
runs against it corrupt each other. If you delegate work to subagents, they edit
source only - you own the build.

## What counts as done

A green test run is not evidence that a feature works. Before claiming
completion:

```sh
swift test
bash scripts/no-adapter-clean-build-test.sh   # core must not link AllwardHerdr
python3 scripts/mas-isolation-receipts.py     # MAS isolation; read it, do not
                                              # expect it to pass before phase 6
python3 scripts/validate-publication.py       # public markdown
```

The MAS receipts exit non-zero by design. What matters is that they fail on
fewer things than before your change, and never on something new.

Then exercise the real application. It photographs itself:

```sh
Allward --capture out.png --exercise <surface> --then "wait,wait"
```

`.build/debug/allward-qa artifacts/visual-qa` renders every surface to PNG
through the same code paths the app uses. For a behavioural fix, prove the fix
with a test that fails without it.

## Rules that keep being broken

- **Settings contains settings.** A statement of fact belongs in the README. A
  control that reports rather than changes something is not a setting.
- **No dead controls.** A button that cannot act must not be visible, and one
  that opens a screen where the user can do nothing is a dead end.
- **Do not weaken the terminal to make a preference.** Copy and paste, and
  anything a terminal must do, are not switchable.
- **MAS is remote-only.** No local shell, and no helper that provides one.
- **Delete what you replace.** No compatibility shims or deprecated paths unless
  asked for.
- Comments explain why. Never narrate a line's mechanics mid-function.

`.claude/napkin.md` collects specific corrections from earlier sessions. Read it,
and add to it when you get something wrong.
