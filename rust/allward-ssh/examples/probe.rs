//! Exercises the C ABI against a real SSH server, the way Swift will.
//!
//! Run it as:
//!
//! ```sh
//! cargo run --release --example probe -- <host> <user> <key-path> "<command>"
//! ```
//!
//! It exists because a library that compiles proves nothing about a protocol. The
//! only claim worth making is that a real server accepted a real key and returned
//! real bytes, so this drives `allward_ssh_open` and prints what came back.

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use allward_ssh::*;
use parking_lot::Mutex;

/// Collected stdout and stderr from the far side.
static OUTPUT: LazyLock<Mutex<Vec<u8>>> = LazyLock::new(|| Mutex::new(Vec::new()));
/// The exit report, as `(code, had_code)`.
static FINISHED: LazyLock<Mutex<Option<(i32, bool)>>> = LazyLock::new(|| Mutex::new(None));
/// Anything the transport reported through `on_error`.
static ERRORS: LazyLock<Mutex<Vec<String>>> = LazyLock::new(|| Mutex::new(Vec::new()));

extern "C" fn on_state(_context: *mut c_void, state: u32) {
    let name = match state {
        ALLWARD_SSH_STATE_CONNECTING => "connecting",
        ALLWARD_SSH_STATE_AUTHENTICATING => "authenticating",
        ALLWARD_SSH_STATE_READY => "ready",
        ALLWARD_SSH_STATE_CLOSED => "closed",
        _ => "unknown",
    };
    println!("state: {name}");
}

extern "C" fn on_data(_context: *mut c_void, bytes: *const u8, len: usize) {
    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    OUTPUT.lock().extend_from_slice(slice);
}

extern "C" fn on_exit(_context: *mut c_void, code: i32, has_code: bool) {
    *FINISHED.lock() = Some((code, has_code));
}

extern "C" fn on_error(_context: *mut c_void, message: *const c_char) {
    let text = unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned();
    ERRORS.lock().push(text);
}

extern "C" fn verify_host_key(
    _context: *mut c_void,
    algorithm: *const c_char,
    fingerprint: *const c_char,
    _blob: *const u8,
    blob_len: usize,
) -> bool {
    let algorithm = unsafe { CStr::from_ptr(algorithm) }.to_string_lossy();
    let fingerprint = unsafe { CStr::from_ptr(fingerprint) }.to_string_lossy();
    println!("host key: {algorithm} {fingerprint} ({blob_len} bytes)");
    // A probe trusts on sight. Swift does not: SPEC §14 puts host trust in the
    // application, which is the whole reason this is a callback.
    true
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: probe <host> <user> <key-path> <command>");
        std::process::exit(2);
    }

    println!("rsa algorithms recognised: {}", allward_ssh_rsa_algorithm_count());

    let host = CString::new(args[1].clone()).unwrap();
    let user = CString::new(args[2].clone()).unwrap();
    let key = CString::new(args[3].clone()).unwrap();
    let command = CString::new(args[4].clone()).unwrap();
    let term = CString::new("xterm-256color").unwrap();

    let config = AllwardSSHConfig {
        host: host.as_ptr(),
        port: 22,
        user: user.as_ptr(),
        term: term.as_ptr(),
        columns: 80,
        rows: 24,
        command: command.as_ptr(),
        want_pty: true,
        private_key_path: key.as_ptr(),
        connect_timeout_ms: 10_000,
    };

    let callbacks = AllwardSSHCallbacks {
        context: std::ptr::null_mut(),
        on_state,
        on_data,
        on_exit,
        on_error,
        verify_host_key,
    };

    let session = unsafe { allward_ssh_open(&config, callbacks) };
    if session.is_null() {
        eprintln!("open failed: {:?}", ERRORS.lock());
        std::process::exit(1);
    }

    let deadline = Instant::now() + Duration::from_secs(20);
    while FINISHED.lock().is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }

    let exit = *FINISHED.lock();
    let collected = String::from_utf8_lossy(&OUTPUT.lock()).into_owned();
    let failures = ERRORS.lock().clone();

    unsafe {
        allward_ssh_close(session);
        allward_ssh_free(session);
    }

    println!("--- output ---");
    print!("{collected}");
    println!("--- end ---");
    println!("exit: {exit:?}");
    if !failures.is_empty() {
        println!("errors: {failures:?}");
    }

    match exit {
        Some(_) if collected.contains("ALLWARD_SSH_WORKS") => {
            println!("PROBE_OK");
        }
        _ => {
            eprintln!("PROBE_FAILED");
            std::process::exit(1);
        }
    }
}
