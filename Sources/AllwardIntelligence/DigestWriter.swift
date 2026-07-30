import AllwardCore
import Foundation
import FoundationModels

public struct DigestFact: Hashable, Sendable, Identifiable {
    public let id: RecordID
    public let text: String

    public init(id: RecordID = RecordID(), text: String) {
        self.id = id
        self.text = text
    }
}

public struct DeterministicDigest: Hashable, Sendable {
    public let facts: [DigestFact]

    public init(facts: [DigestFact]) {
        self.facts = facts
    }
}

public struct DigestRewrite: Hashable, Sendable {
    public let facts: [DigestFact]
    public let closingSentence: String?
    public let usedOnDeviceModel: Bool

    public init(
        facts: [DigestFact],
        closingSentence: String?,
        usedOnDeviceModel: Bool
    ) {
        self.facts = facts
        self.closingSentence = closingSentence
        self.usedOnDeviceModel = usedOnDeviceModel
    }

    public var renderedLines: [String] {
        facts.map(\.text) + [closingSentence].compactMap { $0 }
    }
}

public struct DigestWriter: Sendable {
    public let bound = AttemptBound.localPrepare

    public init() {}

    public func rewrite(_ deterministic: DeterministicDigest) async -> DigestRewrite {
        let unchanged = DigestRewrite(
            facts: deterministic.facts,
            closingSentence: nil,
            usedOnDeviceModel: false
        )
        guard !deterministic.facts.isEmpty, bound.maxAttempts > 0 else { return unchanged }
        guard #available(macOS 26.0, *) else { return unchanged }

        let model = SystemLanguageModel.default
        guard model.availability == .available, model.supportsLocale(.current) else {
            return unchanged
        }

        guard let candidate = await boundedClosingSentence(
            facts: deterministic.facts,
            model: model
        ), let validated = validate(candidate, against: deterministic.facts) else {
            return unchanged
        }

        return DigestRewrite(
            facts: deterministic.facts,
            closingSentence: validated,
            usedOnDeviceModel: true
        )
    }

    @available(macOS 26.0, *)
    private func boundedClosingSentence(
        facts: [DigestFact],
        model: SystemLanguageModel
    ) async -> String? {
        guard facts.count <= 64,
              facts.allSatisfy({ $0.text.count <= 512 }),
              facts.reduce(into: 0, { $0 += $1.text.count }) <= 8_192 else {
            return nil
        }
        let factLines = facts.enumerated().map { index, fact in
            "\(index + 1). \(fact.text)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(
            model: model,
            instructions: "Write one extractive, neutral digest closing sentence using only supplied fact words."
        )
        let prompt = """
        Write one sentence of at most 120 characters. Use only facts below.
        Do not change their order, declare completion, add urgency, or infer missing state.
        Facts:
        \(factLines)
        """
        let timeout = min(bound.perAttemptTimeout, bound.totalTimeout)

        return await withTaskGroup(of: RewriteRace.self, returning: String?.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: prompt)
                    return .value(response.content)
                } catch {
                    return .unavailable
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }

            let first = await group.next() ?? .unavailable
            group.cancelAll()
            if case let .value(value) = first { return value }
            return nil
        }
    }

    private func validate(_ raw: String, against facts: [DigestFact]) -> String? {
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard let candidate, !candidate.isEmpty, candidate.count <= 120 else { return nil }

        let factWords = Set(facts.flatMap { normalizedWords(in: $0.text) })
        let allowedFunctionWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "of", "on",
            "or", "the", "to", "with",
        ]
        let candidateWords = Set(normalizedWords(in: candidate))
        guard candidateWords.subtracting(factWords).subtracting(allowedFunctionWords).isEmpty else {
            return nil
        }

        let completionOrUrgency: Set<String> = [
            "asap", "closed", "complete", "completed", "critical", "done", "finished", "fixed", "immediately",
            "passed", "resolved", "shipped", "succeeded", "success", "successful", "urgent",
        ]
        guard candidateWords.isDisjoint(with: completionOrUrgency) else { return nil }
        return candidate
    }

    private func normalizedWords(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private enum RewriteRace: Sendable {
        case value(String)
        case unavailable
        case timedOut
    }
}
