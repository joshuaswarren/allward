import Foundation

/// Which revision this binary was built from, for telling one test build from the
/// next.
///
/// The facts come from the bundle's `Info.plist`, written by `scripts/make-app.sh`
/// and `scripts/make-mas-app.sh`. Reading them at runtime rather than baking them
/// into a generated source file keeps the build one scriptable command and means an
/// unbundled binary degrades to `unknown` instead of lying.
public struct BuildInfo: Hashable, Sendable {
    /// Short commit, or nil when this binary was not built from a known revision.
    public let commit: String?
    /// Whether the tree had uncommitted changes to tracked files. A test build of
    /// work in progress is the normal case here, so this is a fact rather than a
    /// warning.
    public let isDirty: Bool
    public let builtAt: Date?
    /// `debug` or `release`.
    public let configuration: String?
    /// Which product: the two are both called Allward and behave differently.
    public let product: String?
    public let version: String

    public init(
        commit: String?,
        isDirty: Bool,
        builtAt: Date?,
        configuration: String?,
        product: String?,
        version: String = allwardVersion
    ) {
        self.commit = commit
        self.isDirty = isDirty
        self.builtAt = builtAt
        self.configuration = configuration
        self.product = product
        self.version = version
    }

    /// Info.plist keys. Named here so the scripts and the reader cannot drift
    /// apart without one place to look.
    public enum Key {
        public static let commit = "AllwardBuildCommit"
        public static let dirty = "AllwardBuildDirty"
        public static let date = "AllwardBuildDate"
        public static let configuration = "AllwardBuildConfiguration"
        public static let product = "AllwardBuildProduct"
    }

    public static let current = BuildInfo(bundle: .main)

    public init(bundle: Bundle) {
        func string(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                !value.isEmpty,
                value != "unknown"
            else { return nil }
            return value
        }
        commit = string(Key.commit)
        isDirty = string(Key.dirty) == "true"
        builtAt = string(Key.date).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        configuration = string(Key.configuration)
        product = string(Key.product)
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? allwardVersion
    }

    /// True when nothing is known, which is what an unbundled `swift build` binary
    /// reports. Saying so is the point: a blank About panel would read as a release.
    public var isUnknown: Bool { commit == nil && builtAt == nil }

    /// The one line that answers "am I running the build I just made".
    ///
    /// `0.1.0 (a1b2c3d4e5f6, modified)` beside a `git rev-parse --short=12 HEAD` is
    /// a direct comparison, which is the whole reason the commit is not abbreviated
    /// further.
    public var shortSummary: String {
        guard let commit else { return "\(version) (unknown build)" }
        return isDirty ? "\(version) (\(commit), modified)" : "\(version) (\(commit))"
    }

    /// The multi-line block the About panel and `--version` both print, so the two
    /// can never disagree about what this build is.
    public var details: [(label: String, value: String)] {
        var rows: [(String, String)] = [("Version", version)]
        rows.append(("Commit", commit.map { isDirty ? "\($0) (modified)" : $0 } ?? "unknown"))
        if let builtAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            rows.append(("Built", formatter.string(from: builtAt)))
        } else {
            rows.append(("Built", "unknown"))
        }
        if let configuration { rows.append(("Configuration", configuration)) }
        if let product { rows.append(("Product", product)) }
        return rows
    }

    public var plainText: String {
        details.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}
