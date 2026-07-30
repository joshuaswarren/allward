import AllwardCore
import Foundation
import XCTest

@testable import AllwardProtocol

final class CodecTests: XCTestCase {
    func testRoundTripsEveryFrameAndPublicationPayloadCase() throws {
        let publisher = PublisherID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let binding = makeDecisionBinding()
        let frames: [AllwardFrame] = [
            .grantRequest(
                GrantRequest(
                    capabilities: [.plans, .sessionUpdates, .permissions, .commandRegions],
                    harness: "omp",
                    publisherName: "fixture",
                    descriptor: "grant-1",
                    sessionHint: "session",
                    roomHint: "room",
                    requestedLeaseSeconds: 15
                )
            ),
            .grantResponse(
                GrantResponse(
                    accepted: true,
                    publisher: publisher,
                    epoch: Generation(rawValue: 3),
                    leaseSeconds: 15,
                    acceptedCapabilities: [.plans, .permissions]
                )
            ),
            .publication(
                PublicationFrame(
                    epoch: Generation(rawValue: 3),
                    sequence: 1,
                    payload: .plan([PlanEntry(id: "p1", content: "Ship", status: .inProgress)])
                )
            ),
            .publication(
                PublicationFrame(
                    epoch: Generation(rawValue: 3),
                    sequence: 2,
                    payload: .sessionUpdate(SessionUpdate(activity: "Testing", lifecycle: .running))
                )
            ),
            .publication(
                PublicationFrame(
                    epoch: Generation(rawValue: 3),
                    sequence: 3,
                    payload: .permissionRequest(
                        PermissionRequest(
                            id: "permission-1",
                            verb: "Run",
                            subject: "tests",
                            options: [.init(id: "allow", label: "Allow", isLeastDestructive: true)]
                        )
                    )
                )
            ),
            .publication(
                PublicationFrame(
                    epoch: Generation(rawValue: 3),
                    sequence: 4,
                    payload: .commandRegion(
                        CommandRegionUpdate(commandID: "c1", phase: "D", exitCode: 0)
                    )
                )
            ),
            .publication(
                PublicationFrame(epoch: Generation(rawValue: 3), sequence: 5, payload: .heartbeat)
            ),
            .decision(
                DecisionFrame(
                    decisionID: "decision-1",
                    decisionGeneration: Generation(rawValue: 4),
                    permissionRequestID: "permission-1",
                    optionID: "allow",
                    epoch: Generation(rawValue: 3),
                    binding: binding
                )
            ),
            .decisionStatus(
                DecisionStatusFrame(
                    decisionID: "decision-1",
                    decisionGeneration: Generation(rawValue: 4),
                    status: .committed,
                    statusOrdinal: DecisionStatus.committed.ordinal,
                    binding: binding,
                    receipt: "effect-1"
                )
            ),
            .decisionQuery(
                DecisionQueryFrame(
                    decisionID: "decision-1",
                    decisionGeneration: Generation(rawValue: 4),
                    binding: binding
                )
            ),
            .decisionCancel(
                DecisionCancelFrame(
                    decisionID: "decision-1",
                    decisionGeneration: Generation(rawValue: 4),
                    binding: binding
                )
            ),
            .decisionAck(
                DecisionAckFrame(
                    decisionID: "decision-1",
                    decisionGeneration: Generation(rawValue: 4),
                    acknowledgedOutcome: .committed,
                    binding: binding
                )
            ),
        ]

        let encoder = FrameEncoder()
        for frame in frames {
            var decoder = FrameDecoder()
            let encoded = try encoder.encode(frame)
            let split = encoded.count / 2
            let first = decoder.append(encoded.prefix(split))
            let second = decoder.append(encoded.suffix(from: split))
            XCTAssertTrue(first.isEmpty)
            XCTAssertEqual(second, [.frame(frame)])
            XCTAssertTrue(decoder.finish().isEmpty)
        }
    }

    func testRejectsThreeHundredKilobyteLineWithoutRetainingPayload() {
        var decoder = FrameDecoder()
        var data = Data(repeating: 0x78, count: 300 * 1024)
        data.append(0x0A)

        let results = decoder.append(data)

        XCTAssertEqual(results, [.rejected(.lineTooLong(limit: FrameDecoder.maximumLineBytes))])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertEqual(decoder.rejectedBoundCount, 1)
    }

    func testRejectsNestingDepthFortyBeforeTypedDecode() {
        var decoder = FrameDecoder()
        let json = "{\"future\":" + String(repeating: "[", count: 40) + "0"
            + String(repeating: "]", count: 40) + "}\n"

        let results = decoder.append(Data(json.utf8))

        XCTAssertEqual(results, [.rejected(.nestingTooDeep(limit: FrameDecoder.maximumNestingDepth))])
        XCTAssertEqual(decoder.rejectedBoundCount, 1)
        XCTAssertEqual(decoder.ignoredUnknownFrameCount, 0)
    }

    func testRejectsPlanAndPermissionCountsBeforeTypedDecode() throws {
        let plan = (0...FrameDecoder.maximumPlanEntries).map {
            PlanEntry(id: "p\($0)", content: "item", status: .pending)
        }
        let planFrame = AllwardFrame.publication(
            PublicationFrame(epoch: .initial, sequence: 1, payload: .plan(plan))
        )
        var planDecoder = FrameDecoder()
        let planResults = planDecoder.append(try FrameEncoder().encode(planFrame))
        XCTAssertEqual(
            planResults,
            [.rejected(.tooManyPlanEntries(limit: FrameDecoder.maximumPlanEntries))]
        )

        let options = (0...FrameDecoder.maximumPermissionOptions).map {
            PermissionRequest.Option(id: "o\($0)", label: "option")
        }
        let permissionFrame = AllwardFrame.publication(
            PublicationFrame(
                epoch: .initial,
                sequence: 1,
                payload: .permissionRequest(
                    PermissionRequest(id: "request", verb: "Run", subject: "task", options: options)
                )
            )
        )
        var permissionDecoder = FrameDecoder()
        let permissionResults = permissionDecoder.append(try FrameEncoder().encode(permissionFrame))
        XCTAssertEqual(
            permissionResults,
            [.rejected(.tooManyPermissionOptions(limit: FrameDecoder.maximumPermissionOptions))]
        )
    }

    func testUnknownOptionalFrameIsIgnoredAndCounted() {
        var decoder = FrameDecoder()

        let results = decoder.append(Data("{\"futureTelemetry\":{\"value\":1}}\n".utf8))

        XCTAssertEqual(results, [.ignoredUnknownFrame])
        XCTAssertEqual(decoder.ignoredUnknownFrameCount, 1)
    }

    func testRejectsPublisherSuppliedProvenanceBeforeNormalization() throws {
        let publication = AllwardFrame.publication(
            PublicationFrame(epoch: .initial, sequence: 1, payload: .heartbeat)
        )
        let encoded = try FrameEncoder().encode(publication)
        let wire = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let injected = wire.replacingOccurrences(
            of: "\"_0\":{",
            with: "\"_0\":{\"source\":\"adapter_associated\",",
            options: [],
            range: wire.range(of: "\"_0\":{")
        )
        var decoder = FrameDecoder()

        let results = decoder.append(Data(injected.utf8))

        XCTAssertEqual(results, [.rejected(.reservedPublisherField("source"))])
    }

    func testUnknownOptionalCapabilityIsRemovedAndCounted() throws {
        let request = AllwardFrame.grantRequest(
            GrantRequest(
                capabilities: [.plans],
                harness: "omp",
                publisherName: "fixture",
                descriptor: "grant"
            )
        )
        let encoded = try FrameEncoder().encode(request)
        let replaced = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(of: "plans", with: "future_optional")
        )
        var decoder = FrameDecoder()

        let results = decoder.append(Data(replaced.utf8))

        guard case let .frame(.grantRequest(decoded)) = try XCTUnwrap(results.first) else {
            return XCTFail("Expected a filtered grant request")
        }
        XCTAssertEqual(decoded.capabilities, [])
        XCTAssertEqual(decoder.ignoredUnknownFrameCount, 1)
    }
}

final class GrantAndNormalizationTests: XCTestCase {
    func testUnsupportedMajorRejectsOnlyThatStream() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        let ledger = GrantLedger(clock: clock)
        let target = makeTarget()
        _ = await ledger.mintPublisherTargetKey(
            target: target,
            harness: "omp",
            publisherName: "bad",
            descriptor: "bad-grant",
            credentialGeneration: .initial
        )
        let rejected = await ledger.consume(
            GrantRequest(
                protocolMajor: 99,
                capabilities: [.plans],
                harness: "omp",
                publisherName: "bad",
                descriptor: "bad-grant"
            )
        )

        XCTAssertFalse(rejected.accepted)

        _ = await ledger.mintPublisherTargetKey(
            target: target,
            harness: "omp",
            publisherName: "good",
            descriptor: "good-grant",
            credentialGeneration: .initial
        )
        let accepted = await ledger.consume(
            GrantRequest(
                capabilities: [.plans],
                harness: "omp",
                publisherName: "good",
                descriptor: "good-grant"
            )
        )

        XCTAssertTrue(accepted.accepted)
        XCTAssertNotNil(accepted.publisher)
    }

    func testIdentityMismatchConsumesGrantAndFailsClosed() async {
        let ledger = GrantLedger(clock: FixedClock())
        _ = await ledger.mintPublisherTargetKey(
            target: makeTarget(),
            harness: "omp",
            publisherName: "expected",
            descriptor: "identity-grant",
            credentialGeneration: .initial
        )

        let mismatch = await ledger.consume(
            GrantRequest(
                capabilities: [.plans],
                harness: "other",
                publisherName: "expected",
                descriptor: "identity-grant"
            )
        )
        let replay = await ledger.consume(
            GrantRequest(
                capabilities: [.plans],
                harness: "omp",
                publisherName: "expected",
                descriptor: "identity-grant"
            )
        )

        XCTAssertFalse(mismatch.accepted)
        XCTAssertFalse(replay.accepted)
    }

    func testDuplicateAndResetWithinEpochAreIgnoredAndCounted() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 200))
        let ledger = GrantLedger(clock: clock)
        let publisher = try await grantPublisher(ledger: ledger, descriptor: "sequence-grant")
        let normalizer = PublicationNormalizer(clock: clock, ledger: ledger)

        let first = await normalizer.accept(
            PublicationFrame(epoch: publisher.epoch, sequence: 10, payload: .heartbeat),
            from: publisher
        )
        let duplicate = await normalizer.accept(
            PublicationFrame(epoch: publisher.epoch, sequence: 10, payload: .heartbeat),
            from: publisher
        )
        let reset = await normalizer.accept(
            PublicationFrame(epoch: publisher.epoch, sequence: 1, payload: .heartbeat),
            from: publisher
        )

        guard case let .accepted(normalized) = first else {
            return XCTFail("First sequence must be accepted")
        }
        XCTAssertEqual(normalized.source, .publisherDirect)
        XCTAssertEqual(normalized.observedAt, clock.now)
        XCTAssertEqual(normalized.publisher, publisher.publisher)
        XCTAssertEqual(duplicate, .ignored(.duplicateOrLowerSequence))
        XCTAssertEqual(reset, .ignored(.duplicateOrLowerSequence))
        let normalizerCounters = await normalizer.counters()
        let ledgerCounters = await ledger.counters()
        XCTAssertEqual(normalizerCounters.duplicateSequence, 2)
        XCTAssertEqual(ledgerCounters.duplicateSequence, 2)
    }

    func testLeaseExpiresAgainstFixedClock() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 300))
        let ledger = GrantLedger(clock: clock, minimumLeaseSeconds: 1, maximumLeaseSeconds: 60, defaultLeaseSeconds: 5)
        let publisher = try await grantPublisher(
            ledger: ledger,
            descriptor: "lease-grant",
            requestedLeaseSeconds: 5
        )

        let liveState = await ledger.leaseState(for: publisher.publisher)
        XCTAssertEqual(liveState, .live)
        clock.advance(by: 5)
        let staleState = await ledger.leaseState(for: publisher.publisher)
        XCTAssertEqual(staleState, .stale)
    }
}

final class PermissionDecisionTransactionTests: XCTestCase {
    func testCommittedTransactionIsTheOnlyGrantedOutcome() async {
        let dispatch = await makeDispatch()
        let target = await dispatch.transaction.snapshot().binding.publisherTargetKey
        _ = await dispatch.transaction.process(status(.accepted, dispatch: dispatch), from: target)
        let committed = await dispatch.transaction.process(status(.committed, dispatch: dispatch), from: target)

        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(committed.finalOutcome, .committed)
        XCTAssertEqual(committed.recordState, .granted)
    }

    func testRejectedAndCancelledNeverGrant() async {
        for outcome in [DecisionStatus.rejected, .cancelled] {
            let dispatch = await makeDispatch()
            let target = await dispatch.transaction.snapshot().binding.publisherTargetKey
            let snapshot = await dispatch.transaction.process(status(outcome, dispatch: dispatch), from: target)

            XCTAssertEqual(snapshot.phase, outcome == .rejected ? .rejected : .cancelled)
            XCTAssertNotEqual(snapshot.recordState, .granted)
        }
    }

    func testAcknowledgedPreservesEachFinalOutcome() async {
        let outcomes: [(DecisionStatus, PermissionDecisionFinalOutcome)] = [
            (.committed, .committed),
            (.rejected, .rejected),
            (.cancelled, .cancelled),
        ]

        for (statusValue, finalOutcome) in outcomes {
            let dispatch = await makeDispatch()
            let target = await dispatch.transaction.snapshot().binding.publisherTargetKey
            if statusValue == .committed {
                _ = await dispatch.transaction.process(status(.accepted, dispatch: dispatch), from: target)
            }
            _ = await dispatch.transaction.process(status(statusValue, dispatch: dispatch), from: target)
            let outcomeAck = await dispatch.transaction.acknowledgmentFrame()
            XCTAssertEqual(outcomeAck?.acknowledgedOutcome, statusValue)
            XCTAssertEqual(outcomeAck?.binding, dispatch.frame.binding)
            let acknowledged = await dispatch.transaction.process(
                status(.acknowledged, dispatch: dispatch, finalOutcome: statusValue),
                from: target
            )

            XCTAssertEqual(acknowledged.phase, .acknowledged)
            XCTAssertEqual(acknowledged.finalOutcome, finalOutcome)
            XCTAssertEqual(acknowledged.recordState, finalOutcome == .committed ? .granted :
                (finalOutcome == .rejected ? .denied : .cancelled))
        }
    }

    func testResponseLossProducesOutcomeUnknownAndCanOnlyRecoverByStatus() async {
        let dispatch = await makeDispatch()
        let target = await dispatch.transaction.snapshot().binding.publisherTargetKey

        let unknown = await dispatch.transaction.recordResponseLoss()
        XCTAssertEqual(unknown.phase, .outcomeUnknown)
        XCTAssertEqual(unknown.recordState, .outcomeUnknown)
        let query = await dispatch.transaction.queryFrame()
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.binding, dispatch.frame.binding)
        let cancel = await dispatch.transaction.cancelFrame()
        XCTAssertNil(cancel)

        let recovered = await dispatch.transaction.process(status(.committed, dispatch: dispatch), from: target)
        XCTAssertEqual(recovered.phase, .committed)
        XCTAssertEqual(recovered.recordState, .granted)
    }

    func testOutcomeUnknownCanBeAcknowledgedWithoutPromotion() async {
        let dispatch = await makeDispatch()
        let target = await dispatch.transaction.snapshot().binding.publisherTargetKey
        _ = await dispatch.transaction.recordResponseLoss()

        let acknowledged = await dispatch.transaction.process(status(.acknowledged, dispatch: dispatch), from: target)

        XCTAssertEqual(acknowledged.phase, .acknowledged)
        XCTAssertEqual(acknowledged.finalOutcome, .outcomeUnknown)
        XCTAssertEqual(acknowledged.recordState, .outcomeUnknown)
    }

    func testStaleGenerationStatusLeavesCurrentStateUnchangedAndRecordsReceipt() async {
        let dispatch = await makeDispatch()
        let target = await dispatch.transaction.snapshot().binding.publisherTargetKey
        let before = await dispatch.transaction.snapshot()
        var stale = status(.committed, dispatch: dispatch)
        stale.decisionGeneration = dispatch.frame.decisionGeneration.next

        let after = await dispatch.transaction.process(stale, from: target)

        XCTAssertEqual(after.phase, before.phase)
        XCTAssertEqual(after.recordState, before.recordState)
        XCTAssertEqual(after.receipts.last?.rejection, .staleGeneration)
    }

    func testWrongTargetStatusLeavesCurrentStateUnchangedAndRecordsReceipt() async {
        let dispatch = await makeDispatch()
        let before = await dispatch.transaction.snapshot()
        let correctTarget = before.binding.publisherTargetKey
        let wrongTarget = PublisherTargetKey(
            descriptor: "wrong",
            target: makeTarget(),
            credentialGeneration: Generation(rawValue: 88)
        )
        var wrongTargetStatus = status(.committed, dispatch: dispatch)
        wrongTargetStatus.binding.targetKey = wrongTarget

        let after = await dispatch.transaction.process(wrongTargetStatus, from: correctTarget)

        XCTAssertEqual(after.phase, before.phase)
        XCTAssertEqual(after.recordState, before.recordState)
        XCTAssertEqual(after.receipts.last?.rejection, .wrongTarget)
    }

    func testWrongRecordBindingAndOrdinalMismatchLeaveStateUnchanged() async {
        let dispatch = await makeDispatch()
        let before = await dispatch.transaction.snapshot()
        let target = before.binding.publisherTargetKey
        var wrongRecord = status(.accepted, dispatch: dispatch)
        wrongRecord.binding.recordID = RecordID()
        let afterWrongRecord = await dispatch.transaction.process(wrongRecord, from: target)
        XCTAssertEqual(afterWrongRecord.phase, before.phase)
        XCTAssertEqual(afterWrongRecord.receipts.last?.rejection, .wrongBinding)

        var wrongOrdinal = status(.accepted, dispatch: dispatch)
        wrongOrdinal.statusOrdinal = 99
        let afterWrongOrdinal = await dispatch.transaction.process(wrongOrdinal, from: target)
        XCTAssertEqual(afterWrongOrdinal.phase, before.phase)
        XCTAssertEqual(afterWrongOrdinal.receipts.last?.rejection, .ordinalMismatch)
    }
}

private func makeTarget() -> Target {
    Target(room: RoomID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
}

private func grantPublisher(
    ledger: GrantLedger,
    descriptor: String,
    requestedLeaseSeconds: TimeInterval? = nil
) async throws -> GrantedPublisher {
    _ = await ledger.mintPublisherTargetKey(
        target: makeTarget(),
        harness: "omp",
        publisherName: "fixture",
        descriptor: descriptor,
        credentialGeneration: .initial
    )
    let response = await ledger.consume(
        GrantRequest(
            capabilities: [.plans, .sessionUpdates, .permissions, .commandRegions],
            harness: "omp",
            publisherName: "fixture",
            descriptor: descriptor,
            requestedLeaseSeconds: requestedLeaseSeconds
        )
    )
    XCTAssertTrue(response.accepted)
    let publisher = await ledger.activePublisher(for: descriptor)
    return try XCTUnwrap(publisher)
}

private func makeDecisionBinding(epoch: Generation = Generation(rawValue: 3)) -> DecisionBinding {
    DecisionBinding(
        targetKey: PublisherTargetKey(
            descriptor: "decision-target",
            target: makeTarget(),
            credentialGeneration: Generation(rawValue: 2)
        ),
        recordID: RecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!),
        recordSequence: 7,
        connectionGeneration: Generation(rawValue: 3),
        ownershipGeneration: Generation(rawValue: 4),
        publisherEpoch: epoch
    )
}

private func makeDispatch() async -> PermissionDecisionDispatch {
    let targetKey = PublisherTargetKey(
        descriptor: "decision-target",
        target: makeTarget(),
        credentialGeneration: Generation(rawValue: 2)
    )
    let binding = PermissionDecisionBinding(
        permissionRequestID: "permission-1",
        optionID: "allow",
        normalizedPermissionRecordID: RecordID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        ),
        permissionRecordSequence: 7,
        publisherTargetKey: targetKey,
        connectionGeneration: Generation(rawValue: 3),
        publisherOwnershipGeneration: Generation(rawValue: 4),
        publisherEpoch: Generation(rawValue: 5)
    )
    let coordinator = PermissionDecisionCoordinator(makeDecisionID: { "decision-fixed" })
    return await coordinator.begin(binding)
}

private func status(
    _ status: DecisionStatus,
    dispatch: PermissionDecisionDispatch,
    finalOutcome: DecisionStatus? = nil
) -> DecisionStatusFrame {
    DecisionStatusFrame(
        decisionID: dispatch.frame.decisionID,
        decisionGeneration: dispatch.frame.decisionGeneration,
        status: status,
        statusOrdinal: status.ordinal,
        binding: dispatch.frame.binding,
        finalOutcome: finalOutcome,
        receipt: status == .committed ? "effect-receipt" : nil
    )
}
