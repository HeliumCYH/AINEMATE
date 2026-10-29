import CoreGraphics
import Foundation

/// One playable animation: an atlas row plus the dwell time of each frame.
/// Tables are transcribed from the Codex v2 pet contract (`animation-rows.md`).
public struct PetAnimation: Equatable, Sendable {
    public let name: String
    public let row: Int
    public let durationsMs: [Int]

    public var frameCount: Int { durationsMs.count }

    init(name: String, row: Int, durationsMs: [Int]) {
        self.name = name
        self.row = row
        self.durationsMs = durationsMs
    }

    public var totalDurationMs: Int { durationsMs.reduce(0, +) }

    public static let idle = PetAnimation(
        name: "idle", row: 0, durationsMs: [280, 110, 110, 140, 140, 320])
    /// The atlas paints the right-facing pose in row 2: the look rows agree,
    /// since 90° (pointer due right) also puts the face on the right half of the
    /// cell. The row table in the shipped contract has these two labelled the
    /// other way round, so the numbers here follow the art, not the table.
    public static let runningRight = PetAnimation(
        name: "running-right", row: 2, durationsMs: [120, 120, 120, 120, 120, 120, 120, 220])
    public static let runningLeft = PetAnimation(
        name: "running-left", row: 1, durationsMs: [120, 120, 120, 120, 120, 120, 120, 220])
    public static let waving = PetAnimation(
        name: "waving", row: 3, durationsMs: [140, 140, 140, 280])
    public static let jumping = PetAnimation(
        name: "jumping", row: 4, durationsMs: [140, 140, 140, 140, 280])
    public static let failed = PetAnimation(
        name: "failed", row: 5, durationsMs: [140, 140, 140, 140, 140, 140, 140, 240])
    public static let waiting = PetAnimation(
        name: "waiting", row: 6, durationsMs: [150, 150, 150, 150, 150, 260])
    public static let running = PetAnimation(
        name: "running", row: 7, durationsMs: [120, 120, 120, 120, 120, 220])
    public static let review = PetAnimation(
        name: "review", row: 8, durationsMs: [150, 150, 150, 150, 150, 280])

    /// Rows 9 and 10 form one continuous clockwise 16-pose look loop.
    public static let lookRowA = 9
    public static let lookRowB = 10

    public static func from(state: PetState) -> PetAnimation {
        switch state {
        case .idle: return .idle
        case .running: return .running
        case .waiting: return .waiting
        case .review: return .review
        case .failed: return .failed
        }
    }

    /// The 8x9 standard grid; `waving`/`jumping` are gestures with no backing state.
    public static let all: [PetAnimation] = [
        .idle, .runningRight, .runningLeft, .waving, .jumping,
        .failed, .waiting, .running, .review,
    ]
}

/// Atlas geometry and the gaze quantizer, both lifted from the runtime constants.
public enum AtlasLayout {
    public static let columns = 8
    public static let rows = 11
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let widthPx = columns * cellWidth      // 1536
    public static let heightPx = rows * cellHeight       // 2288
    public static let aspectRatio = Double(cellWidth) / Double(cellHeight)

    public static let minMascotWidth: CGFloat = 80
    public static let maxMascotWidth: CGFloat = 224
    public static let defaultMascotWidth: CGFloat = 128

    /// Mirrors `p(e)` in `avatar-overlay-mascot-size`: clamp then round.
    public static func mascotWidthPx(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return defaultMascotWidth }
        return round(min(maxMascotWidth, max(minMascotWidth, raw)))
    }

    /// Pointer angle to one of 16 clockwise poses, taking AppKit-style deltas
    /// where positive `dy` is *above* the pet. `0` is up / 12 o'clock; the caller
    /// treats a too-close pointer as the neutral deadzone and falls back to the
    /// state animation instead.
    public static func lookIndex(pointerDX dx: CGFloat, pointerDY dy: CGFloat) -> Int {
        let degrees = (atan2(-dy, dx) * 180 / .pi + 450).truncatingRemainder(dividingBy: 360)
        return Int((degrees / 22.5).rounded()) % 16
    }

    public static func lookCell(for index: Int) -> (row: Int, column: Int) {
        let i = ((index % 16) + 16) % 16
        return (i < 8 ? PetAnimation.lookRowA : PetAnimation.lookRowB, i % columns)
    }

    /// Cell rect inside an atlas of `atlasSize` pixels. `CGImage.cropping(to:)`
    /// counts rows from the top, which is also the order the contract documents:
    /// cropping the shipped sheets at `y = row * 208` puts idle at row 0 and the
    /// red failed face at row 5.
    public static func cellRect(row: Int, column: Int, atlasSize: CGSize) -> CGRect {
        let cellW = atlasSize.width / CGFloat(columns)
        let cellH = atlasSize.height / CGFloat(rows)
        return CGRect(x: CGFloat(column) * cellW,
                      y: CGFloat(row) * cellH,
                      width: cellW,
                      height: cellH)
    }
}
