import AllwardChrome
import AllwardPlatformMAS
import AppKit
import Foundation

// The MAS product of decision 5: sandboxed, remote-only, built from the same
// revision as the Developer ID app.
//
// `AllwardPlatformMAS` is what makes this the sandboxed build. It offers direct
// SSH and nothing else: no local shell, no control-socket listener, and no
// process-table discovery, so a Room's server is declared rather than found.
//
// It still refuses to launch. `AllwardSSH` opens sessions by launching
// `/usr/bin/ssh`, so this binary would spawn a child even though the platform
// offers no local shell, and a product labelled MAS must not. Phase 2 of
// docs/MAS-PLAN.md replaces that transport with russh; this refusal and the
// `exit` below are deleted in the same change.

let platform = MASPlatform()

let message = """
allward-mas cannot launch yet: the SSH transport still spawns a process.

The platform is already correct. MASPlatform offers \(platform.transports.count) \
transport(s), no control-socket listener, and no process-table discovery. What is \
missing is underneath it: AllwardSSH opens a session by launching /usr/bin/ssh.

To see what remains:

    python3 scripts/mas-isolation-receipts.py

docs/MAS-PLAN.md phase 2 puts russh behind the RemoteTransport facade. This \
entry point becomes the application in that change.

"""

FileHandle.standardError.write(Data(message.utf8))
exit(78)  // EX_CONFIG: the configuration is wrong, not the invocation.
