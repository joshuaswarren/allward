import AllwardCore
import Foundation

// The connection, PTY, byte-channel, control-channel, and forwarding facade of
// SPEC §5. `AllwardSSH` is one in-process implementation; the local PTY module
// implements the byte-channel half only.

/// What a transport is asked to open.
public struct RemoteDestination: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case localShell
        case ssh
    }

    public var kind: Kind
    /// Configured host alias for `ssh`; ignored for a local shell.
    public var host: HostAlias?
    /// Optional explicit command; `nil` runs the login shell.
    public var command: [String]?
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        kind: Kind,
        host: HostAlias? = nil,
        command: [String]? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.kind = kind
        self.host = host
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public static func localShell(
        workingDirectory: String? = nil, environment: [String: String] = [:]
    ) -> RemoteDestination {
        RemoteDestination(
            kind: .localShell, workingDirectory: workingDirectory, environment: environment)
    }

    public static func ssh(
        _ host: HostAlias, command: [String]? = nil, environment: [String: String] = [:]
    ) -> RemoteDestination {
        RemoteDestination(kind: .ssh, host: host, command: command, environment: environment)
    }

    /// The provenance string a pane header shows. Local and direct SSH are
    /// primary routes: neither ever carries a fallback badge.
    public var provenanceLabel: String {
        switch kind {
        case .localShell: "Local"
        case .ssh: host.map { "ssh \($0.rawValue)" } ?? "ssh"
        }
    }
}

/// A transport lifecycle event. Every active phase has a typed exit, so no
/// consumer can be left in `loading` (SPEC §5, DESIGN-LANGUAGE §18.10.2).
public enum RemoteEvent: Sendable {
    case state(ConnectionState, AttemptProgress?)
    case bytes(ArraySlice<UInt8>)
    case exited(code: Int32?)
    case failed(AllwardError)
}

/// One opened byte channel with a PTY on the far side.
public protocol RemoteChannel: AnyObject, Sendable {
    var id: ConnectionID { get }
    var destination: RemoteDestination { get }

    /// Ordered, bounded events for exactly this channel.
    var events: AsyncStream<RemoteEvent> { get }

    /// Write raw bytes to the far side. Input never waits on render coalescing.
    func write(_ bytes: [UInt8])

    /// Publish a new PTY window size.
    func resize(columns: Int, rows: Int)

    /// Close explicitly. This is the `closed(.explicit)` transition, which
    /// presents `empty` rather than an error.
    func close()
}

/// Opens channels. Implementations must respect the injected attempt bound and
/// must never retry past it silently.
public protocol RemoteTransport: Sendable {
    /// Whether this transport can serve the destination in this product target.
    func supports(_ destination: RemoteDestination) -> Bool

    func open(
        _ destination: RemoteDestination,
        geometry: (columns: Int, rows: Int),
        bound: AttemptBound
    ) async throws -> any RemoteChannel
}

/// A forwarded endpoint used by publishers to reach the app over SSH.
public struct ForwardedEndpoint: Hashable, Sendable {
    /// Remote path the publisher connects to, carried in its environment.
    public var remoteSocketPath: String
    /// Local receiver descriptor path this forwards into.
    public var localSocketPath: String
    public var host: HostAlias

    public init(remoteSocketPath: String, localSocketPath: String, host: HostAlias) {
        self.remoteSocketPath = remoteSocketPath
        self.localSocketPath = localSocketPath
        self.host = host
    }
}
