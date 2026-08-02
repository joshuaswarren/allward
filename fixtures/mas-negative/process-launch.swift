// Negative fixture: no process-launching executor may be visible to the MAS
// product.
//
// scripts/mas-isolation-receipts.py requires this compile to FAIL, and requires
// the diagnostic to name `HerdrProcessExecutor`. That executor runs the herdr
// argv through a child process, which a sandboxed remote-only product must not
// do. Phase 4 of docs/MAS-PLAN.md gives MAS an SSH exec channel instead, and
// phase 3 moves this type into the Developer ID platform module.
//
// Foundation's own `Process` cannot be excluded by compiling: it is always
// importable. Nor does the sandbox block the spawn. Measured on macOS 26.5.2,
// App Sandbox permits launching `/usr/bin/ssh`; the child simply inherits the
// sandbox and starves. See docs/evidence/SANDBOX.md. So this fixture proves the
// absence of Allward's own launcher, and receipt 2 additionally scans the MAS
// closure's sources for the raw process-launch APIs the manifest forbids.

import AllwardChrome

func forbidden() -> HerdrProcessExecutor.Type {
    HerdrProcessExecutor.self
}
