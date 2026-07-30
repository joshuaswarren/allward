import AllwardCore
import Foundation

extension ControlService {
    public func lockInputRoute(
        for pane: PaneID
    ) async -> (
        handle: UUID,
        routeGeneration: Generation,
        ownershipGeneration: Generation
    )? {
        guard await registry.target(for: pane) != nil else { return nil }
        let routeGeneration = await registry.generation
        let ownership = (inputOwnership[pane] ?? .initial).next
        let state = InputRouteState(
            handle: UUID(),
            routeGeneration: routeGeneration,
            ownershipGeneration: ownership
        )
        inputOwnership[pane] = ownership
        inputRoutes[pane] = state
        return (state.handle, state.routeGeneration, state.ownershipGeneration)
    }

    public func isRouteCurrent(
        pane: PaneID,
        handle: UUID,
        routeGeneration: Generation,
        ownershipGeneration: Generation
    ) async -> Bool {
        guard let state = inputRoutes[pane], state.handle == handle,
              state.routeGeneration == routeGeneration,
              state.ownershipGeneration == ownershipGeneration
        else { return false }
        let currentGeneration = await registry.generation
        let currentTarget = await registry.target(for: pane)
        return currentGeneration == routeGeneration && currentTarget != nil
    }

    public func injectText(
        _ text: String,
        pane: PaneID,
        handle: UUID,
        routeGeneration: Generation,
        ownershipGeneration: Generation
    ) async -> Bool {
        guard let target = await registry.target(for: pane),
              let session = await registry.session(for: pane)
        else { return false }
        let result = await arbiter.submit(
            pane: pane,
            target: target,
            expectedGeneration: routeGeneration,
            source: .speech,
            preflight: {
                await self.routeDropReason(
                    pane: pane,
                    handle: handle,
                    routeGeneration: routeGeneration,
                    ownershipGeneration: ownershipGeneration
                )
            },
            currentGeneration: {
                guard await session.isOpen() else { return nil }
                return await self.registry.generation
            },
            deliver: { await session.paste(text) }
        )
        if case .delivered = result { return true }
        return false
    }

    func invalidateInputRoute(for pane: PaneID) {
        inputRoutes[pane] = nil
        inputOwnership[pane] = (inputOwnership[pane] ?? .initial).next
    }

    private func routeDropReason(
        pane: PaneID,
        handle: UUID,
        routeGeneration: Generation,
        ownershipGeneration: Generation
    ) async -> PaneInputDropReason? {
        guard let state = inputRoutes[pane] else {
            return .staleRoute(expectedHandle: handle, actualHandle: nil)
        }
        guard state.handle == handle, state.ownershipGeneration == ownershipGeneration else {
            return .staleRoute(expectedHandle: handle, actualHandle: state.handle)
        }
        let actualGeneration = await registry.generation
        guard state.routeGeneration == routeGeneration, actualGeneration == routeGeneration else {
            return .staleGeneration(expected: routeGeneration, actual: actualGeneration)
        }
        return nil
    }
}
