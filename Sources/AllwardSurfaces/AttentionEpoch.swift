import AllwardCore
import Foundation

public struct AttentionEpochID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var subject: String
    public var ordinal: UInt64

    public init(subject: String, ordinal: UInt64) {
        self.subject = subject
        self.ordinal = ordinal
    }

    public var description: String { "\(subject)#\(ordinal)" }
}

public struct AttentionAcknowledgmentToken: Hashable, Sendable, Codable {
    public var recordID: RecordID
    public var epoch: AttentionEpochID

    public init(recordID: RecordID, epoch: AttentionEpochID) {
        self.recordID = recordID
        self.epoch = epoch
    }
}

struct AttentionEpochTracker: Hashable, Sendable {
    private struct Signature: Hashable, Sendable {
        var recordID: RecordID
        var actionID: String
        var target: Target
        var attentionClass: AttentionClass

        static func == (lhs: Signature, rhs: Signature) -> Bool {
            lhs.actionID == rhs.actionID
                && lhs.target == rhs.target
                && lhs.attentionClass == rhs.attentionClass
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(actionID)
            hasher.combine(target)
            hasher.combine(attentionClass)
        }
    }

    private var nextOrdinal: UInt64 = 1
    private var openBySubject: [String: Signature] = [:]
    private var epochByRecord: [RecordID: AttentionEpochID] = [:]
    private var acknowledgedBySubject: [String: Signature] = [:]

    mutating func observe(_ records: [SurfaceReducedRecord]) -> [RecordID] {
        let actionable = records.filter {
            $0.projection.eligibility.boardActionable && $0.projection.eligibility.routerClass != nil
        }
        let activeSubjects = Set(actionable.map(subjectKey))
        for subject in Array(openBySubject.keys) where !activeSubjects.contains(subject) {
            if let closed = openBySubject.removeValue(forKey: subject) {
                epochByRecord.removeValue(forKey: closed.recordID)
            }
        }
        for subject in Array(acknowledgedBySubject.keys) where !activeSubjects.contains(subject) {
            acknowledgedBySubject.removeValue(forKey: subject)
        }

        var opened: [RecordID] = []
        for reduced in actionable.sorted(by: BoardReducer.lessThan) {
            let subject = subjectKey(reduced)
            let signature = actionSignature(reduced)
            if let current = openBySubject[subject], current == signature {
                if current.recordID != signature.recordID {
                    let epoch = epochByRecord.removeValue(forKey: current.recordID)
                    openBySubject[subject] = signature
                    epochByRecord[signature.recordID] = epoch
                }
                continue
            }
            if acknowledgedBySubject[subject] == signature {
                openBySubject.removeValue(forKey: subject)
                epochByRecord.removeValue(forKey: reduced.record.id)
                continue
            }
            acknowledgedBySubject.removeValue(forKey: subject)
            if let old = openBySubject.updateValue(signature, forKey: subject) {
                epochByRecord.removeValue(forKey: old.recordID)
            }
            let epoch = AttentionEpochID(subject: subject, ordinal: nextOrdinal)
            nextOrdinal &+= 1
            epochByRecord[reduced.record.id] = epoch
            opened.append(reduced.record.id)
        }
        return opened
    }

    mutating func acknowledgeLocally(_ token: AttentionAcknowledgmentToken) -> Bool {
        guard epochByRecord[token.recordID] == token.epoch,
              let signature = openBySubject[token.epoch.subject] else { return false }
        epochByRecord.removeValue(forKey: token.recordID)
        openBySubject.removeValue(forKey: token.epoch.subject)
        acknowledgedBySubject[token.epoch.subject] = signature
        return true
    }

    func epoch(for recordID: RecordID) -> AttentionEpochID? {
        epochByRecord[recordID]
    }

    func isLocallyAcknowledged(_ reduced: SurfaceReducedRecord) -> Bool {
        acknowledgedBySubject[subjectKey(reduced)] == actionSignature(reduced)
    }

    private func subjectKey(_ reduced: SurfaceReducedRecord) -> String {
        let record = reduced.record
        return [
            record.target.room.rawValue.uuidString.lowercased(),
            record.target.session?.rawValue.uuidString.lowercased() ?? "",
            record.target.pane?.rawValue.uuidString.lowercased() ?? "",
            record.publisher?.rawValue.uuidString.lowercased() ?? "",
            reduced.effectiveSubjectID
        ].joined(separator: "|")
    }

    private func actionSignature(_ reduced: SurfaceReducedRecord) -> Signature {
        Signature(
            recordID: reduced.record.id,
            actionID: actionID(for: reduced.record),
            target: reduced.record.target,
            attentionClass: reduced.projection.eligibility.routerClass ?? .running
        )
    }

    private func actionID(for record: NormalizedRecord) -> String {
        guard let permission = record.permission else { return record.title }
        let options = permission.options.map {
            "\($0.id)=\($0.label)"
        }.joined(separator: "|")
        return [permission.id, permission.verb, permission.subject, options].joined(separator: "|")
    }
}
