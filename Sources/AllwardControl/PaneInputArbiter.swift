import AllwardCore
import Foundation

public enum PaneInputSource: String, Codable, Hashable, Sendable {
    case nativeUI
    case mcp
    case speech
}

public enum PaneInputDropReason: Equatable, Sendable {
    case paneUnavailable(PaneID)
    case targetMismatch(expected: PaneID, supplied: PaneID?)
    case staleGeneration(expected: Generation, actual: Generation)
    case staleRoute(expectedHandle: UUID, actualHandle: UUID?)
    case cancelled
}

public enum PaneInputResult: Equatable, Sendable {
    case delivered(pane: PaneID, generation: Generation)
    case dropped(PaneInputDropReason)
}

public actor PaneInputArbiter {
    private struct WorkItem: Sendable {
        var target: Target
        var expectedGeneration: Generation
        var source: PaneInputSource
        var preflight: @Sendable () async -> PaneInputDropReason?
        var currentGeneration: @Sendable () async -> Generation?
        var deliver: @Sendable () async -> Bool
        var continuation: CheckedContinuation<PaneInputResult, Never>
    }

    private var queues: [PaneID: [WorkItem]] = [:]
    private var activePanes: Set<PaneID> = []

    public init() {}

    func submit(
        pane: PaneID,
        target: Target,
        expectedGeneration: Generation,
        source: PaneInputSource,
        preflight: @escaping @Sendable () async -> PaneInputDropReason? = { nil },
        currentGeneration: @escaping @Sendable () async -> Generation?,
        deliver: @escaping @Sendable () async -> Bool
    ) async -> PaneInputResult {
        guard target.pane == pane else {
            return .dropped(.targetMismatch(expected: pane, supplied: target.pane))
        }
        return await withCheckedContinuation { continuation in
            queues[pane, default: []].append(
                WorkItem(
                    target: target,
                    expectedGeneration: expectedGeneration,
                    source: source,
                    preflight: preflight,
                    currentGeneration: currentGeneration,
                    deliver: deliver,
                    continuation: continuation
                )
            )
            guard activePanes.insert(pane).inserted else { return }
            Task { await self.drain(pane) }
        }
    }

    public func cancelQueuedInput(for pane: PaneID) {
        let queued = queues.removeValue(forKey: pane) ?? []
        for item in queued { item.continuation.resume(returning: .dropped(.cancelled)) }
    }

    private func drain(_ pane: PaneID) async {
        while !Task.isCancelled {
            guard var queue = queues[pane], !queue.isEmpty else {
                queues[pane] = nil
                activePanes.remove(pane)
                return
            }
            let item = queue.removeFirst()
            queues[pane] = queue
            let result: PaneInputResult
            if let dropReason = await item.preflight() {
                result = .dropped(dropReason)
                item.continuation.resume(returning: result)
                continue
            }
            guard let actualGeneration = await item.currentGeneration() else {
                result = .dropped(.paneUnavailable(pane))
                item.continuation.resume(returning: result)
                continue
            }
            guard actualGeneration == item.expectedGeneration else {
                result = .dropped(
                    .staleGeneration(expected: item.expectedGeneration, actual: actualGeneration)
                )
                item.continuation.resume(returning: result)
                continue
            }
            guard await item.deliver() else {
                result = .dropped(.paneUnavailable(pane))
                item.continuation.resume(returning: result)
                continue
            }
            result = .delivered(pane: pane, generation: actualGeneration)
            item.continuation.resume(returning: result)
            _ = item.source
        }
    }
}
