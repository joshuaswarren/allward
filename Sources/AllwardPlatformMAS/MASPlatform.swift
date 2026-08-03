import AllwardControl
import AllwardCore
import AllwardHerdr
import AllwardMultiplexer
import AllwardRemote
import AllwardSSH
import Foundation

/// The sandboxed product's platform: remote only.
///
/// Every difference from `DevIDPlatform` is a measured sandbox constraint rather
/// than a policy choice. See docs/evidence/SANDBOX.md.
public struct MASPlatform: PlatformServices {
    /// Configured hosts. A sandboxed product cannot read ~/.ssh/config, so this
    /// is the only place an alias resolves.
    public let hosts = RemoteHostDirectory()
    /// Decision 39: keys in the Keychain. Syncing is requested but refused for
    /// want of a provisioned entitlement, so keys do not leave this Mac yet.
    public let credentials = KeychainCredentialStore()
    /// Pins survive relaunch, or trust on first use re-trusts a changed key on the
    /// next launch, which is the attack it exists to notice.
    public let hostTrust: DurableHostTrust

    public init() {
        // NSHomeDirectory() is the container under App Sandbox, which
        // docs/evidence/SANDBOX.md measured as the only writable home here.
        hostTrust = DurableHostTrust(
            url: DurableHostTrust.defaultURL(
                inContainer: URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support/Allward", isDirectory: true)
            ))
    }

    /// Direct SSH and nothing else. Decision 5 makes MAS remote-only, and there
    /// is no reduced local shell to fall back to.
    public var transports: [any RemoteTransport] {
        [RusshTransport(hosts: hosts, hostTrust: hostTrust, credentials: credentials)]
    }

    /// Starts the control socket inside the App Group container, if one is
    /// configured.
    ///
    /// Option A for sandboxed MCP. `allward-mcp` is spawned by the client outside
    /// the sandbox, so it can reach the group container; the app binds the socket
    /// inside it, avoiding the need for `inherit` on a bundled helper. If the
    /// build carries no App Group (e.g. built by a stranger without a team ID),
    /// this returns nil and the product degrades gracefully to no MCP.
    public func startControlSocket(
        handler: any ControlRequestHandling
    ) throws -> (any ControlSocketServing)? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AllwardAppGroup") as? String,
              !group.isEmpty else {
            return nil
        }
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        guard let container = url else { return nil }
        let path = container.appendingPathComponent("app.sock").path
        let host = MASControlSocketHost()
        try host.start(handler: handler, at: path)
        return host
    }

    /// A declared host only, reached by an SSH exec channel on the connection the
    /// Room already holds. Discovery is absent by design, so an undeclared Room
    /// yields the valid no-adapter state rather than a guess.
    public func makeMultiplexerAdapter(host: HostAlias?) -> any MultiplexerAdapter {
        guard let host else { return NoMultiplexerAdapter() }
        // `.ssh` always: there is no local herdr in a sandboxed product, so an
        // endpoint must never claim one.
        let endpoint = HerdrEndpoint(host: host, executionSite: .ssh)
        let executor = HerdrExecChannelExecutor(
            transport: RusshTransport(
                hosts: hosts, hostTrust: hostTrust, credentials: credentials))
        return HerdrAdapter(
            client: HerdrSocketClient(
                endpoint: endpoint, executor: executor.executor(for: endpoint)))
    }

    /// Publishes the configured hosts an alias resolves against.
    public func apply(hosts configured: [RemoteHost]) {
        hosts.replace(with: configured)
    }

    /// Never. Discovery reads the process table, which this product must not do,
    /// so a Room's server is declared in Settings or on the Board.
    public func discoverAdapterHost() async -> HostAlias? { nil }
}
