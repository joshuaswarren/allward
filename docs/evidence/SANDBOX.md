# App Sandbox and SSH library evidence

Measured, not read. [SPEC.md](../SPEC.md) §14 leaves ssh-agent access,
security-scoped key-file access, and entitlements "probe-gated", and says
plainly that Apple's documentation "does not prove the needed credential
route". [MAS-PLAN.md](../MAS-PLAN.md) decisions **D-A** and **D-B** were blocked
on facts nobody had gathered. These are the facts.

This is the capability subset of **OQ-14**, not OQ-14. OQ-14 additionally
requires import, unlock, use, rotation, deletion, host-key first use and
mismatch, log and crash-artifact inspection, with throwaway keys, in both
products. Phase 5 owns that.

## Sandbox capabilities

Reproduce with `bash fixtures/mas-sandbox-probe/run.sh`. It assembles a minimal
bundle, signs it ad hoc with `com.apple.security.app-sandbox` and
`com.apple.security.network.client`, and runs the probe inside it. Measured on
macOS 26.5.2 (build 25F84), Apple silicon, 2026-08-02:

| Probe | Verdict | Detail |
|---|---|---|
| sandbox container | active | container home in use, so the run is valid |
| `SSH_AUTH_SOCK` in environment | inherited | the variable survives |
| ssh-agent `connect()` | **denied** | `EPERM` |
| read `~/.ssh/config` | **denied** | `EPERM` |
| read `~/.ssh/known_hosts` | **denied** | `EPERM` |
| write `/tmp` | **denied** | `EPERM` |
| launch `/usr/bin/ssh` | **permitted** | exited 0 |
| child reads `~/.ssh/config` | **denied** | child inherited the sandbox |
| Keychain add and read | inconclusive | `SecItemAdd` returned `-25308` under ad-hoc signing |
| outgoing TCP | permitted | connected to loopback 22 |

### What this settles

**The agent question is closed by measurement, not by choice.** The socket path
is inherited but unreachable. A sandboxed Allward cannot use ssh-agent, so
"no agent" in D-B is a fact to design around rather than a decision to make.

**MAS host aliases must come from Allward's own configuration.** `~/.ssh/config`
and `~/.ssh/known_hosts` are both unreadable, so host aliases defined there do
not resolve and prior host-key pinning is invisible.

**SPEC §2's `/tmp` prohibition is empirical.** A sandboxed product has a
container, and `/tmp` is not writable.

**Keychain is unproven, not disproven.** `-25308` is
`errSecInteractionNotAllowed`, and the probe is signed ad hoc with no team
identifier, so it cannot reach its own keychain access group. This is the one
measurement on this page that has not been taken.

Taking it needs a real signing identity, and that is where it stops. Signing with
one over SSH fails with `errSecInternalComponent`, because the login keychain is
locked in a non-interactive session and `security show-keychain-info` reports
"User interaction is not allowed". The signing key cannot be read without the
keychain password. Whoever holds it can close this in one command:

```sh
security unlock-keychain ~/Library/Keychains/login.keychain-db
ALLWARD_PROBE_IDENTITY="Apple Development: ..." bash fixtures/mas-sandbox-probe/run.sh
```

`run.sh` prints that instruction itself when signing fails, so the next person
does not have to rediscover it.

### The correction this forced

[MAS-PLAN.md](../MAS-PLAN.md) assumed the sandbox forbids launching `ssh`. It
does not. The spawn is permitted. What the measurement shows instead is that the
child **inherits the sandbox**, so a spawned `ssh` starts and then cannot read
the config, the known-hosts file, or any key.

The plan's conclusion survives and its stated reason does not. MAS needs
in-process SSH because a spawned client is starved of everything it needs, and
because MAS is remote-only by product rule. Not because `exec` is blocked.

## SSH libraries

Read from source, 2026-08-02. Relevant to **D-A**.

| | `swift-nio-ssh` | libssh2 | libssh | Citadel |
|---|---|---|---|---|
| Version | 0.15.0, pre-1.0 | 1.11.1 | HEAD | HEAD |
| Released | 2026-07-28 | 2024-10-16 | 2026-07-27 | 2026-04-04 |
| License | Apache-2.0 | BSD-style | **LGPL-2.1** | MIT |
| Language | Swift, no C vendoring | C | C | Swift + a C target |
| PTY / exec / direct-tcpip | yes / yes / yes | yes / yes / yes | yes / yes / yes | via its dependency |
| RSA host keys | **no** | yes | yes | no |
| `known_hosts` | none, ours to write | none | ships one | no |
| keyboard-interactive | **no** | yes | yes | no |

`swift-nio-ssh` facts, all from its own repository at commit `3ec2814`:

- Its README states: "SwiftNIO SSH does not ship production-ready SSH clients
  and servers, but instead provides the building blocks for building this kind
  of client and server." We would be writing the client.
- **One commit in the last twelve months.** Effectively dormant.
- `NIOSSHPublicKey.BackingKey` holds only Ed25519, ECDSA P-256/P-384/P-521, and
  certificates, and `knownAlgorithms` lists only `ssh-ed25519` and the three
  ECDSA names. An `ssh-rsa` or `rsa-sha2-256/512` **host** key cannot be
  represented or verified at all. This is a host-key gap, not only a user-key
  one.
- PTY is `SSHChannelRequestEvent.PseudoTerminalRequest` with terminal modes and
  a matching `WindowChangeRequest`; exec is `ExecRequest`; forwarding is
  `SSHChannelType.directTCPIP`. Host-key validation is a caller delegate,
  `NIOSSHClientServerAuthenticationDelegate.validateHostKey`, which matches
  §14 assigning host trust to us.
- It supports Secure Enclave P-256 private keys on Darwin, which is worth
  weighing in D-B: a key that cannot be exported beats a key held in Keychain.
- Declares `swift-nio`, `swift-crypto`, `swift-atomics`. Transitive licence and
  C-shim status is **not** audited; do not claim all-Apache without checking.

### How much the RSA gap actually costs

Measured against a stock macOS 26.5.2 `sshd`, the offered host key algorithms
are `ssh-ed25519`, `ecdsa-sha2-nistp256`, and `ssh-rsa`. Because a server
advertises several and the client negotiates, `swift-nio-ssh` connects to that
server: it picks Ed25519.

The gap bites only where a server offers **no** Ed25519 or ECDSA host key. That
is older appliances, embedded devices, and long-lived legacy hosts, not a modern
OpenSSH. It also means a host previously pinned by its RSA key would be
re-pinned under a different algorithm, and MAS cannot read the old pin anyway.

The gap is real and narrow. It is a product-compatibility question, which is why
it belongs to the owner rather than to whoever is writing phase 2.

### Candidate notes

- **libssh** is LGPL-2.1. That creates App Store distribution obligations that
  need legal review before it is even a candidate.
- **libssh2** is licence-clean and algorithm-complete, but it is C with no
  maintained Swift binding, so Allward would own the bridge. C vendoring is not
  a new precedent here: `CAllwardPTY` already exists. Its last release was
  October 2024 while its repository stays active.
- **Citadel** is MIT and Swift-facing, but its manifest depends on a *fork* of
  `swift-nio-ssh` pinned to 0.3.x while upstream is 0.15.0, and it carries its
  own C bcrypt target. That is a supply-chain risk, not a shortcut.
