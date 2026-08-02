import Foundation

// The MAS product of decision 5: sandboxed, remote-only, built from the same
// revision as the Developer ID app.
//
// It refuses to launch. The shared graph still reaches `AllwardLocalPTY`
// through `AllwardSSH`, `AllwardControl`, and `AllwardChrome`, so this binary
// cannot honestly claim to be remote-only, and a product labelled MAS that
// offered a local shell is the one thing MAS must never be. Phase 3 of
// docs/MAS-PLAN.md moves that code behind injected protocols; this refusal is
// deleted in the same change that makes a real launch possible.
//
// The `AllwardChrome` dependency is declared in Package.swift and deliberately
// not imported here. Declaring it is what gives receipt 1 a graph to resolve,
// and that receipt is the measure of this phase.

let message = """
allward-mas cannot launch: MAS isolation is unproven.

The shared module graph still reaches AllwardLocalPTY, so this binary cannot \
claim to be remote-only. To see the current graph and what still violates it:

    python3 scripts/mas-isolation-receipts.py

docs/MAS-PLAN.md phase 3 relocates local platform code behind protocols \
declared in shared code. This entry point becomes the application when \
receipt 1 reports no forbidden target.

"""

FileHandle.standardError.write(Data(message.utf8))
exit(78)  // EX_CONFIG: the configuration is wrong, not the invocation.
