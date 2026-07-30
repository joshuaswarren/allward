import AllwardCore
import Foundation
import FoundationModels

public struct SessionNamingFacts: Hashable, Sendable {
    public var workingDirectory: String?
    public var runningCommand: String?
    public var host: HostAlias?

    public init(
        workingDirectory: String?,
        runningCommand: String?,
        host: HostAlias?
    ) {
        self.workingDirectory = workingDirectory
        self.runningCommand = runningCommand
        self.host = host
    }
}

public enum SessionNameSource: Hashable, Sendable {
    case heuristic
    case onDeviceModel
}

public struct SessionName: Hashable, Sendable {
    public var value: String
    public var source: SessionNameSource

    public init(value: String, source: SessionNameSource) {
        self.value = value
        self.source = source
    }
}

public struct SessionNaming: Sendable {
    public init() {}

    public func name(for facts: SessionNamingFacts) async -> SessionName {
        let baseline = heuristicName(for: facts)
        guard #available(macOS 26.0, *) else { return baseline }

        let model = SystemLanguageModel.default
        guard model.availability == .available, model.supportsLocale(.current) else {
            return baseline
        }
        guard modelInputIsBounded(facts) else { return baseline }

        let session = LanguageModelSession(
            model: model,
            instructions: "Create short, neutral terminal session names from only the supplied facts."
        )
        let prompt = """
        Name this terminal session in sentence case using at most 48 characters.
        Do not add urgency, progress, success, failure, or facts not present here.
        Working directory: \(facts.workingDirectory ?? "unknown")
        Running command: \(facts.runningCommand ?? "unknown")
        Host alias: \(facts.host?.rawValue ?? "unknown")
        Return only the name.
        """

        do {
            let response = try await session.respond(to: prompt)
            guard let candidate = validatedModelName(response.content, facts: facts) else {
                return baseline
            }
            return SessionName(value: candidate, source: .onDeviceModel)
        } catch {
            return baseline
        }
    }

    public func heuristicName(for facts: SessionNamingFacts) -> SessionName {
        var parts: [String] = []
        if let directory = usefulDirectoryName(facts.workingDirectory) {
            parts.append(directory)
        }
        if let command = usefulCommand(facts.runningCommand),
           !parts.contains(where: { $0.caseInsensitiveCompare(command) == .orderedSame }) {
            parts.append(command)
        }
        if let host = usefulComponent(facts.host?.rawValue),
           !parts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
            parts.append(host)
        }
        if parts.isEmpty {
            parts.append("Terminal")
        }

        let combined = parts.joined(separator: " · ")
        return SessionName(value: sentenceCase(shortened(combined, limit: 48)), source: .heuristic)
    }

    private func validatedModelName(_ raw: String, facts: SessionNamingFacts) -> String? {
        let oneLine = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard let oneLine, !oneLine.isEmpty, oneLine.count <= 48 else { return nil }

        let source = [facts.workingDirectory, facts.runningCommand, facts.host?.rawValue]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let forbidden = ["urgent", "asap", "critical", "immediately", "blocked"]
        let lowercased = oneLine.lowercased()
        guard !forbidden.contains(where: { lowercased.contains($0) && !source.contains($0) }) else {
            return nil
        }
        let sourceWords = Set(normalizedWords(in: source))
        let genericWords: Set<String> = ["session", "terminal"]
        let candidateWords = Set(normalizedWords(in: oneLine))
        guard candidateWords.subtracting(sourceWords).subtracting(genericWords).isEmpty else {
            return nil
        }
        return sentenceCase(oneLine)
    }

    private func usefulDirectoryName(_ path: String?) -> String? {
        guard let path = usefulComponent(path) else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    private func usefulCommand(_ commandLine: String?) -> String? {
        guard let commandLine = usefulComponent(commandLine) else { return nil }
        let words = commandLine.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return nil }

        let executable = URL(fileURLWithPath: String(first)).lastPathComponent
        let ignored = ["zsh", "bash", "fish", "sh", "login"]
        guard !ignored.contains(executable.lowercased()) else { return nil }

        let selected = [executable] + words.dropFirst().prefix(1).map(String.init)
        return selected.joined(separator: " ")
    }

    private func usefulComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let prefix = String(value.prefix(limit))
        if let boundary = prefix.lastIndex(where: \.isWhitespace) {
            return String(prefix[..<boundary]).trimmingCharacters(in: .whitespaces)
        }
        return prefix
    }

    private func modelInputIsBounded(_ facts: SessionNamingFacts) -> Bool {
        let directoryBytes = facts.workingDirectory?.utf8.count ?? 0
        let commandBytes = facts.runningCommand?.utf8.count ?? 0
        let hostBytes = facts.host?.rawValue.utf8.count ?? 0
        return directoryBytes <= 1_024
            && commandBytes <= 2_048
            && hostBytes <= 256
            && directoryBytes + commandBytes + hostBytes <= 3_072
    }

    private func normalizedWords(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}
