import Foundation

public enum ShellMismatchReason: Hashable, Sendable {
    case recordedVersion(recorded: Int, expected: Int)
    case ownedLineChanged
    case snippetChanged
    case noPublicationsThisSession
    case concurrentChange

    public var description: String {
        switch self {
        case let .recordedVersion(recorded, expected):
            "recorded v\(recorded), expected v\(expected)"
        case .ownedLineChanged:
            "owned line changed"
        case .snippetChanged:
            "owned snippet changed"
        case .noPublicationsThisSession:
            "no publications this session"
        case .concurrentChange:
            "shell configuration changed while applying the plan"
        }
    }
}

public enum ShellIntegrationLaneState: Hashable, Sendable {
    case notInstalled
    case installed
    case active
    case stale(ShellMismatchReason)
    case unsupported(shell: String)
}

public enum ShellPublicationObservation: Hashable, Sendable {
    case neverObserved
    case current
    case missingThisSession
}

public struct ShellIntegrationRecipe: Hashable, Sendable {
    public let version: Int
    public let rcLine: String
    public let relativeSnippetPath: String
    public let snippet: String

    public init(version: Int, rcLine: String, relativeSnippetPath: String, snippet: String) {
        self.version = version
        self.rcLine = rcLine
        self.relativeSnippetPath = relativeSnippetPath
        self.snippet = snippet
    }

    // LIMITATION: Socket-backed shell publication requires the 1.x remote allward-shell-publisher helper.
    public static let current = ShellIntegrationRecipe(
        version: 1,
        rcLine: "source \"$HOME/.config/allward/zsh-integration-v1.zsh\" # allward-owned:shell-integration:v1",
        relativeSnippetPath: ".config/allward/zsh-integration-v1.zsh",
        snippet: """
        # allward zsh integration v1
        _allward_osc() { printf '\033]%s\007' "$1"; }
        _allward_precmd() {
          local _allward_status=$?
          _allward_osc "133;D;$_allward_status"
          _allward_osc "7;file://$(hostname)${PWD// /%20}"
          _allward_osc '133;A'
        }
        _allward_preexec() { _allward_osc '133;B'; _allward_osc '133;C'; }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _allward_precmd
        add-zsh-hook preexec _allward_preexec
        """
    )
}

public struct ShellIntegrationPlan: Hashable, Sendable {
    public let recipeVersion: Int
    public let exactFile: String
    public let exactLine: String
    public let snippetFile: String
    public let snippet: String

    public init(
        recipeVersion: Int,
        exactFile: String,
        exactLine: String,
        snippetFile: String,
        snippet: String
    ) {
        self.recipeVersion = recipeVersion
        self.exactFile = exactFile
        self.exactLine = exactLine
        self.snippetFile = snippetFile
        self.snippet = snippet
    }
}

public struct ShellIntegrationRecord: Hashable, Sendable {
    public let recipeVersion: Int
    public let exactFile: String
    public let exactLine: String
    public let snippetFile: String
    public let ownedSnippet: String

    public init(plan: ShellIntegrationPlan) {
        recipeVersion = plan.recipeVersion
        exactFile = plan.exactFile
        exactLine = plan.exactLine
        snippetFile = plan.snippetFile
        ownedSnippet = plan.snippet
    }
}

public enum ShellIntegrationError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedShell(String)
    case conflict(ShellMismatchReason)
    case atomicWriteRejected

    public var errorDescription: String? {
        switch self {
        case let .unsupportedShell(shell):
            "Shell integration is not yet supported for \(shell)"
        case let .conflict(reason):
            reason.description
        case .atomicWriteRejected:
            ShellMismatchReason.concurrentChange.description
        }
    }
}

public struct ShellFileMutation: Hashable, Sendable {
    public let path: String
    public let expectedContents: String?
    public let replacementContents: String?

    public init(path: String, expectedContents: String?, replacementContents: String?) {
        self.path = path
        self.expectedContents = expectedContents
        self.replacementContents = replacementContents
    }
}

public protocol ShellIntegrationFileStore: Sendable {
    func readFile(at path: String) async throws -> String?
    func applyAtomically(_ mutations: [ShellFileMutation]) async throws -> Bool
}

public enum ShellApplyResult: Hashable, Sendable {
    case applied(ShellIntegrationRecord)
    case unchanged(ShellIntegrationRecord)
}

public enum ShellRemovalResult: Hashable, Sendable {
    case removed
    case unchanged
}

public struct ShellIntegration: Sendable {
    public let recipe: ShellIntegrationRecipe

    public init(recipe: ShellIntegrationRecipe = .current) {
        self.recipe = recipe
    }

    public func dryRun(loginShell: String, homeDirectory: String) throws -> ShellIntegrationPlan {
        let shell = normalizedShellName(loginShell)
        guard shell == "zsh" else { throw ShellIntegrationError.unsupportedShell(shell) }
        let home = homeDirectory.removingTrailingSlashes
        return ShellIntegrationPlan(
            recipeVersion: recipe.version,
            exactFile: "\(home)/.zshrc",
            exactLine: recipe.rcLine,
            snippetFile: "\(home)/\(recipe.relativeSnippetPath)",
            snippet: recipe.snippet
        )
    }

    public func detect(
        loginShell: String,
        record: ShellIntegrationRecord?,
        rcContents: String?,
        snippetContents: String?,
        publication: ShellPublicationObservation
    ) -> ShellIntegrationLaneState {
        let shell = normalizedShellName(loginShell)
        guard shell == "zsh" else { return .unsupported(shell: shell) }
        guard let record else { return .notInstalled }
        guard record.recipeVersion == recipe.version else {
            return .stale(.recordedVersion(recorded: record.recipeVersion, expected: recipe.version))
        }
        guard exactLineCount(record.exactLine, in: rcContents ?? "") == 1 else {
            return .stale(.ownedLineChanged)
        }
        guard snippetContents == record.ownedSnippet, record.ownedSnippet == recipe.snippet else {
            return .stale(.snippetChanged)
        }
        return switch publication {
        case .neverObserved: .installed
        case .current: .active
        case .missingThisSession: .stale(.noPublicationsThisSession)
        }
    }

    public func apply(
        loginShell: String,
        plan: ShellIntegrationPlan,
        using store: any ShellIntegrationFileStore
    ) async throws -> ShellApplyResult {
        let shell = normalizedShellName(loginShell)
        guard shell == "zsh" else { throw ShellIntegrationError.unsupportedShell(shell) }
        guard plan.recipeVersion == recipe.version,
              plan.exactLine == recipe.rcLine,
              plan.snippet == recipe.snippet else {
            throw ShellIntegrationError.conflict(.recordedVersion(
                recorded: plan.recipeVersion,
                expected: recipe.version
            ))
        }

        let rcContents = try await store.readFile(at: plan.exactFile)
        let snippetContents = try await store.readFile(at: plan.snippetFile)
        let ownedLineCount = exactLineCount(plan.exactLine, in: rcContents ?? "")
        if ownedLineCount == 1, snippetContents == plan.snippet {
            return .unchanged(ShellIntegrationRecord(plan: plan))
        }
        if ownedLineCount > 1 || (containsOwnedMarker(in: rcContents ?? "") && ownedLineCount == 0) {
            throw ShellIntegrationError.conflict(.ownedLineChanged)
        }
        if snippetContents != nil, snippetContents != plan.snippet {
            throw ShellIntegrationError.conflict(.snippetChanged)
        }

        let nextRC = ownedLineCount == 1
            ? rcContents ?? ""
            : appendingExactLine(plan.exactLine, to: rcContents ?? "")
        let mutations = [
            ShellFileMutation(
                path: plan.snippetFile,
                expectedContents: snippetContents,
                replacementContents: plan.snippet
            ),
            ShellFileMutation(
                path: plan.exactFile,
                expectedContents: rcContents,
                replacementContents: nextRC
            ),
        ]
        guard try await store.applyAtomically(mutations) else {
            throw ShellIntegrationError.atomicWriteRejected
        }
        return .applied(ShellIntegrationRecord(plan: plan))
    }

    public func remove(
        record: ShellIntegrationRecord,
        using store: any ShellIntegrationFileStore
    ) async throws -> ShellRemovalResult {
        let rcContents = try await store.readFile(at: record.exactFile)
        let snippetContents = try await store.readFile(at: record.snippetFile)
        let ownedLineCount = exactLineCount(record.exactLine, in: rcContents ?? "")
        let hasOwnedLine = ownedLineCount == 1

        if ownedLineCount > 1 {
            throw ShellIntegrationError.conflict(.ownedLineChanged)
        }
        if !hasOwnedLine, containsOwnedMarker(in: rcContents ?? "") {
            throw ShellIntegrationError.conflict(.ownedLineChanged)
        }
        if let snippetContents, snippetContents != record.ownedSnippet {
            throw ShellIntegrationError.conflict(.snippetChanged)
        }
        guard hasOwnedLine || snippetContents != nil else { return .unchanged }

        let nextRC = hasOwnedLine ? removingFirstExactLine(record.exactLine, from: rcContents ?? "") : rcContents
        var mutations: [ShellFileMutation] = []
        if hasOwnedLine {
            mutations.append(
                ShellFileMutation(
                    path: record.exactFile,
                    expectedContents: rcContents,
                    replacementContents: nextRC
                )
            )
        }
        if snippetContents != nil {
            mutations.append(
                ShellFileMutation(
                    path: record.snippetFile,
                    expectedContents: snippetContents,
                    replacementContents: nil
                )
            )
        }
        guard try await store.applyAtomically(mutations) else {
            throw ShellIntegrationError.atomicWriteRejected
        }
        return .removed
    }

    private func normalizedShellName(_ loginShell: String) -> String {
        let trimmed = loginShell.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    private func containsOwnedMarker(in contents: String) -> Bool {
        contents.split(separator: "\n", omittingEmptySubsequences: false).contains {
            $0.contains("# allward-owned:shell-integration:")
        }
    }

    private func exactLineCount(_ line: String, in contents: String) -> Int {
        contents.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, candidate in
            if String(candidate) == line {
                count += 1
            }
        }
    }

    private func appendingExactLine(_ line: String, to contents: String) -> String {
        guard !contents.isEmpty else { return line + "\n" }
        return contents.hasSuffix("\n") ? contents + line + "\n" : contents + "\n" + line + "\n"
    }

    private func removingFirstExactLine(_ line: String, from contents: String) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(of: line) {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var removingTrailingSlashes: String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
