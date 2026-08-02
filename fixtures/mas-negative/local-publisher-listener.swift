// Negative fixture: the app-owned AF_UNIX listener must not be visible to the
// MAS product.
//
// scripts/mas-isolation-receipts.py requires this compile to FAIL. A sandboxed
// product owns no listener path, and SPEC section 2 places
// `AllwardLocalPublisherEndpoint` outside the MAS link graph. MAS publishers
// arrive over reverse SSH instead.

import AllwardLocalPublisherEndpoint

func forbidden() -> LocalPublisherEndpoint.Type {
    LocalPublisherEndpoint.self
}
