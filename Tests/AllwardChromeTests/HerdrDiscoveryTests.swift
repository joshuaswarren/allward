import AllwardCore
import XCTest

@testable import AllwardChrome
@testable import AllwardHerdr
@testable import AllwardMultiplexer
/// Allward has to notice the herdr you are already using.
///
/// The adapter was built only from a Room's declared adapter server, and there
/// is no way to declare one in the interface, so Integrations said "no herdr"
/// to everyone forever - including with a `herdr --remote` session open in a
/// pane. Reading the process table is what makes the ordinary way in visible.
final class HerdrDiscoveryTests: XCTestCase {
    func testARemoteSessionNamesItsHost() {
        let table = """
            200 100 /bin/zsh -l
            201 200 herdr --remote jw14m2
            300 1 /usr/libexec/secinitd
            """
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: table, rootPID: 100)?.rawValue, "jw14m2")
    }

    func testTheEqualsFormIsAlsoAHost() {
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: "200 100 herdr --remote=macstudio", rootPID: 100)?.rawValue,
            "macstudio")
    }

    func testAFullPathToHerdrCounts() {
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(
                processTable: "200 100 /Users/j/.local/bin/herdr --remote esper", rootPID: 100)?.rawValue,
            "esper")
    }

    func testALocalServerIsThisMachine() {
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: "200 100 herdr server", rootPID: 100)?.rawValue, "localhost")
    }

    /// A remote session outranks a local server: the panes are on the far end.
    func testARemoteSessionWinsOverALocalServer() {
        let table = """
            200 100 herdr server
            201 100 herdr --remote tyrell
            """
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: table, rootPID: 100)?.rawValue, "tyrell")
    }

    func testNoHerdrMeansNoHost() {
        let table = """
            200 100 /bin/zsh -l
            100 1 /Applications/Allward.app/Contents/MacOS/Allward
            """
        XCTAssertNil(HerdrDiscovery.attachedHost(processTable: table, rootPID: 100))
    }

    /// Editing this file must not look like a herdr session.
    func testMerelyMentioningHerdrIsNotASession() {
        let table = "200 100 vim Sources/AllwardChrome/HerdrDiscovery.swift --remote nonsense"
        XCTAssertNil(HerdrDiscovery.attachedHost(processTable: table, rootPID: 100))
    }

    /// A herdr running in some other terminal is not ours.
    ///
    /// This shipped: a freshly launched Allward found a herdr client left
    /// running in another window, listed its panes on the Board, and could not
    /// teleport to any of them because they belong to a window Allward has
    /// nothing to do with.
    func testAHerdrInAnotherTerminalIsIgnored() {
        let table = """
            100 1 /Applications/Allward.app/Contents/MacOS/Allward
            900 1 /Applications/Other.app/Contents/MacOS/Other
            901 900 herdr --remote omp-home-local
            """
        XCTAssertNil(HerdrDiscovery.attachedHost(processTable: table, rootPID: 100))
    }

    /// A herdr several levels down one of our panes still counts: the shell is
    /// our child, and herdr is the shell's.
    func testAHerdrDeepInOurOwnPaneIsFound() {
        let table = """
            100 1 /Applications/Allward.app/Contents/MacOS/Allward
            200 100 -zsh
            201 200 herdr --remote esper
            """
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: table, rootPID: 100)?.rawValue, "esper")
    }

    /// A cycle in the reported table must not hang the walk.
    func testACyclicProcessTableTerminates() {
        let table = """
            200 201 herdr --remote loop
            201 200 -zsh
            """
        XCTAssertNil(HerdrDiscovery.attachedHost(processTable: table, rootPID: 100))
    }

    /// `--remote` with no value, or followed by another flag, names nothing.
    func testADanglingRemoteFlagNamesNothing() {
        XCTAssertNil(HerdrDiscovery.remoteTarget(in: ["herdr", "--remote"]))
        XCTAssertNil(HerdrDiscovery.remoteTarget(in: ["herdr", "--remote", "--verbose"]))
        XCTAssertNil(HerdrDiscovery.remoteTarget(in: ["herdr", "--remote="]))
    }
}
