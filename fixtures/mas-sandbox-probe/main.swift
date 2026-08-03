// Measures what App Sandbox actually permits on this machine.
//
// SPEC section 14 leaves ssh-agent access, security-scoped key-file access, and
// entitlements "probe-gated", and says plainly that Apple's documentation
// "does not prove the needed credential route". Decision D-B in
// docs/MAS-PLAN.md cannot be argued from documentation, so this measures it.
//
// This is the capability subset of OQ-14, not OQ-14. OQ-14 additionally requires
// import, unlock, use, rotation, deletion, host-key first use and mismatch, log
// and crash-artifact inspection, with throwaway keys, in both products. Phase 5
// owns that. Run with fixtures/mas-sandbox-probe/run.sh, which signs this into a
// sandboxed bundle first; run unsigned it measures nothing.

import Darwin
import Foundation
import Security

enum Verdict: String {
    case permitted = "PERMITTED"
    case denied = "DENIED"
    case absent = "ABSENT"
    case inconclusive = "INCONCLUSIVE"
}

var findings: [(name: String, verdict: Verdict, detail: String)] = []

func record(_ name: String, _ verdict: Verdict, _ detail: String) {
    findings.append((name, verdict, detail))
}

func realHomeDirectory() -> String {
    // NSHomeDirectory() returns the container under sandbox, so the real home
    // has to come from the password database to test access to it at all.
    guard let entry = getpwuid(getuid()) else { return "" }
    return String(cString: entry.pointee.pw_dir)
}

// 1. Is the sandbox actually applied? Every other result is void if not.
let containerHome = NSHomeDirectory()
record(
    "sandbox container",
    containerHome.contains("/Library/Containers/") ? .permitted : .absent,
    containerHome.contains("/Library/Containers/")
        ? "container home in use"
        : "NOT SANDBOXED: home is the real home, so this run proves nothing"
)

// 2. ssh-agent. The variable may be inherited even when the socket is unreachable,
//    so presence and reachability are separate facts.
if let agentPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
    record("SSH_AUTH_SOCK in environment", .permitted, "inherited")
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    if descriptor < 0 {
        record("ssh-agent connect", .denied, "socket(AF_UNIX) failed: \(errno)")
    } else {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(agentPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            if bytes.count <= storage.count { storage.copyBytes(from: bytes) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, size)
            }
        }
        let failure = errno
        close(descriptor)
        record(
            "ssh-agent connect",
            connected == 0 ? .permitted : .denied,
            connected == 0 ? "connected" : "errno \(failure) \(String(cString: strerror(failure)))"
        )
    }
} else {
    record("SSH_AUTH_SOCK in environment", .absent, "not inherited")
    record("ssh-agent connect", .absent, "no socket path to try")
}

// 3 and 4. Unmediated reads of the user's own ssh material. A sandboxed product
//          cannot resolve ~/.ssh/config host aliases if this is denied.
let home = realHomeDirectory()
for name in [".ssh/config", ".ssh/known_hosts"] {
    let path = "\(home)/\(name)"
    let exists = FileManager.default.fileExists(atPath: path)
    if !exists {
        record("read ~/\(name)", .inconclusive, "file does not exist on this machine")
        continue
    }
    let descriptor = open(path, O_RDONLY)
    let failure = errno
    if descriptor >= 0 {
        close(descriptor)
        record("read ~/\(name)", .permitted, "opened for reading")
    } else {
        record("read ~/\(name)", .denied, "errno \(failure) \(String(cString: strerror(failure)))")
    }
}

// 5. Shared /tmp, which SPEC section 2 forbids shared code to assume.
let temporary = "/tmp/allward-sandbox-probe-\(getpid())"
if FileManager.default.createFile(atPath: temporary, contents: Data("probe".utf8)) {
    try? FileManager.default.removeItem(atPath: temporary)
    record("write /tmp", .permitted, "created and removed a file")
} else {
    record("write /tmp", .denied, "errno \(errno) \(String(cString: strerror(errno)))")
}

// 6. Launching the system ssh client. The plan assumed the sandbox forbids this.
//    Measure it rather than assume, and measure the thing that actually decides
//    the question: whether a child inherits the sandbox. `ssh -V` needs no files
//    and no network, so it succeeding proves very little on its own.
let launch = Process()
launch.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
launch.arguments = ["-V"]
launch.standardOutput = FileHandle.nullDevice
launch.standardError = FileHandle.nullDevice
do {
    try launch.run()
    launch.waitUntilExit()
    record("launch /usr/bin/ssh", .permitted, "exited \(launch.terminationStatus)")
} catch {
    record("launch /usr/bin/ssh", .denied, "\(error)")
}

// 6b. Can that child read what a real ssh session needs? If the child inherits
//     the sandbox, spawning ssh buys nothing: it starts and then cannot read the
//     config, the known_hosts file, or any key.
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/cat")
child.arguments = ["\(home)/.ssh/config"]
child.standardOutput = FileHandle.nullDevice
child.standardError = FileHandle.nullDevice
do {
    try child.run()
    child.waitUntilExit()
    let readIt = child.terminationStatus == 0
    record(
        "child reads ~/.ssh/config",
        readIt ? .permitted : .denied,
        readIt
            ? "child escaped the parent's file restrictions"
            : "child inherited the sandbox; exit \(child.terminationStatus)"
    )
} catch {
    record("child reads ~/.ssh/config", .denied, "could not launch /bin/cat: \(error)")
}

// 7. Keychain, the proposed home for imported keys.
let service = "ai.allward.sandbox-probe"
let secret = Data("probe-secret".utf8)
let attributes: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: "probe",
    kSecValueData as String: secret,
]
SecItemDelete(attributes as CFDictionary)
let addStatus = SecItemAdd(attributes as CFDictionary, nil)
if addStatus == errSecSuccess {
    var item: CFTypeRef?
    let readStatus = SecItemCopyMatching(
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
            kSecReturnData as String: true,
        ] as CFDictionary,
        &item
    )
    let round_tripped = (item as? Data) == secret
    record(
        "keychain add and read",
        readStatus == errSecSuccess && round_tripped ? .permitted : .denied,
        "add ok, read status \(readStatus), value matched \(round_tripped)"
    )
    SecItemDelete(attributes as CFDictionary)
} else {
    record("keychain add and read", .denied, "SecItemAdd status \(addStatus)")
}

// 7b. The same round trip with `kSecAttrSynchronizable`, which is the attribute
//     decision 39 actually rests on. It is probed separately because it needs the
//     data-protection keychain, and that is a different permission from ordinary
//     keychain access: 7 can pass while this fails.
let syncService = "ai.allward.sandbox-probe.sync"
let syncQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: syncService,
    kSecAttrAccount as String: "probe",
    kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
    kSecUseDataProtectionKeychain as String: true,
]
var syncAdd = syncQuery
syncAdd[kSecValueData as String] = secret
SecItemDelete(syncQuery as CFDictionary)
let syncStatus = SecItemAdd(syncAdd as CFDictionary, nil)
if syncStatus == errSecSuccess {
    var item: CFTypeRef?
    var read = syncQuery
    read[kSecReturnData as String] = true
    let readStatus = SecItemCopyMatching(read as CFDictionary, &item)
    let matched = (item as? Data) == secret
    record(
        "keychain synchronizable (iCloud)",
        readStatus == errSecSuccess && matched ? .permitted : .denied,
        "add ok, read status \(readStatus), value matched \(matched)"
    )
    SecItemDelete(syncQuery as CFDictionary)
} else {
    let message = SecCopyErrorMessageString(syncStatus, nil) as String? ?? "?"
    record(
        "keychain synchronizable (iCloud)", .denied,
        "SecItemAdd status \(syncStatus): \(message)")
}

// 8. Outgoing TCP, which com.apple.security.network.client is supposed to allow.
//    A refused connection still proves the syscall was permitted; the sandbox
//    denies with EPERM instead, so the two are distinguishable.
let outgoing = socket(AF_INET, SOCK_STREAM, 0)
if outgoing < 0 {
    record("outgoing TCP", .denied, "socket(AF_INET) failed: \(errno)")
} else {
    var destination = sockaddr_in()
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = UInt16(22).bigEndian
    destination.sin_addr.s_addr = inet_addr("127.0.0.1")
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafePointer(to: &destination) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(outgoing, $0, size)
        }
    }
    let failure = errno
    close(outgoing)
    if result == 0 {
        record("outgoing TCP", .permitted, "connected to loopback 22")
    } else if failure == EPERM || failure == EACCES {
        record("outgoing TCP", .denied, "errno \(failure) \(String(cString: strerror(failure)))")
    } else {
        record(
            "outgoing TCP",
            .permitted,
            "syscall allowed; connection failed with errno \(failure) "
                + String(cString: strerror(failure))
        )
    }
}

print("Allward sandbox capability probe")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("")
let width = findings.map(\.name.count).max() ?? 0
for finding in findings {
    let name = finding.name.padding(toLength: width, withPad: " ", startingAt: 0)
    print("\(name)  \(finding.verdict.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0))  \(finding.detail)")
}
