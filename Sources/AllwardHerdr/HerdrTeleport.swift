import AllwardCore
import AllwardMultiplexer
import Foundation

public enum HerdrTeleportReference: Hashable, Sendable {
    case board(recordID: String)
    case router(sessionID: String)
}

public struct HerdrTeleportDestination: Hashable, Sendable {
    public var host: HostAlias
    public var workspace: String
    public var paneID: String

    public init(host: HostAlias, workspace: String, paneID: String) {
        self.host = host
        self.workspace = workspace
        self.paneID = paneID
    }

    public var displayLabel: String {
        "\(host.rawValue) · \(workspace) · \(paneID)"
    }
}

public struct PreparedHerdrTeleport: Hashable, Sendable {
    public var lockToken: UUID
    public var reference: HerdrTeleportReference
    public var destination: HerdrTeleportDestination
    public var session: AdapterSession
    public var routeSelection: HerdrRouteSelection
    public var attachArgv: [String]

    public init(
        lockToken: UUID,
        reference: HerdrTeleportReference,
        destination: HerdrTeleportDestination,
        session: AdapterSession,
        routeSelection: HerdrRouteSelection,
        attachArgv: [String]
    ) {
        self.lockToken = lockToken
        self.reference = reference
        self.destination = destination
        self.session = session
        self.routeSelection = routeSelection
        self.attachArgv = attachArgv
    }
}

public struct CommittedHerdrTeleport: Hashable, Sendable {
    public var destination: HerdrTeleportDestination
    public var session: AdapterSession
    public var routeSelection: HerdrRouteSelection
    public var attachArgv: [String]

    public init(prepared: PreparedHerdrTeleport) {
        self.destination = prepared.destination
        self.session = prepared.session
        self.routeSelection = prepared.routeSelection
        self.attachArgv = prepared.attachArgv
    }
}

public enum HerdrTeleportError: Error, Hashable, Sendable, CustomStringConvertible {
    case preparationAlreadyLocked
    case destinationUnavailable(HerdrTeleportDestination)
    case preparedDestinationChanged

    public var description: String {
        switch self {
        case .preparationAlreadyLocked:
            "A teleport destination is already shown and input-locked"
        case .destinationUnavailable(let destination):
            "No herdr session matches \(destination.displayLabel)"
        case .preparedDestinationChanged:
            "The committed teleport does not match the shown, locked destination"
        }
    }
}

public typealias HerdrTeleportResolver = @Sendable (
    HerdrTeleportReference,
    AttemptBound
) async throws -> HerdrTeleportDestination

public actor HerdrTeleport {
    private let adapter: HerdrAdapter
    private let resolver: HerdrTeleportResolver
    private var pending: PreparedHerdrTeleport?

    public init(adapter: HerdrAdapter, resolver: @escaping HerdrTeleportResolver) {
        self.adapter = adapter
        self.resolver = resolver
    }

    public var isInputLocked: Bool { pending != nil }

    public var preparedDestination: HerdrTeleportDestination? { pending?.destination }

    public func prepare(
        _ reference: HerdrTeleportReference,
        bound: AttemptBound
    ) async throws -> PreparedHerdrTeleport {
        guard pending == nil else { throw HerdrTeleportError.preparationAlreadyLocked }
        let destination = try await resolver(reference, bound)
        guard let session = await adapter.session(
            host: destination.host,
            workspace: destination.workspace,
            paneID: destination.paneID
        ) else {
            throw HerdrTeleportError.destinationUnavailable(destination)
        }
        let selection = await adapter.selection(for: session)
        let prepared = PreparedHerdrTeleport(
            lockToken: UUID(),
            reference: reference,
            destination: destination,
            session: session,
            routeSelection: selection,
            attachArgv: adapter.attachCommand(for: session, route: selection.route)
        )
        pending = prepared
        return prepared
    }

    public func commit(
        _ prepared: PreparedHerdrTeleport,
        bound: AttemptBound
    ) async throws -> CommittedHerdrTeleport {
        guard let pending, pending == prepared else {
            throw HerdrTeleportError.preparedDestinationChanged
        }
        try await adapter.focus(session: pending.session, bound: bound)
        self.pending = nil
        return CommittedHerdrTeleport(prepared: pending)
    }

    public func cancel(_ prepared: PreparedHerdrTeleport) throws {
        guard pending == prepared else { throw HerdrTeleportError.preparedDestinationChanged }
        pending = nil
    }
}
