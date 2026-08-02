import AllwardCore
import AllwardMultiplexer
import XCTest

@testable import AllwardHerdr

/// The Board is read by a person, so it has to carry herdr's own names.
///
/// It showed raw identifiers instead: the mapper set a session's workspace to
/// `workspaceID` - `w1G` rather than the space's name - and it looked up the
/// label only to use it as a last-resort title. An agent's pane was likewise
/// titled by whatever the shell had last set rather than by the agent.
final class HerdrSessionMapperTests: XCTestCase {
    private func snapshot(
        paneTitle: String?, agentTitle: String?, agentName: String?
    ) -> HerdrSnapshot {
        HerdrSnapshot(
            version: "0.7.5",
            protocolVersion: 4,
            workspaces: [
                HerdrWorkspace(
                    workspaceID: "w1G", label: "Infinitty repo review", focused: true,
                    activeTabID: "w1G:t1")
            ],
            panes: [
                HerdrPane(
                    paneID: "w1G:p1", terminalID: "term_657", workspaceID: "w1G",
                    tabID: "w1G:t1", focused: true, agentStatus: .working, revision: 1,
                    agent: agentName, cwd: "/src", foregroundCwd: "/src",
                    title: paneTitle, label: nil)
            ],
            agents: [
                HerdrAgent(
                    terminalID: "term_657", agent: agentName, agentStatus: .working,
                    workspaceID: "w1G", tabID: "w1G:t1", paneID: "w1G:p1", focused: true,
                    revision: 1, cwd: "/src", foregroundCwd: "/src", title: agentTitle)
            ],
            focusedPaneID: "w1G:p1")
    }

    private func map(_ snapshot: HerdrSnapshot) -> AdapterSession {
        HerdrSessionMapper()
            .map(snapshot: snapshot, host: HostAlias(rawValue: "jw14m2"))
            .sessions[0]
    }

    func testTheSpaceCarriesItsNameRatherThanItsIdentifier() {
        let session = map(snapshot(paneTitle: "zsh", agentTitle: nil, agentName: "omp"))
        XCTAssertEqual(
            session.workspace, "Infinitty repo review",
            "The Board showed the raw workspace id, which names nothing to a reader.")
    }

    /// A pane running an agent is known by the agent, not by whatever the shell
    /// last wrote into the title.
    func testAnAgentPaneIsNamedByTheAgent() {
        let session = map(
            snapshot(paneTitle: "zsh", agentTitle: "omp: repo review", agentName: "omp"))
        XCTAssertEqual(session.title, "omp: repo review")
    }

    func testAPaneWithoutAnAgentTitleFallsBackToItsOwn() {
        let session = map(snapshot(paneTitle: "make test", agentTitle: nil, agentName: nil))
        XCTAssertEqual(session.title, "make test")
    }

    /// The identifier is still what routing uses, so it stays in `id`.
    func testTheIdentifierIsStillAvailableForRouting() {
        let session = map(snapshot(paneTitle: nil, agentTitle: nil, agentName: "omp"))
        XCTAssertEqual(session.id, "herdr:jw14m2:w1G:w1G:p1")
        XCTAssertEqual(session.paneID, "w1G:p1")
    }

    /// A space with no label must not leave the row blank.
    func testAnUnlabelledSpaceFallsBackToItsIdentifier() {
        var raw = snapshot(paneTitle: "zsh", agentTitle: nil, agentName: nil)
        raw.workspaces = []
        XCTAssertEqual(map(raw).workspace, "w1G")
    }
}
