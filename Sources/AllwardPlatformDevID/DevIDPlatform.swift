import AllwardControl
import AllwardCore
import AllwardHerdr
import AllwardLocalPTY
import AllwardMultiplexer
import AllwardRemote
import AllwardSSH

/// The Developer ID product's platform: a real local shell, a herdr found by
/// reading the process table, and an AF_UNIX control socket.
///
/// This is the only module that may hold those capabilities. Shared code sees
/// `PlatformServices` and never imports `AllwardLocalPTY`, which is what makes
/// the MAS exclusion a fact about the link graph instead of a promise.
public struct DevIDPlatform: PlatformServices {
    /// Configured hosts, republished on every configuration reload.
    public let hosts = RemoteHostDirectory()

    public init() {}

    /// Local first: an unqualified destination is this machine, and asking SSH
    /// to consider it would be a round trip to nowhere.
    public var transports: [any RemoteTransport] {
        [LocalPTYTransport(), RusshTransport(hosts: hosts)]
    }

    public func startControlSocket(
        handler: any ControlRequestHandling
    ) throws -> (any ControlSocketServing)? {
        let host = ControlSocketHost()
        try host.start(handler: handler, at: ControlSocketHost.defaultPath())
        return host
    }

    /// A missing declaration can still resolve a herdr attached to one of our
    /// panes; an explicit declaration never consults discovery.
    public func makeMultiplexerAdapter(host: HostAlias?) -> any MultiplexerAdapter {
        guard let endpoint = HerdrProcessExecutor.endpoint(host: host) else {
            return NoMultiplexerAdapter()
        }
        return HerdrAdapter(client: HerdrProcessExecutor.makeClient(for: endpoint))
    }

    public func apply(hosts configured: [RemoteHost]) {
        hosts.replace(with: configured)
    }

    public func discoverAdapterHost() async -> HostAlias? {
        await HerdrDiscovery.attachedHost()
    }
}
