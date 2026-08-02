//! In-process SSH for Allward, behind a C ABI.
//!
//! Decision 40 chose russh because it speaks RSA and accepts an external signer.
//! Both matter here. A measured key inventory is mostly RSA, and decision 39 keeps
//! private keys inside Security.framework, so this library must be able to
//! authenticate without ever seeing key bytes.
//!
//! Shape of the boundary:
//!
//! * Swift owns policy. Host-key trust and signing are callbacks, because SPEC §14
//!   assigns both to us rather than to the protocol library.
//! * Rust owns the protocol and one tokio runtime. A session is an opaque handle
//!   plus a task that pumps channel events into the callbacks.
//! * Callbacks run on tokio worker threads, never on Swift's main actor. The Swift
//!   side is responsible for its own synchronisation.
//!
//! Every `extern "C"` function is null-safe: a null handle or a null required
//! string is a `false` return, never a panic across the ABI.

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use russh::client::{self, Handle};
use russh::keys::{load_secret_key, HashAlg, PrivateKeyWithHashAlg};
use russh::{ChannelMsg, Disconnect};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

/// Connection lifecycle, mirroring the Swift `ConnectionState` cases this
/// transport can actually report. Kept as plain integers so the ABI carries no
/// Rust layout.
pub const ALLWARD_SSH_STATE_CONNECTING: u32 = 0;
pub const ALLWARD_SSH_STATE_AUTHENTICATING: u32 = 1;
pub const ALLWARD_SSH_STATE_READY: u32 = 2;
pub const ALLWARD_SSH_STATE_CLOSED: u32 = 3;

/// Callbacks into Swift. `context` is passed back verbatim to every one.
///
/// `verify_host_key` returning false rejects the connection, which is how
/// first-use trust and a fingerprint mismatch both reach the user.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct AllwardSSHCallbacks {
    pub context: *mut c_void,
    pub on_state: extern "C" fn(*mut c_void, u32),
    pub on_data: extern "C" fn(*mut c_void, *const u8, usize),
    pub on_exit: extern "C" fn(*mut c_void, i32, bool),
    pub on_error: extern "C" fn(*mut c_void, *const c_char),
    pub verify_host_key:
        extern "C" fn(*mut c_void, *const c_char, *const c_char, *const u8, usize) -> bool,
}

// The context is a Swift object pointer that Swift keeps alive for the session's
// lifetime. Raw pointers are not Send, so the promise is made explicit here
// rather than silently by a cast.
unsafe impl Send for AllwardSSHCallbacks {}
unsafe impl Sync for AllwardSSHCallbacks {}

impl AllwardSSHCallbacks {
    fn state(&self, state: u32) {
        (self.on_state)(self.context, state);
    }

    fn data(&self, bytes: &[u8]) {
        (self.on_data)(self.context, bytes.as_ptr(), bytes.len());
    }

    fn exited(&self, code: Option<i32>) {
        (self.on_exit)(self.context, code.unwrap_or(0), code.is_some());
    }

    fn error(&self, message: &str) {
        // A message containing an interior NUL cannot cross as a C string; say so
        // rather than dropping the failure silently.
        let text = CString::new(message)
            .unwrap_or_else(|_| CString::new("ssh error message was not representable").unwrap());
        (self.on_error)(self.context, text.as_ptr());
    }
}

/// What to open. Strings are borrowed for the duration of the call only.
#[repr(C)]
pub struct AllwardSSHConfig {
    pub host: *const c_char,
    pub port: u16,
    pub user: *const c_char,
    /// `TERM` for the PTY request. Ignored when `want_pty` is false.
    pub term: *const c_char,
    pub columns: u32,
    pub rows: u32,
    /// Null runs the login shell. Non-null runs exactly this command, which is
    /// what the herdr executor needs.
    pub command: *const c_char,
    pub want_pty: bool,
    /// Developer ID reads a key file. MAS leaves this null and signs through the
    /// Keychain instead, which is why the library never requires key bytes.
    pub private_key_path: *const c_char,
    pub connect_timeout_ms: u64,
}

/// Commands Swift sends to a live session.
enum Command {
    Write(Vec<u8>),
    Resize { columns: u32, rows: u32 },
    Close,
}

/// An opaque live session. Swift holds this pointer and must free it exactly once.
pub struct AllwardSSHSession {
    commands: mpsc::UnboundedSender<Command>,
}

/// One runtime for every session. Sessions are long-lived and mostly idle, so a
/// shared multi-thread runtime costs less than a reactor per connection.
static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    Runtime::new().expect("the SSH transport could not start a tokio runtime")
});

/// Bridges russh's host-key check to Swift. russh hands us the server's key and
/// waits; we hand Swift the algorithm, the OpenSSH fingerprint, and the raw blob,
/// and Swift answers. No `known_hosts` file is consulted, by design: a sandboxed
/// product cannot read one, which docs/evidence/SANDBOX.md measured.
struct Client {
    callbacks: AllwardSSHCallbacks,
}

impl client::Handler for Client {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let algorithm = CString::new(server_public_key.algorithm().as_str())
            .unwrap_or_else(|_| CString::new("unknown").unwrap());
        let fingerprint = server_public_key
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();
        let fingerprint =
            CString::new(fingerprint).unwrap_or_else(|_| CString::new("unknown").unwrap());
        let blob = server_public_key.to_bytes().unwrap_or_default();
        let accepted = (self.callbacks.verify_host_key)(
            self.callbacks.context,
            algorithm.as_ptr(),
            fingerprint.as_ptr(),
            blob.as_ptr(),
            blob.len(),
        );
        Ok(accepted)
    }
}

/// Borrow a C string, or `None` when null. Invalid UTF-8 is a hard error rather
/// than a lossy conversion, because a mangled host name must not silently connect
/// somewhere else.
unsafe fn optional_str(pointer: *const c_char) -> Option<Result<String, ()>> {
    if pointer.is_null() {
        return None;
    }
    Some(
        CStr::from_ptr(pointer)
            .to_str()
            .map(|value| value.to_owned())
            .map_err(|_| ()),
    )
}

unsafe fn required_str(pointer: *const c_char) -> Result<String, ()> {
    optional_str(pointer).ok_or(())?
}

struct Opened {
    host: String,
    port: u16,
    user: String,
    term: String,
    columns: u32,
    rows: u32,
    command: Option<String>,
    want_pty: bool,
    private_key_path: Option<String>,
    connect_timeout: Duration,
}

/// Opens a session and returns a handle, or null on failure. Failures are also
/// reported through `on_error` so the Swift side has one place to surface them.
///
/// # Safety
/// `config` and its strings must be valid for the duration of the call.
/// `callbacks.context` must remain valid until the handle is freed.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_open(
    config: *const AllwardSSHConfig,
    callbacks: AllwardSSHCallbacks,
) -> *mut AllwardSSHSession {
    if config.is_null() {
        callbacks.error("ssh open was given no configuration");
        return std::ptr::null_mut();
    }
    let config = &*config;
    let parsed = (|| -> Result<Opened, &'static str> {
        Ok(Opened {
            host: required_str(config.host).map_err(|_| "host was not valid UTF-8")?,
            port: config.port,
            user: required_str(config.user).map_err(|_| "user was not valid UTF-8")?,
            term: match optional_str(config.term) {
                Some(Ok(value)) => value,
                Some(Err(())) => return Err("TERM was not valid UTF-8"),
                None => "xterm-256color".to_owned(),
            },
            columns: config.columns.max(1),
            rows: config.rows.max(1),
            command: match optional_str(config.command) {
                Some(Ok(value)) => Some(value),
                Some(Err(())) => return Err("command was not valid UTF-8"),
                None => None,
            },
            want_pty: config.want_pty,
            private_key_path: match optional_str(config.private_key_path) {
                Some(Ok(value)) => Some(value),
                Some(Err(())) => return Err("key path was not valid UTF-8"),
                None => None,
            },
            connect_timeout: Duration::from_millis(config.connect_timeout_ms.max(1)),
        })
    })();

    let opened = match parsed {
        Ok(opened) => opened,
        Err(reason) => {
            callbacks.error(reason);
            return std::ptr::null_mut();
        }
    };

    let (sender, receiver) = mpsc::unbounded_channel();
    RUNTIME.spawn(async move {
        if let Err(error) = run_session(opened, callbacks, receiver).await {
            callbacks.error(&error);
        }
        callbacks.state(ALLWARD_SSH_STATE_CLOSED);
    });

    Box::into_raw(Box::new(AllwardSSHSession { commands: sender }))
}

async fn authenticate(
    session: &mut Handle<Client>,
    opened: &Opened,
) -> Result<(), String> {
    let Some(path) = opened.private_key_path.as_deref() else {
        return Err(
            "no credential was supplied: this build authenticates with a key file, and the \
             Keychain signer is phase 5 work"
                .to_owned(),
        );
    };
    let key = load_secret_key(path, None).map_err(|error| format!("{path}: {error}"))?;
    // The server decides which RSA hash it will accept, and asking is the
    // difference between working with a 4096-bit RSA key and being refused.
    let hash: Option<HashAlg> = session
        .best_supported_rsa_hash()
        .await
        .map_err(|error| format!("{error}"))?
        .flatten();
    let result = session
        .authenticate_publickey(
            opened.user.clone(),
            PrivateKeyWithHashAlg::new(Arc::new(key), hash),
        )
        .await
        .map_err(|error| format!("{error}"))?;
    if result.success() {
        Ok(())
    } else {
        Err("the server rejected the key".to_owned())
    }
}

async fn run_session(
    opened: Opened,
    callbacks: AllwardSSHCallbacks,
    mut commands: mpsc::UnboundedReceiver<Command>,
) -> Result<(), String> {
    callbacks.state(ALLWARD_SSH_STATE_CONNECTING);
    let config = Arc::new(client::Config {
        inactivity_timeout: None,
        ..Default::default()
    });
    let handler = Client { callbacks };
    let address = (opened.host.clone(), opened.port);
    let mut session = tokio::time::timeout(
        opened.connect_timeout,
        client::connect(config, address, handler),
    )
    .await
    .map_err(|_| format!("{}:{} did not answer in time", opened.host, opened.port))?
    .map_err(|error| format!("{}:{}: {error}", opened.host, opened.port))?;

    callbacks.state(ALLWARD_SSH_STATE_AUTHENTICATING);
    authenticate(&mut session, &opened).await?;

    let mut channel = session
        .channel_open_session()
        .await
        .map_err(|error| format!("{error}"))?;

    if opened.want_pty {
        channel
            .request_pty(
                false,
                &opened.term,
                opened.columns,
                opened.rows,
                0,
                0,
                &[],
            )
            .await
            .map_err(|error| format!("{error}"))?;
    }

    match opened.command.as_deref() {
        Some(command) => channel
            .exec(true, command)
            .await
            .map_err(|error| format!("{error}"))?,
        None => channel
            .request_shell(true)
            .await
            .map_err(|error| format!("{error}"))?,
    }

    callbacks.state(ALLWARD_SSH_STATE_READY);

    let mut exit_code: Option<i32> = None;
    loop {
        tokio::select! {
            command = commands.recv() => {
                match command {
                    Some(Command::Write(bytes)) => {
                        if channel.data(&bytes[..]).await.is_err() { break; }
                    }
                    Some(Command::Resize { columns, rows }) => {
                        // A failed window change is not fatal: the session keeps
                        // running at the old size, which beats dropping it.
                        let _ = channel.window_change(columns, rows, 0, 0).await;
                    }
                    // An explicit close is `closed(.explicit)` on the Swift side and
                    // must not read as an error.
                    Some(Command::Close) | None => break,
                }
            }
            message = channel.wait() => {
                match message {
                    Some(ChannelMsg::Data { ref data }) => callbacks.data(data),
                    Some(ChannelMsg::ExtendedData { ref data, .. }) => callbacks.data(data),
                    Some(ChannelMsg::ExitStatus { exit_status }) => {
                        exit_code = Some(exit_status as i32);
                    }
                    // `Eof` means the far side stopped writing, not that the
                    // channel is done. Breaking here loses `ExitStatus` when the
                    // server sends it after EOF, which cost the exit code the
                    // herdr executor reads. Wait for the channel to actually
                    // close, or for `wait()` to run dry.
                    Some(ChannelMsg::Eof) => {}
                    Some(ChannelMsg::Close) | None => break,
                    Some(_) => {}
                }
            }
        }
    }

    callbacks.exited(exit_code);
    let _ = session
        .disconnect(Disconnect::ByApplication, "", "English")
        .await;
    Ok(())
}

/// Writes bytes to the far side. Returns false when the session has gone.
///
/// # Safety
/// `session` must be a handle from `allward_ssh_open` that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_write(
    session: *mut AllwardSSHSession,
    bytes: *const u8,
    len: usize,
) -> bool {
    if session.is_null() || (bytes.is_null() && len != 0) {
        return false;
    }
    let session = &*session;
    let payload = if len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(bytes, len).to_vec()
    };
    session.commands.send(Command::Write(payload)).is_ok()
}

/// Publishes a new PTY window size.
///
/// # Safety
/// `session` must be a live handle from `allward_ssh_open`.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_resize(
    session: *mut AllwardSSHSession,
    columns: u32,
    rows: u32,
) -> bool {
    if session.is_null() {
        return false;
    }
    (&*session)
        .commands
        .send(Command::Resize {
            columns: columns.max(1),
            rows: rows.max(1),
        })
        .is_ok()
}

/// Asks the session to close. The task reports `on_exit` and then the closed
/// state; the handle stays valid until freed.
///
/// # Safety
/// `session` must be a live handle from `allward_ssh_open`.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_close(session: *mut AllwardSSHSession) -> bool {
    if session.is_null() {
        return false;
    }
    (&*session).commands.send(Command::Close).is_ok()
}

/// Frees the handle. Idempotent only in the sense that null is accepted; calling
/// it twice on the same pointer is undefined, as with any Box.
///
/// # Safety
/// `session` must come from `allward_ssh_open` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_free(session: *mut AllwardSSHSession) {
    if session.is_null() {
        return;
    }
    drop(Box::from_raw(session));
}

/// Number of RSA signature algorithms this build recognises. Three means
/// `rsa-sha2-256`, `rsa-sha2-512`, and `ssh-rsa`, which is what a mostly-RSA key
/// inventory needs. Cheap enough to assert at startup.
#[no_mangle]
pub extern "C" fn allward_ssh_rsa_algorithm_count() -> u32 {
    ["rsa-sha2-256", "rsa-sha2-512", "ssh-rsa"]
        .iter()
        .filter(|name| russh::keys::Algorithm::new(name).is_ok())
        .count() as u32
}
