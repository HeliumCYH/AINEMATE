import AimateCore
import AppKit
import SwiftUI

struct PetRootView: View {
    @ObservedObject var model: PetViewModel

    private var width: CGFloat { model.mascotWidth }
    private var height: CGFloat { model.spriteHeight }

    var body: some View {
        VStack(alignment: .center, spacing: PetViewModel.cardSpacing) {
            if model.cardBelow {
                sprite
                slot
            } else {
                slot
                sprite
            }
        }
        // The sprite owns the edge the card is not on, so the envelope stays the
        // fixed size it was sized for and only the pet's edge moves.
        .frame(width: model.envelopeSize.width, height: model.envelopeSize.height,
               alignment: model.cardBelow ? .top : .bottom)
        .animation(expandAnimation, value: model.isExpanded)
        .animation(noticeAnimation, value: model.completion)
    }

    /// The card grows out of the edge nearest the pet; the spring gives it a
    /// little overshoot so it reads as elastic rather than mechanical. A user who
    /// asked for reduced motion gets the plain fade.
    private var expandAnimation: Animation {
        model.settings.reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.36, dampingFraction: 0.7)
    }

    /// The card's slot, or the completion pill while the card is closed. Both
    /// sit the same gap from the sprite, so the pill appears exactly where the
    /// card would open — and because the slot is outside the sprite, neither can
    /// move the pet or the rows.
    @ViewBuilder private var slot: some View {
        if model.isExpanded {
            TaskCardView(model: model)
                .frame(width: model.cardWidth)
                // The card grows out of the edge nearest the pet on whichever
                // side it opened.
                .transition(.opacity.combined(
                    with: .scale(scale: 0.92, anchor: model.cardBelow ? .top : .bottom)))
        } else if let completion = model.completion {
            CompletionPill(notice: completion)
                .transition(.opacity.combined(
                    with: .scale(scale: 0.82, anchor: model.cardBelow ? .top : .bottom)))
        }
    }

    private var sprite: some View {
        PetSpriteView(model: model)
            .frame(width: width, height: height)
    }

    /// Fixed so the pill's own frame is its final frame: the pop starts at its
    /// bottom edge instead of sliding in from the card slot.
    static let pillHeight: CGFloat = 22

    private var noticeAnimation: Animation {
        model.settings.reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.22, dampingFraction: 0.62)
    }
}

/// The completion pill from the concept sheet: one glass line, the check in the
/// success green, then the count and the product that finished. It is not
/// interactive — the card is where anything can be answered.
struct CompletionPill: View {
    let notice: CompletionNotice

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(Color(ns: 0x5F_D08A))
                Text("✓")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(ns: 0x0B_1610))
            }
            .frame(width: 13, height: 13)
            Text(notice.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(ns: 0xE8_EAED))
            if let agent = notice.agentLabel {
                Text("· \(agent)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(ns: 0x8A_9199))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(height: PetRootView.pillHeight)
        .background {
            let capsule = Capsule(style: .continuous)
            ZStack {
                capsule.fill(.ultraThinMaterial)
                capsule.fill(Color(ns: 0x1E_232A).opacity(0.62))
                capsule.fill(LinearGradient(
                    colors: [.white.opacity(0.16), .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom))
                capsule.strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.42), radius: 9, y: 4)
        .accessibilityLabel([
            notice.title, notice.agentLabel.map { "来自 \($0)" } ?? ""
        ].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

struct PetSpriteView: View {
    @ObservedObject var model: PetViewModel
    @ObservedObject var player: SpritePlayer

    init(model: PetViewModel) {
        self.model = model
        self.player = model.player
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let frame = player.image {
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                FallbackBubble(state: model.dominant?.state ?? .idle)
            }
            if model.lastError != nil {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(4)
                    .help(model.lastError ?? "")
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let state = (model.dominant?.state ?? .idle).displayLabel
        guard let title = model.dominant?.title else { return "桌宠：\(state)" }
        return "桌宠：\(state)，\(title)"
    }
}

/// Shown until an atlas loads, so a missing pet package is visible instead of blank.
struct FallbackBubble: View {
    let state: PetState

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
            Text(state.displayLabel).font(.system(size: 11))
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var symbol: String {
        switch state {
        case .waiting: return "questionmark.bubble"
        case .failed: return "exclamationmark.triangle"
        case .review: return "eye"
        case .running: return "hammer"
        case .idle: return "pawprint"
        }
    }
}

/// Agent name beside the state label. The capsule keeps its own metrics, so a
/// row does not resize when the bubble moves onto it.
///
/// Hex sources: `#F77825` is the accent in Qoder CN.app's qoduck mascot art
/// (`application-icons/qoduck-light.png`); the app icon and wordmark themselves are
/// greyscale, so the duck is the only saturated Qoder brand asset on this machine.
/// `#6D7FF7` is the dominant fill of ChatGPT.app's `icon-codex-light.png`.
/// `#4D6BFE` is DeepSeek's public blue — the installed Harness app is monochrome
/// (`icon.png` samples a near-neutral `#333740`), so this one is brand, not sample.
/// OpenCode ships no colour at all: `#211E1E`/`#CFCECD` are its site's ink and text,
/// so its plate is the palette inverted — light plate, dark ink.
struct AgentBadge: View {
    let source: String
    var compact = false

    var body: some View {
        Text(Actor.agentName(for: source))
            .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(ink)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1 : 1.5)
            .background(Capsule().fill(plate))
            .accessibilityLabel("来自 \(Actor.agentName(for: source))")
    }

    private var plate: Color {
        switch Actor.agentTint(for: source) {
        case .amber: return Color(ns: 0xF7_7825)
        case .indigo: return Color(ns: 0x6D_7FF7)
        case .azure: return Color(ns: 0x4D_6BFE)
        case .ink: return Color(ns: 0xE3_E2E1)
        case .slate: return Color(ns: 0x64_748B)
        }
    }

    private var ink: Color {
        Actor.agentTint(for: source) == .ink ? Color(ns: 0x21_1E1E) : .white
    }
}

/// A card action. The capsule is the tap target end to end, and the primary
/// choice is the filled one so a two-button ask reads without a second look.
///
/// Sized for the widest row the product sends — OpenCode's 允许一次/始终允许/拒绝
/// is 182 pt of a 212 pt interior at 11 pt semibold — so a third choice costs no
/// resize. Widths beyond that (a translated or sender-supplied label) shrink to
/// 80% and then truncate instead of wrapping, because a second line would push
/// the roster out of the fixed panel.
struct PetActionButton: View {
    let title: String
    let isPrimary: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isPrimary ? Color.accentColor : Color.primary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .accessibilityHint("在桌宠上作答，发送方会立刻收到")
    }
}

extension Color {
    /// sRGB hex, so the brand values above stay readable where they were taken from.
    init(ns hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
