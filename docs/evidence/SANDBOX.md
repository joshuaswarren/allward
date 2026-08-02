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

### What the RSA gap actually costs: measured, and it is disqualifying

The first pass of this page judged the gap "real and narrow" by looking only at
**host** keys. That was the wrong measurement. A stock macOS 26.5.2 `sshd` offers
`ssh-ed25519`, `ecdsa-sha2-nistp256`, and `ssh-rsa`, and because the client
negotiates, `swift-nio-ssh` connects to it happily by picking Ed25519. On host
keys alone the gap looks survivable.

**User** keys are the ones that decide it. Measured on a working developer
machine, 2026-08-02, counting private keys by algorithm:

```text
16  RSA
 2  ED25519
```

Several of the RSA keys are cloud-provider `.pem` keys whose public half is
already installed on instances the operator does not re-key at will. Since
`NIOSSHPrivateKey` accepts only Ed25519, ECDSA P-256/P-384/P-521, and Secure
Enclave P-256, `swift-nio-ssh` **cannot authenticate with 16 of those 18 keys**.

That is not a narrow compatibility footnote. It is most of a real inventory, and
it disqualifies the library for this product unless someone forks it to add both
RSA and a signer abstraction.

### The requirement this exposes: never hold the private key

If keys live in Keychain, and better still in the Secure Enclave, then the SSH
library must be able to ask the application for a signature instead of owning key
bytes. That reframes D-A: the question is not only "which library speaks RSA" but
"which library lets Security.framework do the signing".

| Library | RSA | External signer | Evidence |
|---|---|---|---|
| libssh2 | yes | **yes** | `libssh2_userauth_publickey(..., sign_callback, abstract)` in `include/libssh2.h` 684-690; called at `src/userauth.c` 1583 |
| russh | yes | **yes** | `Signer.auth_sign` in `russh/src/auth.rs` 136-149, used by `authenticate_publickey_with` |
| Go `x/crypto/ssh` | yes | **yes** | `NewSignerFromSigner(crypto.Signer)` in `ssh/keys.go` 1203-1210, documented "for keys kept in hardware modules" |
| `swift-nio-ssh` | **no** | **no** | `NIOSSHPrivateKey` has an internal backing enum and a private init, `NIOSSHPrivateKey.swift` 20-42, 72-99 |

libssh2's callback hands back the *complete* SSH signature blob, not raw RSA
bytes: `src/userauth.c` 1647-1651 wraps it with `ssh2_store_str`. So the
application performs RSASSA-PKCS1-v1_5 with SHA-256 or SHA-512 per RFC 8332 and
encodes the negotiated algorithm name itself. The callback receives no hash or
padding argument, so our side must track the negotiated method.

### Ranked candidates

| | Licence | RSA | External signer | Latest release | Crypto backend | Swift burden |
|---|---|---|---|---|---|---|
| **russh** | Apache-2.0 | yes | yes | **v0.62.5, 2026-07-31** | self-contained (`aws-lc-rs` or `ring`) | Rust toolchain plus an FFI bridge |
| **libssh2** | BSD-3-Clause | yes | yes | 1.11.1, 2024-10-16 | **none native**: OpenSSL, wolfSSL, Libgcrypt or mbedTLS | C bridge plus a vendored crypto library |
| Go `x/crypto/ssh` | BSD-3-Clause | yes | yes, cleanest | tracks Go | Go standard library | embed the Go runtime; `c-archive` on darwin/arm64 UNVERIFIED |
| `swift-nio-ssh` | Apache-2.0 | **no** | **no** | 0.15.0, 2026-07-28 | `swift-crypto` | none, and it cannot do the job |
| libssh | **LGPL-2.1** | yes | — | — | — | legal review before it is a candidate |
| Citadel | MIT | no | no | — | — | depends on a *fork* of `swift-nio-ssh` at 0.3.x |

Two facts reorder this table against first impressions.

**russh is the actively maintained one.** Apache-2.0 in its `Cargo.toml`, v0.62.5
published 2026-07-31, latest commit the same day, and over a hundred commits in
the last twelve months. Compare `swift-nio-ssh`: one commit in the same period.
The Swift-native option is the dormant one.

**libssh2 carries two vendoring burdens, not one.** Its CMake `CRYPTO_BACKEND`
offers Libgcrypt, mbedTLS, OpenSSL, wolfSSL, or Windows-only WinCNG. There is no
Apple-native backend, so choosing libssh2 means vendoring a C SSH library *and* a
C crypto library into a sandboxed App Store binary. russh's crypto travels with
it.

## Keychain, iCloud, and the Secure Enclave

Relevant to **D-B**. From Apple's documentation.

**An SSH private key in the Keychain can sync over iCloud.** The
`kSecAttrSynchronizable` page states: "Starting in iOS 14, macOS 11, and watchOS
7, the keychain synchronizes passwords, certificates, and cryptographic keys."
`kSecClassKey` is in scope, so this is documented rather than hopeful. Ordinary
Keychain Services calls suffice; no iCloud entitlement is named. Sharing between
apps would need `kSecAttrAccessGroup` and the `keychain-access-groups`
entitlement, which Allward does not need.

Synchronizable items give up three things: no `kSecAttrAccessible` value whose
name ends in `ThisDeviceOnly`, no `SecAccess`-based access control, and no
persistent references.

**iCloud sync and the Secure Enclave are mutually exclusive.** Apple's Secure
Enclave page is explicit: it "can't encode preexisting keys. You must use the
Secure Enclave to create the keys", and "not having a mechanism to transfer
plain-text key data into or out of the Secure Enclave is fundamental to its
security". Only the creating enclave can use the key. A key that cannot leave one
chip cannot appear on another.

That resolves the preference between them, and it is stronger than a preference:

- The enclave **cannot hold any existing key**. Not the 16 RSA keys, not the 2
  Ed25519 ones. It creates its own keys and accepts no imports, and it does
  NIST P-256 only.
- So the enclave is not a later upgrade path for the keys anyone already has. It
  applies solely to a newly generated P-256 key, whose public half would then
  have to be installed on every host, and which could never sync.

Keychain items marked synchronizable are therefore the only option that works
with the keys that actually exist. The enclave remains worth offering for a
freshly generated key on a single machine, and it must be presented as a distinct
choice rather than as an improvement, because choosing it forfeits sync.

## russh integration, verified end to end

Decision 40 chose `russh`. Before any transport code depends on it, the seam was
built and run. Measured 2026-08-02 on macOS 26.5.2, Apple silicon:

| Step | Result |
|---|---|
| `russh = "0.62"` as a `staticlib` for `aarch64-apple-darwin` | builds, 33 s cold, 30.7 MB archive |
| Swift links the archive and calls it over the C ABI | works |
| RSA algorithms recognised | **3 of 3**: `rsa-sha2-256`, `rsa-sha2-512`, `ssh-rsa` |
| Stripped Swift binary | 4.5 MB |
| Libraries the result links | 9, and **every one already permitted** by `scripts/mas-isolation.json` |

The last row is the one that matters for MAS. The linked set is `libSystem`,
`Foundation`, and seven Swift runtime dylibs, all covered by the manifest's
existing `permitted_prefixes`. So adopting russh widens nothing: receipt 3 needs
no new entry, and no OpenSSL or extra framework arrives with it. That is the
concrete advantage over libssh2, which would have brought its own crypto library.

Two constraints this exposes:

- The machine's default toolchain is a nightly. `cargo +stable` was used, and the
  build must pin a stable toolchain rather than inherit whatever is default.
- The C header is **generated by `cbindgen` and committed**, with a receipt that
  regenerates it and diffs. See below.

### The C header is generated, and the drift check is proven

An earlier draft of this page argued for writing the header by hand, on the
grounds that the ABI is small and that `cbindgen` would be a build dependency.
Both halves were wrong.

The surface is not small. An SSH transport needs connect, a host-key callback, an
external-signer callback, PTY open and window-change, exec channels, read and
write, direct-tcpip forwarding, close, and error propagation: tens of functions
plus structs and callbacks passing byte buffers. That is precisely where a
hand-maintained header drifts from the Rust it describes, and an ABI mismatch
corrupts memory silently instead of failing to compile.

And `cbindgen` is not a build dependency in this design. It is a dev tool used to
generate a header that is then **committed and reviewed**, plus a receipt that
regenerates and diffs it. The build compiles the committed header and needs no
Rust tooling to read it.

Measured 2026-08-02:

| Step | Result |
|---|---|
| `cargo install cbindgen` | 0.29.4, **16 seconds** |
| generate the header | clean C, carries Rust doc comments through as Doxygen |
| Swift compiles and runs against the **generated** header | works, still 3 of 3 RSA |
| regenerate and diff an unchanged crate | reports no drift |
| add an `extern "C"` function, then diff | **caught it**, naming the new signature |

The last row is the point. A check nobody has watched fail is not a check, which
this session already learned once when two negative compile fixtures were failing
for an unrelated reason and reporting success. So the drift check was made to fail
on purpose before being trusted.

`uniffi` and `swift-bridge` were considered and rejected: both generate the Swift
side too, which means shipping generated code we do not control, and both impose a
framework where the requirement is one narrow, auditable boundary.

The RSA count is the empirical answer to the question that disqualified
`swift-nio-ssh`. The library that will hold the transport recognises every RSA
algorithm the measured key inventory needs.
