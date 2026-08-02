import AllwardCore
import AllwardHerdr
import AllwardMultiplexer
import AllwardRooms
import Foundation

/// One adapter per Room.
///
/// Rooms are separate workspaces and will usually point at different servers,
/// so there is no single "the adapter" - there is the adapter for the Room you
/// are looking at. Surfaces hold one `SwitchableAdapter` for the lifetime of
/// the app and this coordinator re-points it as Rooms change, keeping each
/// Room's connection alive behind it rather than tearing it down on every
/// visit.
public actor RoomAdapters {
    private let switchable: SwitchableAdapter
    private var adapters: [RoomID: any MultiplexerAdapter] = [:]
    private var hosts: [RoomID: HostAlias?] = [:]
    private var active: RoomID?

    public init(switchable: SwitchableAdapter) {
        self.switchable = switchable
    }

    /// Point the shared reference at `room`'s adapter, building it on first use.
    public func activate(_ room: Room?) async {
        active = room?.id
        guard let room else {
            await switchable.replace(with: NoMultiplexerAdapter())
            return
        }
        let next = await adapter(for: room)
        await switchable.replace(with: next)
    }

    /// Rebuild the Rooms whose declared server changed, and leave the rest
    /// connected. Configuration is written on every unrelated edit, so this
    /// must not disturb a Room the change never mentioned.
    public func apply(_ rooms: [Room]) async {
        for room in rooms {
            guard let recorded = hosts[room.id] else { continue }
            guard recorded != room.herdrHost else { continue }
            let stale = adapters.removeValue(forKey: room.id)
            hosts[room.id] = room.herdrHost
            await stale?.stop()
            if room.id == active {
                let next = await adapter(for: room)
                await switchable.replace(with: next)
            }
        }
        for id in Array(hosts.keys) where !rooms.contains(where: { $0.id == id }) {
            let removed = adapters.removeValue(forKey: id)
            hosts.removeValue(forKey: id)
            await removed?.stop()
        }
    }

    private func adapter(for room: Room) async -> any MultiplexerAdapter {
        if let existing = adapters[room.id] { return existing }
        let host: HostAlias?
        if let declared = room.herdrHost {
            host = declared
        } else {
            host = await HerdrDiscovery.attachedHost()
        }
        let built = Self.make(host: host)
        adapters[room.id] = built
        hosts[room.id] = room.herdrHost
        return built
    }

    /// A missing declaration can still resolve a herdr attached to one of our
    /// panes; explicit declarations never use discovery.
    public static func make(host: HostAlias?) -> any MultiplexerAdapter {
        guard let endpoint = HerdrProcessExecutor.endpoint(host: host) else {
            return NoMultiplexerAdapter()
        }
        return HerdrAdapter(client: HerdrProcessExecutor.makeClient(for: endpoint))
    }
}
