# Theory: Room-scoped herdr connections

## Problem

Allward's herdr integration is a Room setting, but the old discovery path treated herdr as a process that might be found in any pane. That makes a clean configuration impossible to connect from the UI and collapses separate Room workspaces onto whichever host happens to be declared first. A user needs to declare a server for the current Room without a local herdr executable or terminal command.

## Operating theory

The durable boundary is the Room's `herdrHost`, represented by the existing adapter-server reference and host alias. Settings updates already copy the configuration, mutate it, write it, and hand it to the runtime. The missing leverage point is therefore a settings update that resolves the active Room by ID and uses `Room.connectedToHerdr`. A newly typed host must also become a `HostConfiguration`: the Room claims its alias, and configuration validation rejects unconfigured aliases.

Projection must receive the active Room explicitly. Runtime health is still useful, but it is secondary to the Room's declared connection. The Integrations row should state the Room and server together, expose the current value, and provide both typed input and configured aliases. The Board's empty state should invoke the same Room-scoped input flow rather than sending the user to a read-only settings page.

## Strategy

Keep persistence in the existing settings-update path. Normalize empty input to disconnect, reject aliases already owned by another Room before the write, and name the owning Room in the error. Keep the generic SSH picker unchanged; the herdr picker is a dedicated surface because it must accept an alias or `user@host` even when no hosts are configured. The Board action and Settings control both emit the same `setHerdrHost` update.

## Key discoveries

`Room.connectedToHerdr` already maintains both adapter-server and host-alias state, so duplicating that mutation would risk drift. However, its host-alias claim means typed hosts require an accompanying host configuration before `Configuration.validate()` can succeed. The existing adapter projection has no active-Room parameter, so a global health label cannot honestly identify the current server; the projection now derives its detail and editable value from the active Room.

## Open questions

Swift compilation and UI execution remain the orchestrator's responsibility on macOS. The source-level contract is covered by tests for active-Room mutation, disconnect, and per-Room projection values.
