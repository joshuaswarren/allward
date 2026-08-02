import AllwardControl
import AllwardCore
import AllwardDesign
import AllwardMultiplexer
import AllwardRemote
import AllwardRooms
import XCTest

@testable import AllwardChrome

/// A Room's adapter is built once and kept. Revisiting a Room must not tear its
/// connection down and rebuild it, because Rooms are workspaces people move
/// between constantly.
///
/// This exercises `RoomAdapters` against a stub platform rather than a real herdr
/// adapter, which is the point: after the phase 3 split `AllwardChrome` builds no
/// adapter itself, so a test that named `HerdrAdapter` here would be asserting
/// something Chrome is no longer allowed to do.
final class RoomAdaptersTests: XCTestCase {
    /// Names each adapter after the host it was built for, so the test can tell
    /// them apart, and counts builds so retention is observable.
    private final class RecordingPlatform: PlatformServices, @unchecked Sendable {
        private(set) var requestedHosts: [HostAlias?] = []
        private(set) var discoveryCalls = 0

        var transports: [any RemoteTransport] { [] }

        func startControlSocket(
            handler: any ControlRequestHandling
        ) throws -> (any ControlSocketServing)? { nil }

        func makeMultiplexerAdapter(host: HostAlias?) -> any MultiplexerAdapter {
            requestedHosts.append(host)
            return NamedAdapter(name: host?.rawValue ?? "none")
        }

        func discoverAdapterHost() async -> HostAlias? {
            discoveryCalls += 1
            return nil
        }
    }

    private final class NamedAdapter: MultiplexerAdapter {
        let displayName: String
        init(name: String) { displayName = name }
        var capabilities: AdapterCapabilities { .none }
        var health: AdapterHealth { get async { .none } }
        var events: AsyncStream<AdapterEvent> { AsyncStream { $0.finish() } }
        func start() async {}
        func stop() async {}
        func listSessions(bound: AttemptBound) async throws -> [AdapterSession] { [] }
        func route(for session: AdapterSession) async -> AdapterContentRoute { .ordinarySSH }
        func focus(session: AdapterSession, bound: AttemptBound) async throws {}
        func attachCommand(
            for session: AdapterSession, route: AdapterContentRoute
        ) -> [String] { [] }
    }

    func testEachRoomUsesAndRetainsItsOwnAdapter() async throws {
        let roomA = Room(
            name: "A", baseTint: TokenColor(hex: "#5aa0ff")!, terminalThemeName: "Allward Night"
        ).connectedToHerdr(HostAlias("alpha"))
        let roomB = Room(
            name: "B", baseTint: TokenColor(hex: "#3ecde8")!, terminalThemeName: "Allward Night"
        ).connectedToHerdr(HostAlias("beta"))
        let switchable = SwitchableAdapter()
        let platform = RecordingPlatform()
        let coordinator = RoomAdapters(switchable: switchable, platform: platform)

        await coordinator.activate(roomA)
        let adapterA = try XCTUnwrap(switchable.current as? NamedAdapter)
        XCTAssertEqual(adapterA.displayName, "alpha")

        await coordinator.activate(roomB)
        let adapterB = try XCTUnwrap(switchable.current as? NamedAdapter)
        XCTAssertEqual(adapterB.displayName, "beta")
        XCTAssertFalse(adapterA === adapterB)

        await coordinator.activate(roomA)
        let returnedA = try XCTUnwrap(switchable.current as? NamedAdapter)
        XCTAssertTrue(returnedA === adapterA)
        XCTAssertEqual(
            platform.requestedHosts.count, 2,
            "revisiting a Room must reuse its adapter, not ask the platform again")
    }

    /// A declared server is authoritative. Consulting discovery anyway would let a
    /// herdr running locally silently override what the Room says.
    func testDeclaredHostNeverConsultsDiscovery() async throws {
        let room = Room(
            name: "A", baseTint: TokenColor(hex: "#5aa0ff")!, terminalThemeName: "Allward Night"
        ).connectedToHerdr(HostAlias("alpha"))
        let platform = RecordingPlatform()
        let coordinator = RoomAdapters(switchable: SwitchableAdapter(), platform: platform)

        await coordinator.activate(room)

        XCTAssertEqual(platform.discoveryCalls, 0)
        XCTAssertEqual(platform.requestedHosts, [HostAlias("alpha")])
    }
}
