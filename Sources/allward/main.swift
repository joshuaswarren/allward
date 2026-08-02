import AllwardChrome
import AllwardPlatformDevID
import AppKit

// Allward is an AppKit application assembled from a SwiftPM executable rather
// than an Xcode project, so the entry point wires the delegate by hand and
// `scripts/make-app.sh` supplies the bundle.
//
// The product chooses its platform here, and this is the only place it can be
// chosen. `AllwardPlatformDevID` is what makes this the Developer ID build: a
// local shell, process-table herdr discovery, and an AF_UNIX control socket.

let application = NSApplication.shared
let delegate = AllwardAppDelegate(platform: DevIDPlatform())
application.delegate = delegate
application.run()
