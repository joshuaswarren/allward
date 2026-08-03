import AllwardChrome
import AllwardCore
import AllwardPlatformDevID
import AppKit
import Foundation

// Allward is an AppKit application assembled from a SwiftPM executable rather
// than an Xcode project, so the entry point wires the delegate by hand and
// `scripts/make-app.sh` supplies the bundle.
//
// The product chooses its platform here, and this is the only place it can be
// chosen. `AllwardPlatformDevID` is what makes this the Developer ID build: a
// local shell, process-table herdr discovery, and an AF_UNIX control socket.

// `--version` answers "is this the build I just made" without opening a window,
// which is what a script or an ssh session needs. It prints the same facts the
// About panel shows, from the same source, so the two cannot disagree.
if CommandLine.arguments.contains("--version") {
    print(BuildInfo.current.plainText)
    exit(0)
}

let application = NSApplication.shared
let delegate = AllwardAppDelegate(platform: DevIDPlatform())
application.delegate = delegate
application.run()
