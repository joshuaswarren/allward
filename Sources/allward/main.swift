import AllwardChrome
import AppKit

// Allward is an AppKit application assembled from a SwiftPM executable rather
// than an Xcode project, so the entry point wires the delegate by hand and
// `scripts/make-app.sh` supplies the bundle.

let application = NSApplication.shared
let delegate = AllwardAppDelegate()
application.delegate = delegate
application.run()
