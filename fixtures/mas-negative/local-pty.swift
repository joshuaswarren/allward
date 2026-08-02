// Negative fixture: local child PTY must not be visible to the MAS product.
//
// scripts/mas-isolation-receipts.py compiles this against the module search
// path of the MAS target closure and requires the compile to FAIL. A successful
// compile means `AllwardLocalPTY` is reachable and MAS is not remote-only.
//
// It names a public type rather than only the import so that a stale
// `.swiftmodule` left in a scratch directory cannot make the fixture pass by
// accident: the type has to resolve too.

import AllwardLocalPTY

func forbidden() -> LocalPTYTransport.Type {
    LocalPTYTransport.self
}
