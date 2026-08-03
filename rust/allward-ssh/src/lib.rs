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

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{mpsc as std_mpsc, Arc, LazyLock};
use std::time::Duration;

use russh::client::{self, Handle};
use russh::keys::{load_secret_key, HashAlg, PrivateKeyWithHashAlg};
use russh::{ChannelMsg, ChannelReadHalf, ChannelWriteHalf, Disconnect};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

type ForwardReply<T> = std_mpsc::Sender<T>;

/// Connection lifecycle, mirroring the Swift `ConnectionState` cases this
/// transport can actually report. Kept as plain integers so the ABI carries no
/// Rust layout.
pub const ALLWARD_SSH_STATE_CONNECTING: u32 = 0;
pub const ALLWARD_SSH_STATE_AUTHENTICATING: u32 = 1;
pub const ALLWARD_SSH_STATE_READY: u32 = 2;
pub const ALLWARD_SSH_STATE_CLOSED: u32 = 3;

/// Callbacks into Swift. `context` is passed back verbatim to every one.
///
#[derive(Clone, Copy)]
#[repr(C)]
pub struct AllwardSSHCallbacks {
    pub context: *mut c_void,
    pub on_state: extern "C" fn(*mut c_void, u32),
    pub on_data: extern "C" fn(*mut c_void, *const u8, usize),
    pub on_exit: extern "C" fn(*mut c_void, i32, bool),
    pub on_error: extern "C" fn(*mut c_void, *const c_char),
    pub verify_host_key:
        extern "C" fn(*mut c_void, *const c_char, *const c_char, *const u8, usize) -> bool,
    pub on_forward_open:
        Option<extern "C" fn(*mut c_void, u64, *const c_char, u16)>,
    pub on_forward_data: Option<extern "C" fn(*mut c_void, u64, *const u8, usize)>,
    pub on_forward_close: Option<extern "C" fn(*mut c_void, u64)>,
    /// Signs `to_sign` with the private half of the configured public key, and
    /// writes an SSH signature blob to `out_signature`/`out_len`. Returns false to
    /// fail authentication.
    pub sign: Option<
        extern "C" fn(
            *mut c_void,
            *const c_char,
            *const u8,
            usize,
            *mut *mut u8,
            *mut usize,
        ) -> bool,
    >,
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
    fn forward_open(&self, stream: u64, origin_host: &str, origin_port: u16) {
        let Some(callback) = self.on_forward_open else { return };
        let Ok(origin_host) = CString::new(origin_host) else { return };
        callback(self.context, stream, origin_host.as_ptr(), origin_port);
    }

    fn forward_data(&self, stream: u64, bytes: &[u8]) {
        if let Some(callback) = self.on_forward_data {
            callback(self.context, stream, bytes.as_ptr(), bytes.len());
        }
    }

    fn forward_close(&self, stream: u64) {
        if let Some(callback) = self.on_forward_close {
            callback(self.context, stream);
        }
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
    /// The public half, in OpenSSH one-line form ("ssh-rsa AAAA..."), used with the
    /// `sign` callback. The server needs to know which identity is being offered;
    /// only the signature itself requires the private half.
    pub public_key_openssh: *const c_char,
    pub connect_timeout_ms: u64,
}

enum Command {
    Write(Vec<u8>),
    Resize { columns: u32, rows: u32 },
    Close,
    ForwardRemoteOpen {
        host: String,
        port: u16,
        reply: ForwardReply<Result<(), String>>,
    },
    ForwardRemoteClose {
        host: String,
        port: u16,
        reply: ForwardReply<Result<(), String>>,
    },
    ForwardLocalOpen {
        host: String,
        port: u16,
        reply: ForwardReply<Result<u64, String>>,
    },
    ForwardWrite {
        stream: u64,
        bytes: Vec<u8>,
        reply: ForwardReply<bool>,
    },
    ForwardClose {
        stream: u64,
        reply: ForwardReply<bool>,
    },
}

enum ForwardEvent {
    Opened {
        channel: russh::Channel<client::Msg>,
        origin_host: String,
        origin_port: u32,
    },
    Data { stream: u64, bytes: Vec<u8> },
    Closed { stream: u64 },
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
struct Client {
    callbacks: AllwardSSHCallbacks,
    forward_events: mpsc::UnboundedSender<ForwardEvent>,
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
    #[allow(clippy::too_many_arguments)]
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<client::Msg>,
        _connected_address: &str,
        _connected_port: u32,
        originator_address: &str,
        originator_port: u32,
        reply: client::ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        let _ = self.forward_events.send(ForwardEvent::Opened {
            channel,
            origin_host: originator_address.to_owned(),
            origin_port: originator_port,
        });
        Ok(())
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
    public_key_openssh: Option<String>,
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
            public_key_openssh: match optional_str(config.public_key_openssh) {
                Some(Ok(value)) => Some(value),
                Some(Err(())) => return Err("public key was not valid UTF-8"),
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
    let (forward_sender, forward_receiver) = mpsc::unbounded_channel();
    RUNTIME.spawn(async move {
        if let Err(error) =
            run_session(opened, callbacks, receiver, forward_sender.clone(), forward_receiver).await
        {
            callbacks.error(&error);
        }
        callbacks.state(ALLWARD_SSH_STATE_CLOSED);
    });

    Box::into_raw(Box::new(AllwardSSHSession { commands: sender }))
}

async fn authenticate(
    session: &mut Handle<Client>,
    opened: &Opened,
    callbacks: AllwardSSHCallbacks,
) -> Result<(), String> {
    // The external signer comes first. When it is present the private key is in
    // Security.framework or the Secure Enclave and this library must never ask for
    // bytes it is not allowed to have.
    if let (Some(sign), Some(public_key)) = (callbacks.sign, opened.public_key_openssh.as_deref()) {
        return authenticate_with_signer(session, opened, public_key, sign, callbacks).await;
    }
    let Some(path) = opened.private_key_path.as_deref() else {
        return Err(
            "no credential was supplied: give a key file, or a public key plus a signer"
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

/// The signer declined. russh's signer error type carries a transport or key
/// failure, and a refusal is neither, so it is reported as a key error with the
/// reason the credential store already surfaced through `on_error`.
fn signer_refused() -> russh::AgentAuthError {
    russh::AgentAuthError::Key(russh::keys::Error::KeyIsCorrupt)
}

/// Signs by asking Swift, so the private key never enters this process's control.
///
/// russh hands us the exact bytes to sign and the negotiated hash algorithm, and
/// expects back the SSH signature blob. Both are passed straight through: deciding
/// what a signature means is the credential store's job, and duplicating that
/// decision here would be a second place to get it wrong.
struct DelegatedSigner {
    callbacks: AllwardSSHCallbacks,
}

impl russh::Signer for DelegatedSigner {
    type Error = russh::AgentAuthError;

    async fn auth_sign(
        &mut self,
        _key: &russh::keys::agent::AgentIdentity,
        hash_alg: Option<HashAlg>,
        to_sign: Vec<u8>,
    ) -> Result<Vec<u8>, Self::Error> {
        let Some(sign) = self.callbacks.sign else {
            return Err(signer_refused());
        };
        // The algorithm name the server will see. RFC 8332 ties the hash to the
        // name, so telling Swift the name is telling it which digest to use.
        let algorithm = match hash_alg {
            Some(HashAlg::Sha512) => "rsa-sha2-512",
            Some(HashAlg::Sha256) => "rsa-sha2-256",
            None => "ssh-ed25519",
            _ => "rsa-sha2-256",
        };
        let algorithm = CString::new(algorithm).map_err(|_| signer_refused())?;

        let mut buffer: *mut u8 = std::ptr::null_mut();
        let mut length: usize = 0;
        let ok = sign(
            self.callbacks.context,
            algorithm.as_ptr(),
            to_sign.as_ptr(),
            to_sign.len(),
            &mut buffer,
            &mut length,
        );
        if !ok || buffer.is_null() || length == 0 {
            return Err(signer_refused());
        }
        // Copy before freeing: the caller allocated it and we own it now.
        let blob = unsafe { std::slice::from_raw_parts(buffer, length) }.to_vec();
        unsafe { allward_ssh_free_buffer(buffer, length) };

        // russh expects the buffer it handed us with the signature appended, wrapped
        // in one more SSH string, exactly as its own agent client does. Framing is a
        // russh convention, so it lives here rather than in the credential store,
        // whose contract stays "return a signature blob".
        let mut signed = to_sign;
        signed.extend_from_slice(&(blob.len() as u32).to_be_bytes());
        signed.extend_from_slice(&blob);
        Ok(signed)
    }
}

async fn authenticate_with_signer(
    session: &mut Handle<Client>,
    opened: &Opened,
    public_key_openssh: &str,
    _sign: extern "C" fn(
        *mut c_void,
        *const c_char,
        *const u8,
        usize,
        *mut *mut u8,
        *mut usize,
    ) -> bool,
    callbacks: AllwardSSHCallbacks,
) -> Result<(), String> {
    let public_key: russh::keys::ssh_key::PublicKey = public_key_openssh
        .parse()
        .map_err(|error| format!("the configured public key did not parse: {error}"))?;
    // Ask the server which RSA hash it accepts before signing with one it will
    // refuse; the same call is what makes a 4096-bit RSA key work at all.
    let hash: Option<HashAlg> = session
        .best_supported_rsa_hash()
        .await
        .map_err(|error| format!("{error}"))?
        .flatten();
    let mut signer = DelegatedSigner { callbacks };
    let result = session
        .authenticate_publickey_with(opened.user.clone(), public_key, hash, &mut signer)
        .await
        .map_err(|error| format!("{error}"))?;
    if result.success() {
        Ok(())
    } else {
        Err("the server rejected the signed identity".to_owned())
    }
}

/// Allocates a buffer the `sign` callback fills. Swift must use this rather than
/// `malloc` so the allocator that frees it is the one that made it.
///
/// # Safety
/// The returned pointer is valid for `length` bytes, or null when `length` is zero.
#[no_mangle]
pub extern "C" fn allward_ssh_allocate(length: usize) -> *mut u8 {
    if length == 0 {
        return std::ptr::null_mut();
    }
    let mut buffer = vec![0u8; length];
    let pointer = buffer.as_mut_ptr();
    std::mem::forget(buffer);
    pointer
}

/// Frees a buffer from `allward_ssh_allocate`.
///
/// # Safety
/// `pointer` and `length` must be exactly what `allward_ssh_allocate` returned.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_free_buffer(pointer: *mut u8, length: usize) {
    if pointer.is_null() || length == 0 {
        return;
    }
    drop(Vec::from_raw_parts(pointer, length, length));
}

fn spawn_forward_reader(
    mut reader: ChannelReadHalf,
    stream: u64,
    events: mpsc::UnboundedSender<ForwardEvent>,
) {
    RUNTIME.spawn(async move {
        while let Some(message) = reader.wait().await {
            match message {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                    if events
                        .send(ForwardEvent::Data {
                            stream,
                            bytes: data.to_vec(),
                        })
                        .is_err()
                    {
                        return;
                    }
                }
                ChannelMsg::Close => break,
                ChannelMsg::Eof => {}
                _ => {}
            }
        }
        let _ = events.send(ForwardEvent::Closed { stream });
    });
}

async fn run_session(
    opened: Opened,
    callbacks: AllwardSSHCallbacks,
    mut commands: mpsc::UnboundedReceiver<Command>,
    forward_sender: mpsc::UnboundedSender<ForwardEvent>,
    mut forward_events: mpsc::UnboundedReceiver<ForwardEvent>,
) -> Result<(), String> {
    callbacks.state(ALLWARD_SSH_STATE_CONNECTING);
    let config = Arc::new(client::Config {
        inactivity_timeout: None,
        ..Default::default()
    });
    let handler = Client {
        callbacks,
        forward_events: forward_sender.clone(),
    };
    let address = (opened.host.clone(), opened.port);
    let mut session = tokio::time::timeout(
        opened.connect_timeout,
        client::connect(config, address, handler),
    )
    .await
    .map_err(|_| format!("{}:{} did not answer in time", opened.host, opened.port))?
    .map_err(|error| format!("{}:{}: {error}", opened.host, opened.port))?;

    callbacks.state(ALLWARD_SSH_STATE_AUTHENTICATING);
    authenticate(&mut session, &opened, callbacks).await?;

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
    let mut next_stream = 1u64;
    let mut forward_streams: HashMap<u64, ChannelWriteHalf<client::Msg>> = HashMap::new();
    loop {
        tokio::select! {
            command = commands.recv() => {
                match command {
                    Some(Command::Write(bytes)) => {
                        if channel.data(&bytes[..]).await.is_err() { break; }
                    }
                    Some(Command::Resize { columns, rows }) => {
                        let _ = channel.window_change(columns, rows, 0, 0).await;
                    }
                    Some(Command::ForwardRemoteOpen { host, port, reply }) => {
                        let result = session
                            .tcpip_forward(host, u32::from(port))
                            .await
                            .map(|_| ())
                            .map_err(|error| format!("{error}"));
                        let _ = reply.send(result);
                    }
                    Some(Command::ForwardRemoteClose { host, port, reply }) => {
                        let result = session
                            .cancel_tcpip_forward(host, u32::from(port))
                            .await
                            .map_err(|error| format!("{error}"));
                        let _ = reply.send(result);
                    }
                    Some(Command::ForwardLocalOpen { host, port, reply }) => {
                        let result = session
                            .channel_open_direct_tcpip(host, port as u32, "127.0.0.1", 0)
                            .await
                            .map_err(|error| format!("{error}"))
                            .map(|channel| {
                                let stream = next_stream;
                                next_stream = next_stream.saturating_add(1).max(1);
                                let (reader, writer) = channel.split();
                                forward_streams.insert(stream, writer);
                                spawn_forward_reader(reader, stream, forward_sender.clone());
                                callbacks.forward_open(stream, "127.0.0.1", 0);
                                stream
                            });
                        let _ = reply.send(result);
                    }
                    Some(Command::ForwardWrite { stream, bytes, reply }) => {
                        let ok = match forward_streams.get(&stream) {
                            Some(writer) => writer.data(&bytes[..]).await.is_ok(),
                            None => false,
                        };
                        let _ = reply.send(ok);
                    }
                    Some(Command::ForwardClose { stream, reply }) => {
                        let ok = if let Some(writer) = forward_streams.remove(&stream) {
                            writer.close().await.is_ok()
                        } else {
                            false
                        };
                        if ok { callbacks.forward_close(stream); }
                        let _ = reply.send(ok);
                    }
                    Some(Command::Close) | None => break,
                }
            }
            event = forward_events.recv() => {
                match event {
                    Some(ForwardEvent::Opened { channel, origin_host, origin_port }) => {
                        let stream = next_stream;
                        next_stream = next_stream.saturating_add(1).max(1);
                        let (reader, writer) = channel.split();
                        forward_streams.insert(stream, writer);
                        spawn_forward_reader(reader, stream, forward_sender.clone());
                        callbacks.forward_open(stream, &origin_host, origin_port.min(u32::from(u16::MAX)) as u16);
                    }
                    Some(ForwardEvent::Data { stream, bytes }) => {
                        if forward_streams.contains_key(&stream) {
                            callbacks.forward_data(stream, &bytes);
                        }
                    }
                    Some(ForwardEvent::Closed { stream }) => {
                        if forward_streams.remove(&stream).is_some() {
                            callbacks.forward_close(stream);
                        }
                    }
                    None => {}
                }
            }
            message = channel.wait() => {
                match message {
                    Some(ChannelMsg::Data { ref data }) => callbacks.data(data),
                    Some(ChannelMsg::ExtendedData { ref data, .. }) => callbacks.data(data),
                    Some(ChannelMsg::ExitStatus { exit_status }) => {
                        exit_code = Some(exit_status as i32);
                    }
                    Some(ChannelMsg::Eof) => {}
                    Some(ChannelMsg::Close) | None => break,
                    Some(_) => {}
                }
            }
        }
    }

    for (stream, writer) in forward_streams {
        let _ = writer.close().await;
        callbacks.forward_close(stream);
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

const FORWARD_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

fn receive_forward_reply<T>(receiver: std_mpsc::Receiver<T>, fallback: T) -> T {
    receiver
        .recv_timeout(FORWARD_COMMAND_TIMEOUT)
        .unwrap_or(fallback)
}

/// Asks the server to listen on a TCP address and forward new connections to
/// this client.
///
/// # Safety
/// `session` must be live and `bind_host` must be a valid NUL-terminated UTF-8
/// string.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_forward_remote_open(
    session: *mut AllwardSSHSession,
    bind_host: *const c_char,
    bind_port: u16,
) -> bool {
    if session.is_null() {
        return false;
    }
    let Ok(host) = required_str(bind_host) else { return false };
    let (reply, receiver) = std_mpsc::channel();
    if (&*session)
        .commands
        .send(Command::ForwardRemoteOpen {
            host,
            port: bind_port,
            reply,
        })
        .is_err()
    {
        return false;
    }
    receive_forward_reply(receiver, Err("forward request timed out".to_owned()))
        .is_ok()
}

/// Cancels a TCP address the server was asked to listen on.
///
/// # Safety
/// `session` must be live and `bind_host` must be a valid NUL-terminated UTF-8
/// string.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_forward_remote_close(
    session: *mut AllwardSSHSession,
    bind_host: *const c_char,
    bind_port: u16,
) -> bool {
    if session.is_null() {
        return false;
    }
    let Ok(host) = required_str(bind_host) else { return false };
    let (reply, receiver) = std_mpsc::channel();
    if (&*session)
        .commands
        .send(Command::ForwardRemoteClose {
            host,
            port: bind_port,
            reply,
        })
        .is_err()
    {
        return false;
    }
    receive_forward_reply(receiver, Err("forward cancellation timed out".to_owned()))
        .is_ok()
}

/// Opens a direct-tcpip channel through the server.
///
/// Returns a non-zero stream id, or zero when the channel could not be opened.
///
/// # Safety
/// `session` must be live and `target_host` must be a valid NUL-terminated UTF-8
/// string.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_forward_local_open(
    session: *mut AllwardSSHSession,
    target_host: *const c_char,
    target_port: u16,
) -> u64 {
    if session.is_null() {
        return 0;
    }
    let Ok(host) = required_str(target_host) else { return 0 };
    let (reply, receiver) = std_mpsc::channel();
    if (&*session)
        .commands
        .send(Command::ForwardLocalOpen {
            host,
            port: target_port,
            reply,
        })
        .is_err()
    {
        return 0;
    }
    receive_forward_reply(
        receiver,
        Err("direct-tcpip channel open timed out".to_owned()),
    )
    .unwrap_or(0)
}

/// Writes bytes to a direct-tcpip or reverse-forward stream.
///
/// # Safety
/// `session` must be live, and `bytes` must be valid for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_forward_write(
    session: *mut AllwardSSHSession,
    stream: u64,
    bytes: *const u8,
    len: usize,
) -> bool {
    if session.is_null() || stream == 0 || (bytes.is_null() && len != 0) {
        return false;
    }
    let payload = if len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(bytes, len).to_vec()
    };
    let (reply, receiver) = std_mpsc::channel();
    if (&*session)
        .commands
        .send(Command::ForwardWrite {
            stream,
            bytes: payload,
            reply,
        })
        .is_err()
    {
        return false;
    }
    receive_forward_reply(receiver, false)
}

/// Closes a direct-tcpip or reverse-forward stream.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn allward_ssh_forward_close(
    session: *mut AllwardSSHSession,
    stream: u64,
) -> bool {
    if session.is_null() || stream == 0 {
        return false;
    }
    let (reply, receiver) = std_mpsc::channel();
    if (&*session)
        .commands
        .send(Command::ForwardClose { stream, reply })
        .is_err()
    {
        return false;
    }
    receive_forward_reply(receiver, false)
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
