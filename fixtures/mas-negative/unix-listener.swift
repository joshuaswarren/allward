// Negative fixture: the app's own AF_UNIX control listener must not be visible
// to the MAS product.
//
// scripts/mas-isolation-receipts.py requires this compile to FAIL, and requires
// the diagnostic to name `ControlSocketHost`. It binds and listens on a socket
// path, which is the capability SPEC section 2 forbids shared code to assume.
// Connecting a client socket inside the container stays permitted, so the
// manifest forbids `bind`, `listen`, and `accept` rather than `socket`.

import AllwardChrome

func forbidden() -> ControlSocketHost.Type {
    ControlSocketHost.self
}
