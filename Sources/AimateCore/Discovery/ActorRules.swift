import Foundation

/// Rules every pull adapter shares, so a Codex turn and a Qoder turn expire and
/// read the same way in the card.
enum ActorRules {
    /// How long an actor stays renderable after its last state-changing event.
    /// A sender that forgets to clear itself therefore falls back to idle.
    /// Review is short: a finished turn is news for a moment, and the card's ✓
    /// clears it at once for anyone who is looking.
    static func ttl(for state: PetState) -> TimeInterval {
        switch state {
        case .running: return 180
        case .waiting: return 900
        case .review: return 20
        case .failed: return 180
        case .idle: return 0
        }
    }

    /// Card headlines are single-line and short; agent prompts are neither.
    static func trim(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        let collapsed = oneLine.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > 72 ? String(collapsed.prefix(71)) + "…" : collapsed
    }

    static func humanDuration(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 { return String(format: "%.0f 秒", seconds) }
        let minutes = Int(seconds / 60)
        let rest = Int(seconds.truncatingRemainder(dividingBy: 60))
        return minutes > 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分 \(rest) 秒"
    }

    static func humanSeconds(_ seconds: Int) -> String {
        humanDuration(seconds * 1000)
    }

    /// Last path component of a working directory, used as the fallback name for
    /// a session the agent has not titled yet.
    static func directoryLabel(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
