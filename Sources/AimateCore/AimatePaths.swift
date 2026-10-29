import Foundation

/// Every path the pet reads or writes. All of them hang off one directory so
/// the whole feature can be removed by deleting `~/.aimate`.
public enum AimatePaths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["AIMATE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aimate", isDirectory: true)
    }

    public static var petRoot: URL { root.appendingPathComponent("pet", isDirectory: true) }
    public static var actorsDir: URL { petRoot.appendingPathComponent("actors", isDirectory: true) }
    /// Where the pet writes the user's answer to a card that asked for one.
    public static var repliesDir: URL { petRoot.appendingPathComponent("replies", isDirectory: true) }
    public static var petsDir: URL { root.appendingPathComponent("pets", isDirectory: true) }
    /// Where the user's "I have seen this" marks live. Kept apart from replies:
    /// an ack is the pet's own bookkeeping, never something a sender waits on.
    public static var seenDir: URL { petRoot.appendingPathComponent("seen", isDirectory: true) }
    public static var settingsFile: URL { petRoot.appendingPathComponent("settings.json") }
    public static var anchorFile: URL { petRoot.appendingPathComponent("anchor.json") }
    /// Rewritten every pet tick. Senders check its age before asking anything,
    /// so a closed pet falls through to the agent's own prompt instead of
    /// making the user wait out a timeout they cannot see.
    public static var heartbeatFile: URL { petRoot.appendingPathComponent("live.stamp") }

    /// OpenAI's own custom-pet location, so pets the user already hatched work.
    public static var codexPetsDir: URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let base = codexHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        return base.appendingPathComponent("pets", isDirectory: true)
    }

    public static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [root, petRoot, actorsDir, repliesDir, seenDir, petsDir] where !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
