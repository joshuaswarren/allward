# Apple platform and MCP evidence

Sources: linked Apple and Model Context Protocol primary sources, checked 2026-07-29.

## Apple platform

| Area | Verified fact | Source |
|---|---|---|
| App Sandbox | Mac App Store distribution requires App Sandbox. | <https://developer.apple.com/documentation/security/app-sandbox> |
| Program access | A sandboxed app can run programs in its container; user-selected-file entitlements do not authorize programs outside the app bundle/container/app groups. | <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox> |
| Helper | A sandboxed embedded CLI helper uses App Sandbox plus `com.apple.security.inherit`; extra entitlements may cause problems. | <https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app> |
| Network | `com.apple.security.network.client` permits outgoing connections, including to another machine. | <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client> |
| Swift concurrency | New Xcode 26 projects enable approachable-concurrency features; Swift 6 language mode supplies compile-time data-race safety. | <https://developer.apple.com/videos/play/wwdc2025/270/> |
| Display pacing | `CAMetalDisplayLink` supports variable-rate displays and best-effort callbacks. Smoothness can improve; fixed frame-rate or energy savings are not guaranteed. | <https://developer.apple.com/documentation/quartzcore/cametaldisplaylink> |
| Foundation Models | `SystemLanguageModel` is on-device on macOS 26+, but availability depends on device, region, and model readiness. | <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel> |
| Speech | `SpeechAnalyzer` is an async actor on macOS 26+; one analyzer handles one input sequence at a time. | <https://developer.apple.com/documentation/speech/speechanalyzer> |
| Focus | `SetFocusFilterIntent` adapts app behavior when Focus changes; available macOS 13+. | <https://developer.apple.com/documentation/appintents/setfocusfilterintent> |
| Accessibility | Custom/non-`NSView` UI can be represented by `NSAccessibilityElement` and role-specific protocols. No automatic Metal-pixel semantic extraction is documented. | <https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class>, <https://developer.apple.com/documentation/appkit/custom-controls> |
| MetricKit | Daily macOS 26 metrics and immediate diagnostics are supported. Apple pages conflict on older daily-metric support. `MetalFrameRateMetric` is macOS 27+, not macOS 26. | <https://developer.apple.com/documentation/metrickit>, <https://developer.apple.com/documentation/metrickit/mxmetricmanager>, <https://developer.apple.com/documentation/metrickit/metalframeratemetric> |

## MCP revision compatibility

- `2026-07-28` exists and is GA. Receipts:
  <https://github.com/modelcontextprotocol/modelcontextprotocol/tree/main/schema/2026-07-28>,
  <https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/blog/content/posts/2026-07-28-spec-ga/index.md>.
- Legacy `2024-11-05` begins with `initialize`; a server returns the requested
  supported version or another supported version, followed by
  `notifications/initialized`.
  Source: <https://modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle>.
- Modern `2026-07-28` has no negotiation handshake. Each request carries its
  version in `_meta` and, over HTTP, `MCP-Protocol-Version`. Unsupported
  versions return `UnsupportedProtocolVersionError` with supported versions.
  Servers must implement `server/discover`; clients may call it.
  Sources: <https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning>,
  <https://modelcontextprotocol.io/specification/2026-07-28/server/discover>.
- The modern spec calls 2026-07-28+ modern and 2025-11-25-and-earlier legacy.
  Modern-only and legacy-only peers do not interoperate. A dual-era stdio
  client probes `server/discover` and falls back only on a non-modern error;
  HTTP fallback inspects the 400 response body. A recognized modern JSON-RPC
  error means retry a supported modern revision, not legacy fallback.
- 2026-07-28 removes the modern `initialize`/`initialized` exchange and
  `Mcp-Session-Id`, moves identity/capabilities/version to per-request `_meta`,
  and deprecates Roots, Sampling, Logging, and legacy HTTP+SSE with the stated
  transition window.

## Unknowns / constraints

- Do not claim `CAMetalDisplayLink` guarantees lower power; measure it.
- Do not use macOS 27 `MetalFrameRateMetric` in the macOS 26 design.
- Foundation Models and SpeechAnalyzer need explicit unavailable-state UX.
- A Metal terminal requires an explicit AppKit accessibility projection.
- Supporting both MCP eras requires two real protocol paths, not version echo.
