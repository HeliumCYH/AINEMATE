import AimateCore
import CoreGraphics
import Foundation
import Testing

@Suite("v2 atlas geometry")
struct AtlasLayoutTests {
    @Test("mascot width clamps and rounds")
    func mascotWidth() {
        #expect(AtlasLayout.mascotWidthPx(40) == 80)
        #expect(AtlasLayout.mascotWidthPx(900) == 224)
        #expect(AtlasLayout.mascotWidthPx(127.6) == 128)
        #expect(AtlasLayout.mascotWidthPx(.nan) == AtlasLayout.defaultMascotWidth)
    }

    @Test("cell rects map the grid onto a 1536x2288 atlas")
    func cellRects() {
        // Rows are counted from the top, the order the contract documents.
        let atlas = CGSize(width: 1536, height: 2288)
        #expect(AtlasLayout.cellRect(row: 0, column: 0, atlasSize: atlas)
            == CGRect(x: 0, y: 0, width: 192, height: 208))
        #expect(AtlasLayout.cellRect(row: 10, column: 7, atlasSize: atlas)
            == CGRect(x: 1344, y: 2080, width: 192, height: 208))
    }

    @Test(arguments: [
        (CGFloat(0), CGFloat(40), 0),    // up / 12 o'clock
        (CGFloat(40), CGFloat(0), 4),    // 3 o'clock
        (CGFloat(0), CGFloat(-40), 8),   // 6 o'clock
        (CGFloat(-40), CGFloat(0), 12),  // 9 o'clock
        (CGFloat(40), CGFloat(40), 2),   // 1:30
    ])
    func lookIndex(dx: CGFloat, dy: CGFloat, expected: Int) {
        #expect(AtlasLayout.lookIndex(pointerDX: dx, pointerDY: dy) == expected)
    }

    @Test("look poses span rows nine and ten")
    func lookCells() {
        #expect(AtlasLayout.lookCell(for: 0).row == 9)
        #expect(AtlasLayout.lookCell(for: 7) == (9, 7))
        #expect(AtlasLayout.lookCell(for: 8) == (10, 0))
        #expect(AtlasLayout.lookCell(for: 15) == (10, 7))
    }

    @Test("standard rows match the contract's frame counts and durations")
    func animationTable() {
        #expect(PetAnimation.all.map { $0.row } == [0, 2, 1, 3, 4, 5, 6, 7, 8])
        #expect(PetAnimation.all.map { $0.frameCount } == [6, 8, 8, 4, 5, 8, 6, 6, 6])
        #expect(PetAnimation.idle.durationsMs == [280, 110, 110, 140, 140, 320])
        #expect(PetAnimation.waiting.durationsMs == [150, 150, 150, 150, 150, 260])
        #expect(PetAnimation.failed.durationsMs.last == 240)
        #expect(PetAnimation.review.durationsMs.last == 280)
    }

    @Test("the run rows point the way the art does")
    func facing() {
        // In this atlas the face sits on the right half of the cell in row 2 and
        // on the left half in row 1, so a pet carried to the right has to play 2.
        #expect(PetAnimation.runningRight.row == 2)
        #expect(PetAnimation.runningLeft.row == 1)
    }

    @Test("locomotion direction comes from the drag vector")
    func locomotion() {
        #expect(PetState.running.atlasRow(dragDX: 12) == .runningRight)
        #expect(PetState.running.atlasRow(dragDX: -12) == .runningLeft)
        #expect(PetState.running.atlasRow(dragDX: 1) == .running)
        #expect(PetState.running.atlasRow(dragDX: 4) == .runningRight)
    }

    @Test("a carried pet runs whatever it was doing before")
    func locomotionOverridesState() {
        #expect(PetState.idle.atlasRow(dragDX: 99) == .runningRight)
        #expect(PetState.idle.atlasRow(dragDX: -99) == .runningLeft)
        #expect(PetState.waiting.atlasRow(dragDX: 8) == .runningRight)
        #expect(PetState.failed.atlasRow(dragDX: -8) == .runningLeft)
        #expect(PetState.review.atlasRow(dragDX: 8) == .runningRight)
        // Below the runtime's 4 pt step threshold the status row stays.
        #expect(PetState.idle.atlasRow(dragDX: 3.9) == .idle)
        #expect(PetState.waiting.atlasRow(dragDX: -3.9) == .waiting)
    }
}

@Suite("state aggregation")
struct StateAggregationTests {
    @Test("priority matches the runtime ordering")
    func precedence() {
        #expect(PetState.precedence == [.waiting, .failed, .review, .running, .idle])
        #expect(PetState.waiting < .running)
        #expect(PetState.failed < .review)
    }

    @Test("dominant actor is the highest priority, not the most recent")
    func dominantByPriority() {
        let now = Date()
        let snapshot = ActorSnapshot(actors: [
            Actor(id: "a", source: "s", state: .review, title: "r", updatedAt: now),
            Actor(id: "b", source: "s", state: .running, title: "w", updatedAt: now.addingTimeInterval(10)),
            Actor(id: "c", source: "s", state: .waiting, title: "wait", updatedAt: now.addingTimeInterval(-20)),
        ])
        #expect(snapshot.dominant?.id == "c")
    }

    @Test("equal priority falls back to recency")
    func tiesByRecency() {
        let now = Date()
        let snapshot = ActorSnapshot(actors: [
            Actor(id: "old", source: "s", state: .waiting, title: "x", updatedAt: now.addingTimeInterval(-30)),
            Actor(id: "new", source: "s", state: .waiting, title: "y", updatedAt: now),
        ])
        #expect(snapshot.dominant?.id == "new")
    }

    @Test("badge tones follow the observed mapping")
    func tones() {
        #expect(PetState.waiting.tone == .warning)
        #expect(PetState.failed.tone == .danger)
        #expect(PetState.running.tone == .info)
        #expect(PetState.review.tone == .success)
    }
}
