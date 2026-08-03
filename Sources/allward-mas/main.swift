import AllwardChrome
import AllwardCore
import AllwardPlatformMAS
import AppKit
import Foundation

// The MAS product of decision 5: sandboxed, remote-only, built from the same
// revision as the Developer ID app.
//
// It launches. Until phase 2 of docs/MAS-PLAN.md it refused, because the SSH
// transport opened sessions by launching `/usr/bin/ssh` and a product labelled MAS
// must not spawn a child. russh replaced that, and receipts 1 and 2 now pass: no
// local PTY, no publisher listener, and no process launcher is reachable from this
// binary's graph.
//
// `AllwardPlatformMAS` is what makes this the sandboxed build. It offers direct SSH
// and nothing else: no local shell, no process-table discovery, and a control
// socket that binds strictly inside an app group container rather than /tmp.

// Same as the Developer ID product: `--version` reports the build without opening
// a window, which is how a synced test build gets checked over ssh.
if CommandLine.arguments.contains("--version") {
    print(BuildInfo.current.plainText)
    exit(0)
}

let application = NSApplication.shared
let delegate = AllwardAppDelegate(platform: MASPlatform())
application.delegate = delegate
application.run()
