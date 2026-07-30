import Foundation

/// The single source of the product version. `scripts/make-app.sh` reads this
/// literal, so the bundle and the binary can never disagree.
public let allwardVersion = "0.1.0"

/// Reverse-DNS bundle identity, used for the receiver-issued socket directory
/// and for anything that must namespace per-application state.
public let allwardBundleIdentifier = "ai.allward.Allward"

/// The directory Allward owns for runtime descriptors and state. Never `/tmp`:
/// publishers receive the resolved path through their environment instead of
/// assuming one (SPEC §6).
public enum AllwardPaths {
    public static func runtimeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            return URL(fileURLWithPath: runtime, isDirectory: true)
                .appendingPathComponent("allward", isDirectory: true)
        }
        return
            home
            .appendingPathComponent("Library/Application Support/Allward/run", isDirectory: true)
    }

    public static func supportDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/Allward", isDirectory: true)
    }

    public static func configurationFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".config/allward/allward.toml")
    }
}
