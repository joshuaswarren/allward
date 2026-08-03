import AllwardCore
import AllwardHerdr
import AllwardRemote
import Foundation

/// Runs herdr commands as SSH exec channels instead of child processes.
///
/// Phase 4 of docs/MAS-PLAN.md. `HerdrEndpoint` still describes the command; only
/// execution changes, so the adapter, the Board, and the Settings connect controls
/// are untouched. A sandboxed product cannot launch `ssh`, and it does not need to:
/// it already has a connection to the host, and an exec channel on it is cheaper
/// than a fresh handshake per command, which is what the Developer ID process
/// executor pays today.
///
/// `HerdrExecutionSite.local` has no meaning here. There is no local herdr to
/// reach, so an endpoint claiming one is refused rather than quietly translated.
public struct HerdrExecChannelExecutor: Sendable {
    private let transport: any RemoteTransport
    private let bound: AttemptBound

    public init(transport: any RemoteTransport, bound: AttemptBound = .controlRequest) {
        self.transport = transport
        self.bound = bound
    }

    /// A `HerdrCommandExecutor` bound to one endpoint.
    public func executor(for endpoint: HerdrEndpoint) -> HerdrCommandExecutor {
        { [transport, bound] argv in
            guard endpoint.executionSite == .ssh else {
                throw AllwardError(
                    domain: .adapter,
                    operation: "run herdr command",
                    cause: "a sandboxed product has no local herdr to execute against",
                    retryability: .nonretryable,
                    recovery: "Declare the Room's herdr server so it is reached over SSH."
                )
            }
            guard let command = endpoint.remoteCommand(from: argv) else {
                throw AllwardError(
                    domain: .adapter,
                    operation: "run herdr command",
                    cause: "the herdr argv was not the shape this endpoint produces",
                    retryability: .nonretryable,
                    recovery: "This is a defect: report the Room's adapter configuration."
                )
            }
            return try await Self.run(
                command: command, on: endpoint.host, transport: transport, bound: bound)
        }
    }

    /// Opens an exec channel, collects its output, and returns when it exits.
    ///
    /// Cancellation closes the channel: `HerdrCommandExecutor` requires an executor
    /// to terminate the work it owns, and a leaked channel would hold a remote
    /// process open for the life of the connection.
    private static func run(
        command: [String],
        on host: HostAlias,
        transport: any RemoteTransport,
        bound: AttemptBound
    ) async throws -> Data {
        let channel = try await transport.open(
            .ssh(host, command: command),
            geometry: (columns: 200, rows: 50),
            bound: bound
        )
        return try await withTaskCancellationHandler {
            var collected = Data()
            for await event in channel.events {
                switch event {
                case let .bytes(slice):
                    collected.append(contentsOf: slice)
                case .exited:
                    channel.close()
                    return collected
                case let .failed(error):
                    channel.close()
                    throw error
                case .state:
                    continue
                }
            }
            // The stream finished without an exit report, which means the connection
            // went away mid-command. Returning what arrived would look like a short
            // but successful answer, and the client would treat it as truth.
            throw AllwardError(
                domain: .adapter,
                operation: "run herdr command",
                cause: "the exec channel closed before the command reported an exit",
                retryability: .retryable,
                recovery: "Check the connection to \(host.rawValue) and try again."
            )
        } onCancel: {
            channel.close()
        }
    }
}
