import AllwardControl
import AllwardCore
import Observation

/// Find across the focused pane's scrollback.
@MainActor
extension AppModel {
    public var searchMatchCount: Int { searchState.matches.count }
    public var currentSearchMatch: Int { searchState.index }

    public func search(for query: String) async {
        searchState.query = query
        guard let pane = focusedPane, let session = await control.session(for: pane) else {
            searchState.matches = []
            return
        }
        searchState.matches = await session.findMatches(of: query)
        searchState.index = 0
        await revealCurrentMatch()
    }

    /// Wraps at both ends, which is what a find bar is expected to do.
    public func stepSearchMatch(forward: Bool) async {
        guard !searchState.matches.isEmpty else { return }
        let count = searchState.matches.count
        searchState.index = (searchState.index + (forward ? 1 : count - 1)) % count
        await revealCurrentMatch()
    }

    private func revealCurrentMatch() async {
        guard let pane = focusedPane, let session = await control.session(for: pane),
            searchState.matches.indices.contains(searchState.index)
        else { return }
        await session.reveal(searchState.matches[searchState.index])
        if let view = paneView(for: pane) {
            view.apply(await session.snapshot(), focused: true)
        }
    }
}

/// Search is transient view state, so it lives beside the model rather than
/// inside the topology the control layer owns.
@MainActor
final class SearchState {
    var query = ""
    var matches: [SearchMatch] = []
    var index = 0
}
