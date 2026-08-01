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
            /bin/zsh -l
            herdr --remote jw14m2
            /usr/libexec/secinitd
            """
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: table)?.rawValue, "jw14m2")
    }

    func testTheEqualsFormIsAlsoAHost() {
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: "herdr --remote=macstudio")?.rawValue,
            "macstudio")
    }

    func testAFullPathToHerdrCounts() {
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(
                processTable: "/Users/j/.local/bin/herdr --remote esper")?.rawValue,
            "esper")
    }

    func testALocalServerIsThisMachine() {
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: "herdr server")?.rawValue, "localhost")
    }

    /// A remote session outranks a local server: the panes are on the far end.
    func testARemoteSessionWinsOverALocalServer() {
        let table = """
            herdr server
            herdr --remote tyrell
            """
        XCTAssertEqual(
            HerdrDiscovery.attachedHost(processTable: table)?.rawValue, "tyrell")
    }

    func testNoHerdrMeansNoHost() {
        let table = """
            /bin/zsh -l
            /Applications/Allward.app/Contents/MacOS/Allward
            """
        XCTAssertNil(HerdrDiscovery.attachedHost(processTable: table))
    }

    /// Editing this file must not look like a herdr session.
    func testMerelyMentioningHerdrIsNotASession() {
        let table = "vim Sources/AllwardChrome/HerdrDiscovery.swift --remote nonsense"
        XCTAssertNil(HerdrDiscovery.attachedHost(processTable: table))
    }

    /// `--remote` with no value, or followed by another flag, names nothing.
    func testADanglingRemoteFlagNamesNothing() {
        XCTAssertNil(HerdrDiscovery.remoteTarget(in: ["herdr", "--remote"]))
        XCTAssertNil(HerdrDiscovery.remoteTarget(in: ["herdr", "--remote", "--verbose"]))
        XCTAssertNil(HerdrDiscovery.remoteTarget(in: ["herdr", "--remote="]))
    }
}
