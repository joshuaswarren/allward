import AllwardCore
import AllwardProtocol
import Foundation
import XCTest

@testable import AllwardSurfaces

final class SurfaceEligibilityReducerTests: XCTestCase {
    private let reducer = SurfaceEligibilityReducer()

    func testTerminalErrorSuppressesActivePermissionAndAllowsOnlyRecovery() {
        var composition = SourceComposition(permission: .active)
        composition.sourceHealth = .error
        let result = reducer.project(
            composition: composition, usability: .errorRecoveryOnly,
            transition: .semanticChange, presence: .background, isEffectiveSubject: true
        )
        XCTAssertTrue(result.boardIncluded)
        XCTAssertTrue(result.eligibility.boardActionable)
        XCTAssertFalse(result.approvalActionAvailable)
        XCTAssertEqual(result.eligibility.routerClass, .error)
        XCTAssertEqual(result.announcementLane, .errorRecovery)
        XCTAssertFalse(result.eligibility.earconAllowed)
    }

    func testStaleSuppressesActivePermissionButAllowsOneStaleAnnouncement() {
        var composition = SourceComposition(permission: .active)
        composition.freshness = .stale
        let transition = reducer.project(
            composition: composition, usability: .staleNonactionable,
            transition: .leaseExpired, presence: .background, isEffectiveSubject: true
        )
        let refresh = reducer.project(
            composition: composition, usability: .staleNonactionable,
            transition: .refresh, presence: .background, isEffectiveSubject: true
        )
        XCTAssertFalse(transition.eligibility.boardActionable)
        XCTAssertEqual(transition.announcementLane, .stale)
        XCTAssertTrue(transition.eligibility.announcementAllowed)
        XCTAssertFalse(refresh.eligibility.announcementAllowed)
        XCTAssertFalse(transition.eligibility.earconAllowed)
    }

    func testUnavailableControlLeavesContentInspectableButDisabled() {
        let composition = SourceComposition(permission: .active, control: .unavailable)
        let result = reducer.project(
            composition: composition, usability: .usableControlDisabled,
            transition: .semanticChange, presence: .background, isEffectiveSubject: true
        )
        XCTAssertTrue(result.boardIncluded)
        XCTAssertTrue(result.directReadAllowed)
        XCTAssertFalse(result.eligibility.boardActionable)
        XCTAssertFalse(result.approvalActionAvailable)
        XCTAssertNil(result.eligibility.routerClass)
        XCTAssertEqual(result.controlState, .disabled)
    }

    func testExplicitCloseIsAbsentAndCancelsQueuedDelivery() {
        let composition = SourceComposition(connection: .closed(.explicit), permission: .active)
        let result = reducer.project(
            composition: composition, usability: .closedAbsent,
            transition: .explicitClose, presence: .background, isEffectiveSubject: true
        )
        XCTAssertFalse(result.boardIncluded)
        XCTAssertFalse(result.directReadAllowed)
        XCTAssertEqual(result.eligibility, .inert)
        XCTAssertTrue(result.cancelQueuedDelivery)
    }

    func testFocusDenialMasksUnsolicitedSurfacesButNotDirectReading() {
        let composition = SourceComposition(permission: .active, focus: .denied)
        let result = reducer.project(
            composition: composition, usability: .usableActionCapable,
            transition: .semanticChange, presence: .directlyOpened, isEffectiveSubject: true
        )
        XCTAssertTrue(result.boardIncluded)
        XCTAssertTrue(result.directReadAllowed)
        XCTAssertFalse(result.unsolicitedAllowed)
        XCTAssertNil(result.eligibility.routerClass)
        XCTAssertFalse(result.eligibility.digestIncluded)
        XCTAssertFalse(result.eligibility.announcementAllowed)
        XCTAssertFalse(result.eligibility.earconAllowed)
    }
}

final class SurfaceReducerProjectionTests: XCTestCase {
    func testBoardOrderDoesNotChangeForAnUnrelatedRoomMutation() throws {
        let roomA = room("00000000-0000-0000-0000-00000000000A")
        let roomB = room("00000000-0000-0000-0000-00000000000B")
        let recordA = makeRecord(id: "00000000-0000-0000-0001-000000000001", room: roomA, title: "A")
        let recordB = makeRecord(id: "00000000-0000-0000-0002-000000000001", room: roomB, title: "B")
        let reducer = BoardReducer(visibleRowLimit: 100)
        let first = reducer.reduce(
            [SurfaceReducedRecord(record: recordB, projection: .live(record: recordB)),
             SurfaceReducedRecord(record: recordA, projection: .live(record: recordA))],
            generation: Generation(rawValue: 1)
        )
        var changedA = recordA
        changedA.title = "A changed"
        changedA.composition.work = .running
        let second = reducer.reduce(
            [SurfaceReducedRecord(record: changedA, projection: .live(record: changedA)),
             SurfaceReducedRecord(record: recordB, projection: .live(record: recordB))],
            generation: Generation(rawValue: 2)
        )
        XCTAssertEqual(first.groups.map(\.roomID), second.groups.map(\.roomID))
        XCTAssertEqual(
            try XCTUnwrap(first.groups.first(where: { $0.roomID == roomB })).rows.map(\.id),
            try XCTUnwrap(second.groups.first(where: { $0.roomID == roomB })).rows.map(\.id)
        )
    }

    func testRouterKeysAreStableAndNewEpochFiresOnce() {
        let roomID = room("00000000-0000-0000-0000-000000000001")
        var first = makeRecord(id: "00000000-0000-0000-0001-000000000001", room: roomID, title: "First")
        first.composition.permission = .active
        var second = makeRecord(id: "00000000-0000-0000-0002-000000000001", room: roomID, title: "Second")
        second.composition.permission = .active
        let reduced = [first, second].map { SurfaceReducedRecord(record: $0, projection: .live(record: $0)) }
        var reducer = RouterReducer()
        let initial = reducer.reduce(Array(reduced.reversed()), generation: Generation(rawValue: 1))
        let refresh = reducer.reduce(reduced, generation: Generation(rawValue: 2))
        XCTAssertEqual(initial.items.map(\.destinationKey), ["1", "2"])
        XCTAssertEqual(refresh.items.map(\.destinationKey), ["1", "2"])
        XCTAssertEqual(Set(initial.newEpochs), Set([first.id, second.id]))
        XCTAssertTrue(refresh.newEpochs.isEmpty)
    }

    func testDigestCountsEventsRatherThanRenderedLinesAndIsAbsentWithoutEvents() {
        let roomID = room("00000000-0000-0000-0000-000000000001")
        let record = makeRecord(
            id: "00000000-0000-0000-0001-000000000001", room: roomID,
            title: "One event", detail: "first line\nsecond line"
        )
        let event = SurfaceEvent(ordinal: 1, record: record, transition: .semanticChange, isMeaningful: true)
        let reducer = DigestReducer()
        let ready = reducer.reduce(
            events: [event],
            records: [SurfaceReducedRecord(record: record, projection: .live(record: record))],
            generation: Generation(rawValue: 1)
        )
        let absent = reducer.reduce(events: [], records: [], generation: Generation(rawValue: 2))
        XCTAssertEqual(ready.allowedUnseenEventCount, 1)
        XCTAssertEqual(ready.facts.first?.lines.count, 2)
        XCTAssertEqual(ready.state, .readyDeterministic)
        XCTAssertEqual(absent.allowedUnseenEventCount, 0)
        XCTAssertEqual(absent.state, .absent)
    }

    func testFocusDeniedRecordIsFilteredFromRouterAndDigest() {
        let roomID = room("00000000-0000-0000-0000-000000000001")
        var record = makeRecord(
            id: "00000000-0000-0000-0001-000000000001",
            room: roomID,
            title: "Hidden permission"
        )
        record.composition.permission = .active
        record.composition.focus = .denied
        let projection = SurfaceEligibilityReducer().project(
            composition: record.composition,
            usability: .usableActionCapable,
            transition: .semanticChange,
            presence: .directlyOpened,
            isEffectiveSubject: true
        )
        let reduced = SurfaceReducedRecord(record: record, projection: projection)
        var routerReducer = RouterReducer()
        let router = routerReducer.reduce([reduced], generation: Generation(rawValue: 1))
        let event = SurfaceEvent(
            ordinal: 1,
            record: record,
            transition: .semanticChange,
            isMeaningful: true
        )
        let digest = DigestReducer().reduce(
            events: [event],
            records: [reduced],
            generation: Generation(rawValue: 1)
        )

        XCTAssertTrue(projection.directReadAllowed)
        XCTAssertEqual(router.state, .focusFiltered)
        XCTAssertEqual(router.totalActionableCount, 0)
        XCTAssertTrue(router.items.isEmpty)
        XCTAssertEqual(digest.state, .focusFiltered)
        XCTAssertEqual(digest.allowedUnseenEventCount, 0)
        XCTAssertEqual(digest.filteredEventCount, 1)
    }

    func testBoardRepresentsZeroPublisherAndMaximumContentWithoutDisabledPublisherColumns() {
        let roomID = room("00000000-0000-0000-0000-000000000001")
        let records = (1...3).map { offset -> SurfaceReducedRecord in
            let id = String(format: "00000000-0000-0000-0001-%012d", offset)
            let record = makeRecord(id: id, room: roomID, title: "Session \(offset)")
            return SurfaceReducedRecord(record: record, projection: .live(record: record))
        }
        let complete = BoardReducer(visibleRowLimit: 10).reduce(
            records,
            generation: Generation(rawValue: 1)
        )
        let bounded = BoardReducer(visibleRowLimit: 2).reduce(
            records,
            generation: Generation(rawValue: 2)
        )

        XCTAssertEqual(complete.state, .zeroPublishers)
        XCTAssertTrue(complete.groups.flatMap(\.rows).allSatisfy { $0.publisher == nil })
        XCTAssertEqual(bounded.state, .maximumContent(exactTotal: 3))
        XCTAssertEqual(bounded.visibleRowCount, 2)
        XCTAssertEqual(bounded.exactTotal, 3)
    }

    func testBoardStateTableUsesSourceFactsWithoutDroppingRows() {
        let roomID = room("00000000-0000-0000-0000-000000000001")
        let publisherID = PublisherID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let reducer = BoardReducer()
        var record = makeRecord(
            id: "00000000-0000-0000-0001-000000000001",
            room: roomID,
            title: "Session"
        )
        record.publisher = publisherID

        func snapshot(_ value: NormalizedRecord) -> BoardSnapshot {
            reducer.reduce(
                [SurfaceReducedRecord(record: value, projection: .live(record: value))],
                generation: Generation(rawValue: 1)
            )
        }

        XCTAssertEqual(reducer.reduce([], generation: .initial).state, .emptyNoSessions)
        XCTAssertEqual(snapshot(record).state, .emptyNoOpenLoops)

        record.plan = [PlanEntry(id: "open", content: "Work", status: .inProgress)]
        XCTAssertEqual(snapshot(record).state, .populated)

        record.composition.connection = .connecting
        XCTAssertEqual(snapshot(record).state, .loading)

        record.composition.connection = .ready
        record.composition.permission = .active
        XCTAssertEqual(snapshot(record).state, .permission)

        record.composition.freshness = .stale
        XCTAssertEqual(snapshot(record).state, .staleOrDegraded)

        record.composition.freshness = .live
        record.composition.sourceHealth = .error
        let error = snapshot(record)
        XCTAssertEqual(error.state, .error)
        XCTAssertEqual(error.exactTotal, 1)
    }

    private func room(_ value: String) -> RoomID { RoomID(rawValue: UUID(uuidString: value)!) }

    private func makeRecord(id: String, room: RoomID, title: String, detail: String? = nil) -> NormalizedRecord {
        NormalizedRecord(
            id: RecordID(rawValue: UUID(uuidString: id)!), kind: .session, source: .terminalOSC133,
            target: Target(room: room), freshness: FreshnessStamp(observedAt: Date(timeIntervalSince1970: 0)),
            composition: .liveLocal, title: title, detail: detail
        )
    }
}

@MainActor
final class SurfaceStoreTests: XCTestCase {
    func testSupersedeLeavesOnlyReplacementActive() async {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let roomID = RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let first = permissionRecord(
            id: "00000000-0000-0000-0001-000000000001", room: roomID,
            publisher: publisher, observedAt: clock.now
        )
        var replacement = first
        replacement.id = RecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0002-000000000001")!)
        replacement.epoch = Generation(rawValue: 2)
        replacement.sequence = 2
        _ = await store.ingest(NormalizedPublication(logicalKey: "permission:build", record: first, leaseDuration: 30))
        let snapshot = await store.ingest(
            NormalizedPublication(logicalKey: "permission:build", record: replacement, leaseDuration: 30)
        )
        XCTAssertEqual(snapshot.records.map(\.id), [replacement.id])
        let superseded = await store.record(id: first.id)
        XCTAssertEqual(superseded?.composition.freshness, .superseded)
    }

    func testLeaseExpiryMakesRecordStaleAndDisablesAction() async {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let roomID = RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let record = permissionRecord(
            id: "00000000-0000-0000-0001-000000000001", room: roomID,
            publisher: publisher, observedAt: clock.now
        )
        let live = await store.ingest(
            NormalizedPublication(logicalKey: "permission:build", record: record, leaseDuration: 10)
        )
        clock.advance(by: 11)
        let stale = await store.expireLeases()
        XCTAssertEqual(live.board.groups.flatMap(\.rows).first?.isActionable, true)
        XCTAssertEqual(stale.records.first?.composition.freshness, .stale)
        XCTAssertEqual(stale.board.groups.flatMap(\.rows).first?.isActionable, false)
    }

    func testLocalAcknowledgmentDoesNotMutatePublisherPermission() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let roomID = RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let record = permissionRecord(
            id: "00000000-0000-0000-0001-000000000001", room: roomID,
            publisher: publisher, observedAt: clock.now
        )
        let snapshot = await store.ingest(
            NormalizedPublication(logicalKey: "permission:build", record: record, leaseDuration: 30)
        )
        let token = try XCTUnwrap(snapshot.router.items.first?.acknowledgmentToken)
        let acknowledged = await store.acknowledgeLocally(token)
        XCTAssertTrue(acknowledged)
        let unchanged = await store.record(id: record.id)
        XCTAssertEqual(unchanged?.composition.permission, .active)
        XCTAssertEqual(unchanged?.permission?.id, "permission-build")
    }

    func testStaleRouterTokenCannotAcknowledgeSuccessorAction() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let roomID = RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let record = permissionRecord(
            id: "00000000-0000-0000-0001-000000000001",
            room: roomID,
            publisher: publisher,
            observedAt: clock.now
        )
        let first = await store.ingest(
            NormalizedPublication(logicalKey: "permission:build", record: record)
        )
        var successor = record
        successor.sequence = 2
        successor.permission?.verb = "Allow deploy"
        let second = await store.ingest(
            NormalizedPublication(logicalKey: "permission:build", record: successor)
        )
        let oldToken = try XCTUnwrap(first.router.items.first?.acknowledgmentToken)
        let newToken = try XCTUnwrap(second.router.items.first?.acknowledgmentToken)

        XCTAssertNotEqual(oldToken, newToken)
        let acknowledged = await store.acknowledgeLocally(oldToken)
        XCTAssertFalse(acknowledged)
    }

    func testDigestTokenDoesNotAcknowledgeEventArrivingAfterRender() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let roomID = RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let firstRecord = permissionRecord(
            id: "00000000-0000-0000-0001-000000000001",
            room: roomID,
            publisher: publisher,
            observedAt: clock.now
        )
        let first = await store.ingest(
            NormalizedPublication(logicalKey: "permission:first", record: firstRecord)
        )
        var secondRecord = firstRecord
        secondRecord.id = RecordID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0002-000000000001")!
        )
        secondRecord.permission?.id = "permission-second"
        let second = await store.ingest(
            NormalizedPublication(logicalKey: "permission:second", record: secondRecord)
        )
        let token = try XCTUnwrap(first.digest.acknowledgmentToken)

        XCTAssertEqual(second.digest.allowedUnseenEventCount, 2)
        let remaining = await store.acknowledgeDigest(token)
        XCTAssertEqual(remaining.allowedUnseenEventCount, 1)
    }

    func testRefreshReplayDoesNotCreateOrHideSemanticDigestEvent() async {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let roomID = RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let record = permissionRecord(
            id: "00000000-0000-0000-0001-000000000001",
            room: roomID,
            publisher: publisher,
            observedAt: clock.now
        )
        _ = await store.ingest(
            NormalizedPublication(logicalKey: "permission:build", record: record)
        )
        var replay = record
        replay.sequence = 2
        replay.freshness = FreshnessStamp(observedAt: clock.now.addingTimeInterval(1))

        let snapshot = await store.ingest(
            NormalizedPublication(
                logicalKey: "permission:build",
                record: replay,
                transition: .refresh
            )
        )

        XCTAssertEqual(snapshot.digest.allowedUnseenEventCount, 1)
    }

    func testMCPAuthorshipIsReceiverStampedAndInvocationReplayIsIdempotent() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let target = Target(
            room: RoomID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
        )
        let authority = MCPAuthoredAuthority(
            authoritativeClientID: "client",
            grantID: "grant",
            grantInvocationNamespace: "namespace"
        )
        let invocationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let content = MCPAuthoredContent(
            kind: .openLoop,
            title: "Review result",
            detail: "Source fact"
        )

        let created = try await store.createMCPAuthored(
            callerLogicalKey: "review",
            content: content,
            target: target,
            authority: authority,
            invocationID: invocationID
        )
        let replay = try await store.createMCPAuthored(
            callerLogicalKey: "review",
            content: content,
            target: target,
            authority: authority,
            invocationID: invocationID
        )
        let snapshot = await store.snapshot()

        XCTAssertEqual(created.status, .created)
        XCTAssertEqual(replay, created)
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records.first?.source, .mcpAuthored)
        XCTAssertEqual(snapshot.records.first?.sequence, 1)
    }

    func testMCPAuthorityLossMakesOnlyItsRecordsStale() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let store = SurfaceStore(clock: clock)
        let target = Target(
            room: RoomID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
        )
        let authority = MCPAuthoredAuthority(
            authoritativeClientID: "client",
            grantID: "grant",
            grantInvocationNamespace: "namespace"
        )
        _ = try await store.createMCPAuthored(
            callerLogicalKey: "review",
            content: MCPAuthoredContent(kind: .openLoop, title: "Review result"),
            target: target,
            authority: authority,
            invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        )

        let stale = await store.staleMCPAuthority(namespace: "namespace")

        XCTAssertEqual(stale.records.first?.composition.freshness, .stale)
        XCTAssertEqual(stale.board.groups.flatMap(\.rows).first?.isActionable, false)
    }

    private func permissionRecord(
        id: String, room: RoomID, publisher: PublisherID, observedAt: Date
    ) -> NormalizedRecord {
        NormalizedRecord(
            id: RecordID(rawValue: UUID(uuidString: id)!), kind: .permission, source: .publisherDirect,
            target: Target(room: room), freshness: FreshnessStamp(observedAt: observedAt),
            composition: SourceComposition(permission: .active), title: "Build permission",
            publisher: publisher, publisherName: "Agent",
            permission: PermissionRequest(
                id: "permission-build", verb: "Allow build", subject: "workspace",
                options: [PermissionRequest.Option(id: "allow", label: "Allow")]
            ),
            epoch: Generation(rawValue: 1), sequence: 1
        )
    }
}
