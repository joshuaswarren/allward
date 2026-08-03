import AllwardControl
import AllwardCore
import AllwardHerdr
import AllwardMultiplexer
import AllwardRemote
import AllwardSSH

/// The sandboxed product's platform: remote only.
///
/// Every difference from `DevIDPlatform` is a measured sandbox constraint rather
/// than a policy choice. See docs/evidence/SANDBOX.md.
public struct MASPlatform: PlatformServices {
    /// Configured hosts. A sandboxed product cannot read ~/.ssh/config, so this
    /// is the only place an alias resolves.
    public let hosts = RemoteHostDirectory()

    public init() {}

    /// Direct SSH and nothing else. Decision 5 makes MAS remote-only, and there
    /// is no reduced local shell to fall back to.
    public var transports: [any RemoteTransport] {
        [RusshTransport(hosts: hosts)]
    }

    /// None. A sandboxed product owns no listener path outside its container, and
    /// SPEC §2 keeps the listener module out of this graph. MCP reaches MAS over
    /// the connection the Room already holds, which is phase 4 work.
    public func startControlSocket(
        handler: any ControlRequestHandling
    ) throws -> (any ControlSocketServing)? {
        nil
    }

    /// A declared host only, reached by an SSH exec channel on the connection the
    /// Room already holds. Discovery is absent by design, so an undeclared Room
    /// yields the valid no-adapter state rather than a guess.
    public func makeMultiplexerAdapter(host: HostAlias?) -> any MultiplexerAdapter {
        guard let host else { return NoMultiplexerAdapter() }
        // `.ssh` always: there is no local herdr in a sandboxed product, so an
        // endpoint must never claim one.
        let endpoint = HerdrEndpoint(host: host, executionSite: .ssh)
        let executor = HerdrExecChannelExecutor(transport: RusshTransport(hosts: hosts))
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
