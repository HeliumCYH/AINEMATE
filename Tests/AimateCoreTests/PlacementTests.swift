import AimateCore
import CoreGraphics
import Foundation
import Testing

@Suite("window placement")
struct PlacementTests {
    private let envelope = CGSize(width: 232, height: 277)
    private let sprite = CGSize(width: 128, height: 138.6)
    private let screen = CGRect(x: 0, y: 0, width: 1470, height: 923)

    @Test("a corner anchor keeps the whole envelope on screen")
    func cornerClamp() {
        // The sprite sits 40pt from the right edge, which would push the wider
        // card envelope 12pt past it.
        let sidePadding = (envelope.width - sprite.width) / 2
        let raw = CGPoint(x: screen.maxX - envelope.width + sidePadding - 40, y: 32)
        #expect(raw == CGPoint(x: 1250, y: 32))
        let clamped = Placement.clamp(raw, size: envelope, in: screen)
        #expect(clamped.x == screen.maxX - envelope.width)
        #expect(clamped.y == 32)
    }

    @Test("an origin that already fits is left alone")
    func untouched() {
        let origin = CGPoint(x: 400, y: 300)
        #expect(Placement.clamp(origin, size: envelope, in: screen) == origin)
    }

    @Test("an oversized window falls back to the min corner")
    func oversized() {
        let huge = CGSize(width: 2000, height: 2000)
        #expect(Placement.clamp(CGPoint(x: 900, y: 900), size: huge, in: screen)
                == CGPoint(x: screen.minX, y: screen.minY))
    }

    @Test("the sprite is bottom-centred, so an overhanging envelope can stay put")
    func spriteRect() {
        let rect = Placement.spriteRect(windowOrigin: CGPoint(x: 1290, y: 300),
                                         windowSize: envelope, spriteSize: sprite)
        #expect(rect.midX == 1290 + envelope.width / 2)
        #expect(rect.minY == 300)
        // Envelope runs to 1522, off a 1470 screen, yet the pet itself fits.
        #expect(screen.contains(rect))
        #expect(!screen.contains(CGRect(origin: CGPoint(x: 1290, y: 300), size: envelope)))
    }

    // MARK: - Card side

    /// 1470×923 screen with a 30 pt menu bar and an 81 pt Dock.
    private let visible = CGRect(x: 0, y: 81, width: 1470, height: 812)
    private let cardHeight: CGFloat = 176
    private let spacing: CGFloat = 6
    private let cardInset: CGFloat = 182

    private func sprite(atY y: CGFloat, x: CGFloat = 600) -> CGRect {
        CGRect(x: x, y: y, width: sprite.width, height: sprite.height)
    }

    private func below(_ rect: CGRect, currentlyBelow: Bool = false) -> Bool {
        Placement.cardOpensBelow(
            sprite: rect, in: visible, cardHeight: cardHeight, spacing: spacing,
            currentlyBelow: currentlyBelow)
    }

    @Test("the card opens above a pet with room over its head")
    func cardAboveByDefault() {
        // 300 pt of clear air above the sprite.
        #expect(!below(sprite(atY: visible.maxY - sprite.height - spacing - 300)))
        #expect(!below(sprite(atY: visible.minY + 32)))
    }

    @Test("a pet at the top of the screen opens its card below")
    func cardBelowAtTop() {
        // Sprite top at the visible top: nothing above it, which is exactly the
        // case that used to leave the card hanging off the menu bar.
        #expect(below(sprite(atY: visible.maxY - sprite.height)))
        #expect(below(sprite(atY: visible.maxY - sprite.height - 20)))
        // Above the menu bar entirely, the same answer.
        #expect(below(sprite(atY: visible.maxY + 40)))
    }

    @Test("a card already below stays below until there is slack")
    func hysteresis() {
        // 180 pt of room above: enough for the card, not enough to re-open it
        // without asking, so a pet parked here does not flip on every drag step.
        let snug = sprite(atY: visible.maxY - sprite.height - spacing - 180)
        #expect(!below(snug))
        #expect(below(snug, currentlyBelow: true))
        // 300 pt above is slack enough to go back over the pet.
        let roomy = sprite(atY: visible.maxY - sprite.height - spacing - 300)
        #expect(!below(roomy, currentlyBelow: true))
    }

    @Test("a screen too short for either side keeps the card above")
    func noRoomAnywhere() {
        let cramped = CGRect(x: 0, y: 81, width: 1470, height: 300)
        let rect = CGRect(x: 600, y: 100, width: sprite.width, height: sprite.height)
        #expect(!Placement.cardOpensBelow(
            sprite: rect, in: cramped, cardHeight: cardHeight, spacing: spacing,
            currentlyBelow: false))
    }

    @Test("flipping the card side moves the window, never the sprite")
    func flipKeepsSprite() {
        let window = CGSize(width: envelope.width, height: 321)
        let origin = CGPoint(x: 600, y: 700)
        let over = Placement.windowOrigin(
            forSpriteAt: origin, windowSize: window, spriteSize: sprite, cardInset: 0)
        let under = Placement.windowOrigin(
            forSpriteAt: origin, windowSize: window, spriteSize: sprite, cardInset: cardInset)
        // The window slides down by the card slot; the sprite stays on the cursor.
        #expect(under.y == over.y - cardInset)
        #expect(Placement.spriteRect(windowOrigin: over, windowSize: window,
                                     spriteSize: sprite).origin == origin)
        #expect(Placement.spriteRect(windowOrigin: under, windowSize: window,
                                     spriteSize: sprite, inset: cardInset).origin == origin)
    }

    @Test("the eye yields on the body and on an open card, and only there")
    func gazeGate() {
        let body = CGRect(x: 100, y: 100, width: 115, height: 125)
        let openCard = CGRect(x: 40, y: 231, width: 232, height: 182)
        #expect(!Placement.gazeFollows(sprite: body, card: openCard, pointer: CGPoint(x: 150, y: 150)))
        #expect(!Placement.gazeFollows(sprite: body, card: openCard, pointer: CGPoint(x: 150, y: 300)))
        #expect(Placement.gazeFollows(sprite: body, card: openCard, pointer: CGPoint(x: 500, y: 150)))
        // With the card closed, the same point above the pet follows again.
        #expect(Placement.gazeFollows(sprite: body, card: nil, pointer: CGPoint(x: 150, y: 300)))
    }
}
