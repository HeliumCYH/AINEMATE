import CoreGraphics
import Foundation

/// Window placement maths, kept free of AppKit so the edge cases that bit twice —
/// the card envelope hanging off the screen — can be asserted directly.
public enum Placement {
    /// Origin that keeps a `size` window inside `area`. When the window is larger
    /// than the area the min corner wins, so the result stays deterministic.
    public static func clamp(_ origin: CGPoint, size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(
            x: max(area.minX, min(origin.x, area.maxX - size.width)),
            y: max(area.minY, min(origin.y, area.maxY - size.height)))
    }

    /// The sprite sits at the bottom-centre of the envelope, so the envelope can
    /// overhang an edge while the pet is still fully on screen. When the card is
    /// below the pet the sprite is lifted by the card's slot, `inset`, instead.
    public static func spriteRect(
        windowOrigin: CGPoint, windowSize: CGSize, spriteSize: CGSize,
        inset: CGFloat = 0) -> CGRect {
        CGRect(
            x: windowOrigin.x + (windowSize.width - spriteSize.width) / 2,
            y: windowOrigin.y + inset,
            width: spriteSize.width,
            height: spriteSize.height)
    }

    /// Window origin that puts the sprite's bottom-left corner on `origin`, given
    /// which side the card is on. Flipping that side moves the window, never the
    /// sprite — the pet under the cursor must not jump.
    public static func windowOrigin(
        forSpriteAt origin: CGPoint, windowSize: CGSize, spriteSize: CGSize,
        cardInset: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x - (windowSize.width - spriteSize.width) / 2,
            y: origin.y - cardInset)
    }

    /// Whether the eye should track the pointer. The body and an open card both
    /// hold it: following the cursor across the card makes the pet stare at the
    /// card it just offered instead of playing its state.
    public static func gazeFollows(sprite: CGRect, card: CGRect?, pointer: CGPoint) -> Bool {
        !sprite.contains(pointer) && !(card?.contains(pointer) ?? false)
    }

    /// Whether the card has to open under the pet instead of over it. The sprite
    /// is the part being dragged, so it decides: the card goes above until that
    /// would leave it hanging off the top of `area`, then it goes below.
    ///
    /// `currentlyBelow` carries the previous answer, because a card that already
    /// moved below must not move back the moment `cardHeight` of room appears —
    /// a pet parked near the threshold would flip the card on every pixel of a
    /// drag. It returns above only once there is `hysteresis` of slack.
    public static func cardOpensBelow(
        sprite: CGRect, in area: CGRect, cardHeight: CGFloat, spacing: CGFloat,
        currentlyBelow: Bool, hysteresis: CGFloat = 24) -> Bool {
        let above = area.maxY - (sprite.maxY + spacing)
        let below = sprite.minY - spacing - area.minY
        if currentlyBelow {
            return !(above >= cardHeight + hysteresis || above > below)
        }
        return above < cardHeight && below >= above
    }
}
