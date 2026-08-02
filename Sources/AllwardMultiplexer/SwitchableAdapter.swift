import AllwardCore
import Foundation

/// One adapter reference that outlives the adapter it points at.
///
/// Connecting to a workspace while the app runs means replacing the adapter,
/// but every surface already holds a reference to the old one and every event
/// consumer has already subscribed to its stream. A running app cannot rebuild
/// its object graph to answer a click, so the reference is what stays fixed:
/// subscribers attach here once, and keep receiving across the swap.
public final class SwitchableAdapter: MultiplexerAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: any MultiplexerAdapter
    private var pump: Task<Void, Never>?
    private var started = false
    /// Which adapter the pump belongs to. A swap that lands while `start()` is
    /// awaiting must not have its stream replaced by the adapter it retired.
    private var generation = 0
    private let continuation: AsyncStream<AdapterEvent>.Continuation
    public let events: AsyncStream<AdapterEvent>

    public init(_ initial: any MultiplexerAdapter = NoMultiplexerAdapter()) {
        self.inner = initial
        var escaped: AsyncStream<AdapterEvent>.Continuation!
        self.events = AsyncStream { escaped = $0 }
        self.continuation = escaped
    }

    /// The adapter in force right now. Reading it is always safe; acting on it
    /// across an `await` is not, so callers take it once per operation.
    public var current: any MultiplexerAdapter {
        lock.lock()
        defer { lock.unlock() }
        return inner
    }

    public var displayName: String { current.displayName }
    public var capabilities: AdapterCapabilities { current.capabilities }
    public var health: AdapterHealth { get async { await current.health } }

    public func start() async {
        let adapter: any MultiplexerAdapter = {
            lock.lock()
            defer { lock.unlock() }
            started = true
            return inner
        }()
        let generation = self.generation
        await adapter.start()
        forward(adapter, generation: generation)
    }

    public func stop() async {
        let adapter: any MultiplexerAdapter = {
            lock.lock()
            defer { lock.unlock() }
            started = false
            pump?.cancel()
            pump = nil
            return inner
        }()
        await adapter.stop()
    }

    /// Point every existing reference at a different adapter.
    ///
    /// The old adapter is stopped before the new one starts, so two adapters
    /// never poll the same workspace at once.
    public func replace(with next: any MultiplexerAdapter) async {
        let (previous, wasStarted): (any MultiplexerAdapter, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            pump?.cancel()
            pump = nil
            self.generation += 1
            let previous = inner
            inner = next
            return (previous, started)
        }()
        await previous.stop()
        guard wasStarted else { return }
        let generation = self.generation
        await next.start()
        forward(next, generation: generation)
    }

    /// Republish one adapter's events on the stream subscribers already hold.
    private func forward(_ adapter: any MultiplexerAdapter, generation: Int) {
        let task = Task { [continuation] in
            for await event in adapter.events {
                if Task.isCancelled { return }
                continuation.yield(event)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else {
            task.cancel()
            return
        }
        pump?.cancel()
        pump = task
    }

    public func listSessions(bound: AttemptBound) async throws -> [AdapterSession] {
        try await current.listSessions(bound: bound)
    }

    public func route(for session: AdapterSession) async -> AdapterContentRoute {
        await current.route(for: session)
    }

    public func focus(session: AdapterSession, bound: AttemptBound) async throws {
        try await current.focus(session: session, bound: bound)
    }

    public func attachCommand(for session: AdapterSession, route: AdapterContentRoute) -> [String] {
        current.attachCommand(for: session, route: route)
    }
}
