import AllwardCore
import Foundation

public struct HarnessProbeCommand: Hashable, Sendable {
    public let harness: HarnessKind
    public let executable: String
    public let arguments: [String]
    public let exactVersionPattern: String

    public init(
        harness: HarnessKind,
        executable: String,
        arguments: [String],
        exactVersionPattern: String
    ) {
        self.harness = harness
        self.executable = executable
        self.arguments = arguments
        self.exactVersionPattern = exactVersionPattern
    }
}

public struct HarnessProbeOutput: Hashable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public protocol HarnessProbeTransport: Sendable {
    func runPinnedProbe(
        _ command: HarnessProbeCommand,
        bound: AttemptBound,
        maximumOutputBytes: Int
    ) async throws -> HarnessProbeOutput
}

public struct HarnessProbeRecipe: Hashable, Sendable {
    public let version: Int
    public let commands: [HarnessProbeCommand]
    public let bound: AttemptBound
    public let maximumOutputBytes: Int

    public init(
        version: Int,
        commands: [HarnessProbeCommand],
        bound: AttemptBound,
        maximumOutputBytes: Int
    ) {
        self.version = version
        self.commands = commands
        self.bound = bound
        self.maximumOutputBytes = maximumOutputBytes
    }

    public static let current = HarnessProbeRecipe(
        version: 1,
        commands: [
            HarnessProbeCommand(
                harness: .omp,
                executable: "/usr/bin/env",
                arguments: ["omp", "--version"],
                exactVersionPattern: #"\Aomp(?: version)? v?([0-9]+(?:\.[0-9]+){1,3})\z"#
            ),
            HarnessProbeCommand(
                harness: .claudeCode,
                executable: "/usr/bin/env",
                arguments: ["claude", "--version"],
                exactVersionPattern: #"\A(?:claude|claude code) v?([0-9]+(?:\.[0-9]+){1,3})\z"#
            ),
            HarnessProbeCommand(
                harness: .codex,
                executable: "/usr/bin/env",
                arguments: ["codex", "--version"],
                exactVersionPattern: #"\A(?:codex|codex-cli) v?([0-9]+(?:\.[0-9]+){1,3})\z"#
            ),
        ],
        bound: AttemptBound(maxAttempts: 1, perAttemptTimeout: 2, totalTimeout: 6),
        maximumOutputBytes: 4_096
    )
}

public struct ConsentedHarnessProbe: Sendable {
    public let recipe: HarnessProbeRecipe

    public init(recipe: HarnessProbeRecipe = .current) {
        self.recipe = recipe
    }

    public func run(
        consented: Bool,
        using transport: any HarnessProbeTransport
    ) async -> ConsentedHarnessProbeResult {
        guard consented else { return .notRequested }

        let attempts = await withTaskGroup(of: ProbeAttempt.self, returning: [ProbeAttempt].self) { group in
            for command in recipe.commands {
                group.addTask {
                    do {
                        let output = try await transport.runPinnedProbe(
                            command,
                            bound: self.recipe.bound,
                            maximumOutputBytes: self.recipe.maximumOutputBytes
                        )
                        return .output(command, output)
                    } catch {
                        return .failed
                    }
                }
            }

            var results: [ProbeAttempt] = []
            for await attempt in group {
                results.append(attempt)
            }
            return results
        }

        if attempts.contains(where: { $0.failedOrTimedOut(maximumOutputBytes: recipe.maximumOutputBytes) }) {
            return .boundedFailure
        }

        let matches = attempts.compactMap { attempt -> HarnessProbeMatch? in
            guard case let .output(command, output) = attempt,
                  output.exitCode == 0,
                  let version = exactVersion(in: output.standardOutput, command: command) else {
                return nil
            }
            return HarnessProbeMatch(harness: command.harness, version: version)
        }

        switch matches.count {
        case 0:
            return .noMatch
        case 1:
            let match = matches[0]
            return .exact(match, probeIdentity: "\(match.harness.rawValue)-probe-v\(recipe.version)")
        default:
            return .ambiguous(matches.sorted { $0.harness.rawValue < $1.harness.rawValue })
        }
    }

    private func exactVersion(
        in rawOutput: String,
        command: HarnessProbeCommand
    ) -> String? {
        let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let expression = try? NSRegularExpression(pattern: command.exactVersionPattern) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              match.range == range,
              let versionRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[versionRange])
    }

    private enum ProbeAttempt: Sendable {
        case output(HarnessProbeCommand, HarnessProbeOutput)
        case failed

        func failedOrTimedOut(maximumOutputBytes: Int) -> Bool {
            switch self {
            case let .output(_, output):
                output.timedOut
                    || output.standardOutput.utf8.count > maximumOutputBytes
                    || output.standardError.utf8.count > maximumOutputBytes
            case .failed:
                true
            }
        }
    }
}
