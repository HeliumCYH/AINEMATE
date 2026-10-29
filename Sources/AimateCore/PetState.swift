import CoreGraphics
import Foundation

/// The five states the pet contract exposes, plus the two locomotion gestures
/// that are derived from a drag vector rather than from an agent.
public enum PetState: String, Codable, CaseIterable, Comparable, Sendable {
    case idle
    case running
    case waiting
    case review
    case failed

    /// Aggregation order recovered from the Codex runtime: a multi-thread tray
    /// shows the highest-priority state across all active actors.
    public static let precedence: [PetState] = [.waiting, .failed, .review, .running, .idle]

    /// Ordering is "more urgent first", so `waiting < running` and a plain
    /// ascending sort puts the actor the pet should show at the front.
    public static func < (lhs: PetState, rhs: PetState) -> Bool {
        precedence.firstIndex(of: lhs)! < precedence.firstIndex(of: rhs)!
    }

    /// Atlas row to play for this state, given a horizontal drag delta in points.
    /// `un()` in the overlay runtime overrides the status row with locomotion for
    /// any dragged pet, not only a busy one: moving the sprite is itself the
    /// gesture, so an idle pet still runs while it is carried.
    public func atlasRow(dragDX: CGFloat) -> PetAnimation {
        if dragDX >= 4 { return .runningRight }
        if dragDX <= -4 { return .runningLeft }
        return .from(state: self)
    }

    /// Colour tone for the task-card badge.
    public var tone: PetTone {
        switch self {
        case .waiting: return .warning
        case .failed: return .danger
        case .review: return .success
        case .running: return .info
        case .idle: return .neutral
        }
    }

    public var displayLabel: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "工作中"
        case .waiting: return "等待你"
        case .review: return "待检查"
        case .failed: return "出错了"
        }
    }
}

public enum PetTone: String, Sendable {
    case warning, danger, success, info, neutral
}
