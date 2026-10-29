import AimateCore
import Combine
import CoreGraphics
import Foundation

/// Frame clock. Each atlas row carries its own per-frame durations, so the timer
/// is re-scheduled per frame rather than running at a fixed rate.
@MainActor
final class SpritePlayer: ObservableObject {
    @Published private(set) var image: CGImage?

    private var sheet: SpriteSheet?
    private var animation = PetAnimation.idle
    private var frameIndex = 0
    private var gazeIndex: Int?
    private var timer: Timer?
    private var paused = false

    var reduceMotion = false {
        didSet { restart() }
    }

    func load(_ sheet: SpriteSheet) {
        self.sheet = sheet
        frameIndex = 0
        render()
    }

    func setAnimation(_ next: PetAnimation) {
        guard next.row != animation.row else { return }
        animation = next
        frameIndex = 0
        render()
    }

    /// A gaze pose freezes the row on the pose the pointer is asking for; the
    /// neutral deadzone is the caller's responsibility (it passes `nil`).
    func setGaze(_ index: Int?) {
        guard index != gazeIndex else { return }
        gazeIndex = index
        render()
    }

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if value { stopTimer() } else { scheduleTick() }
    }

    func restart() {
        frameIndex = 0
        render()
    }

    private func render() {
        guard let sheet else { return }
        if let gazeIndex {
            let cell = AtlasLayout.lookCell(for: gazeIndex)
            image = sheet.cell(row: cell.row, column: cell.column)
            stopTimer()
            return
        }
        image = sheet.cell(row: animation.row, column: min(frameIndex, animation.frameCount - 1))
        if reduceMotion || paused { stopTimer() } else { scheduleTick() }
    }

    private func scheduleTick() {
        stopTimer()
        guard !reduceMotion, !paused, frameIndex < animation.frameCount else { return }
        let nextIndex = (frameIndex + 1) % animation.frameCount
        let delay = TimeInterval(animation.durationsMs[frameIndex]) / 1000
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.frameIndex = nextIndex
                self.render()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
