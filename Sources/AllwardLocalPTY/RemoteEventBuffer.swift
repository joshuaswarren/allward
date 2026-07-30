import AllwardRemote
import Foundation

public final class RemoteEventBuffer: @unchecked Sendable {
    public private(set) var stream: AsyncStream<RemoteEvent>! = nil

    private static let maximumQueuedEvents = 256
    private static let maximumQueuedBytes = 64 * 1024 * 1024

    private let condition = NSCondition()
    private var queue: [RemoteEvent] = []
    private var costs: [Int] = []
    private var head = 0
    private var queuedBytes = 0
    private var waiters: [CheckedContinuation<RemoteEvent?, Never>] = []
    private var finished = false

    // The condition provides producer backpressure while continuations keep consumers off blocking threads.
    public init() {
        stream = AsyncStream { [weak self] in
            guard let self else { return nil }
            return await self.next()
        }
    }

    public func send(_ event: RemoteEvent) {
        let cost = Self.cost(of: event)
        condition.lock()
        while !finished && !canEnqueue(cost: cost) && waiters.isEmpty {
            condition.wait()
        }
        guard !finished else {
            condition.unlock()
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            condition.unlock()
            waiter.resume(returning: event)
            return
        }
        queue.append(event)
        costs.append(cost)
        queuedBytes += cost
        condition.unlock()
    }

    public func finish() {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        let pending = queueCount == 0 ? waiters : []
        if queueCount == 0 { waiters.removeAll(keepingCapacity: false) }
        condition.broadcast()
        condition.unlock()
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    private func next() async -> RemoteEvent? {
        await withCheckedContinuation { continuation in
            condition.lock()
            if queueCount > 0 {
                let event = queue[head]
                queuedBytes -= costs[head]
                head += 1
                compactIfNeeded()
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: event)
            } else if finished {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }

    private var queueCount: Int {
        queue.count - head
    }

    private func canEnqueue(cost: Int) -> Bool {
        if cost == 0 { return true }
        return queueCount < Self.maximumQueuedEvents
            && queuedBytes + cost <= Self.maximumQueuedBytes
    }

    private func compactIfNeeded() {
        guard head >= 128, head * 2 >= queue.count else { return }
        queue.removeFirst(head)
        costs.removeFirst(head)
        head = 0
    }

    private static func cost(of event: RemoteEvent) -> Int {
        if case let .bytes(bytes) = event { return bytes.count }
        return 0
    }
}
