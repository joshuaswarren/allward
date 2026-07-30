import Foundation

public enum HarnessKind: String, Hashable, Sendable, CaseIterable {
    case omp
    case claudeCode = "claude-code"
    case codex
    case plainShell = "plain-shell"
}

public struct AuthenticatedPublisherHarnessFact: Hashable, Sendable {
    public let harness: HarnessKind
    public let version: String?
    public let publisherIdentity: String

    public init(harness: HarnessKind, version: String?, publisherIdentity: String) {
        self.harness = harness
        self.version = version
        self.publisherIdentity = publisherIdentity
    }
}

public struct VerifiedAdapterHarnessFact: Hashable, Sendable {
    public let harness: HarnessKind
    public let version: String?
    public let adapterIdentity: String

    public init(harness: HarnessKind, version: String?, adapterIdentity: String) {
        self.harness = harness
        self.version = version
        self.adapterIdentity = adapterIdentity
    }
}
public struct HarnessProbeMatch: Hashable, Sendable {
    public let harness: HarnessKind
    public let version: String

    public init(harness: HarnessKind, version: String) {
        self.harness = harness
        self.version = version
    }
}

public enum ConsentedHarnessProbeResult: Hashable, Sendable {
    case notRequested
    case inProgress
    case exact(HarnessProbeMatch, probeIdentity: String)
    case ambiguous([HarnessProbeMatch])
    case noMatch
    case boundedFailure
}


public struct PaneHarnessFacts: Hashable, Sendable {
    public let authenticatedPublishers: [AuthenticatedPublisherHarnessFact]
    public let verifiedAdapterFacts: [VerifiedAdapterHarnessFact]
    public let consentedProbe: ConsentedHarnessProbeResult

    public init(
        authenticatedPublishers: [AuthenticatedPublisherHarnessFact] = [],
        verifiedAdapterFacts: [VerifiedAdapterHarnessFact] = [],
        consentedProbe: ConsentedHarnessProbeResult = .notRequested
    ) {
        self.authenticatedPublishers = authenticatedPublishers
        self.verifiedAdapterFacts = verifiedAdapterFacts
        self.consentedProbe = consentedProbe
    }
}

public enum HarnessEvidence: Hashable, Sendable {
    case authenticatedPublisher(identity: String)
    case verifiedAdapter(identity: String)
    case consentedProbe(identity: String)
}

public struct DetectedHarness: Hashable, Sendable {
    public let kind: HarnessKind
    public let version: String?
    public let evidence: HarnessEvidence

    public init(kind: HarnessKind, version: String?, evidence: HarnessEvidence) {
        self.kind = kind
        self.version = version
        self.evidence = evidence
    }
}

public enum HarnessAmbiguity: Hashable, Sendable {
    case conflictingAuthenticatedPublishers([HarnessKind])
    case conflictingPublisherVersions(harness: HarnessKind, versions: [String])
    case conflictingVerifiedAdapterFacts([HarnessKind])
    case conflictingAdapterVersions(harness: HarnessKind, versions: [String])
    case conflictingProbeMatches([HarnessKind])
}

public enum HarnessDetection: Hashable, Sendable {
    case detected(DetectedHarness)
    case probing
    case ambiguous(HarnessAmbiguity)
    case unknown
}

public enum HarnessInstallMethod: Hashable, Sendable {
    case ompPluginInstall
    case claudeHooksMerge
    case codexManualTrust
}

public struct HarnessInstallAction: Hashable, Sendable {
    public let method: HarnessInstallMethod
    public let title: String
    public let detail: String
    public let requiresManualStep: Bool

    public init(
        method: HarnessInstallMethod,
        title: String,
        detail: String,
        requiresManualStep: Bool
    ) {
        self.method = method
        self.title = title
        self.detail = detail
        self.requiresManualStep = requiresManualStep
    }
}

public struct HarnessDetector: Sendable {
    public init() {}

    public func detect(from facts: PaneHarnessFacts) -> HarnessDetection {
        if !facts.authenticatedPublishers.isEmpty {
            return publisherDetection(facts.authenticatedPublishers)
        }
        if !facts.verifiedAdapterFacts.isEmpty {
            return adapterDetection(facts.verifiedAdapterFacts)
        }
        switch facts.consentedProbe {
        case .notRequested, .noMatch, .boundedFailure:
            return .unknown
        case .inProgress:
            return .probing
        case let .exact(match, identity):
            return .detected(
                DetectedHarness(
                    kind: match.harness,
                    version: match.version,
                    evidence: .consentedProbe(identity: identity)
                )
            )
        case let .ambiguous(matches):
            return .ambiguous(.conflictingProbeMatches(orderedUnique(matches.map(\.harness))))
        }
    }

    public func consentedInstallAction(for harness: HarnessKind) -> HarnessInstallAction? {
        switch harness {
        case .omp:
            HarnessInstallAction(
                method: .ompPluginInstall,
                title: "Install omp plugin",
                detail: "Use omp's versioned plugin installation path after showing its source and planned changes.",
                requiresManualStep: false
            )
        case .claudeCode:
            HarnessInstallAction(
                method: .claudeHooksMerge,
                title: "Merge Claude Code hooks",
                detail: "Structurally merge the versioned hooks while preserving unrelated settings and hooks.",
                requiresManualStep: false
            )
        case .codex:
            HarnessInstallAction(
                method: .codexManualTrust,
                title: "Stage Codex integration and complete manual trust",
                detail: "Stage the versioned integration, then complete Codex's manual trust step yourself.",
                requiresManualStep: true
            )
        case .plainShell:
            nil
        }
    }

    private func publisherDetection(
        _ facts: [AuthenticatedPublisherHarnessFact]
    ) -> HarnessDetection {
        let kinds = orderedUnique(facts.map(\.harness))
        guard kinds.count == 1, let kind = kinds.first else {
            return .ambiguous(.conflictingAuthenticatedPublishers(kinds))
        }
        let versions = orderedUnique(facts.compactMap(\.version))
        guard versions.count <= 1 else {
            return .ambiguous(.conflictingPublisherVersions(harness: kind, versions: versions))
        }
        let identity = facts.map(\.publisherIdentity).sorted().joined(separator: ", ")
        return .detected(
            DetectedHarness(
                kind: kind,
                version: versions.first,
                evidence: .authenticatedPublisher(identity: identity)
            )
        )
    }

    private func adapterDetection(_ facts: [VerifiedAdapterHarnessFact]) -> HarnessDetection {
        let kinds = orderedUnique(facts.map(\.harness))
        guard kinds.count == 1, let kind = kinds.first else {
            return .ambiguous(.conflictingVerifiedAdapterFacts(kinds))
        }
        let versions = orderedUnique(facts.compactMap(\.version))
        guard versions.count <= 1 else {
            return .ambiguous(.conflictingAdapterVersions(harness: kind, versions: versions))
        }
        let identity = facts.map(\.adapterIdentity).sorted().joined(separator: ", ")
        return .detected(
            DetectedHarness(
                kind: kind,
                version: versions.first,
                evidence: .verifiedAdapter(identity: identity)
            )
        )
    }

    private func orderedUnique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen = Set<Value>()
        return values.filter { seen.insert($0).inserted }
    }
}
