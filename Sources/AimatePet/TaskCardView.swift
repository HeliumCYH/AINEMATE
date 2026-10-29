import AimateCore
import SwiftUI

/// The hover card: one row per session, in the order the sessions started.
/// Exactly one row is expanded at a time, and it is expanded where it sits —
/// the glass bubble travels to it instead of the row travelling to the top.
struct TaskCardView: View {
    @ObservedObject var model: PetViewModel

    /// The bubble's identity is the selection, not the row: when the expanded
    /// session changes the glass slides from the old row to the new one.
    @Namespace private var bubble

    /// A card with an ask on screen shows one row fewer rather than clipping the
    /// answer buttons, which are the only way to unblock the sender.
    static let visibleRows = 5
    static let shortRows = 4

    var body: some View {
        let rows = model.orderedActors
        let expanded = model.displayedActor
        let base = expanded?.options?.isEmpty == false ? Self.shortRows : Self.visibleRows
        // The "另有 N 个会话" line costs a row of its own; without this the card
        // grew past the fixed panel and clipped its top edge.
        let cap = rows.count > base ? base - 1 : base
        let shown = Self.visible(rows, cap: cap, focus: expanded?.id)
        return VStack(alignment: .leading, spacing: 3) {
            if rows.isEmpty {
                idle
            } else {
                ForEach(shown) { actor in
                    SessionRow(
                        model: model, actor: actor,
                        expanded: actor.id == expanded?.id,
                        roomy: shown.count == 1,
                        namespace: bubble)
                }
                if rows.count > shown.count {
                    Text("另有 \(rows.count - shown.count) 个会话")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        // Order and expansion animate in the same spring, so a session that
        // finishes and floats to the top glides there instead of jumping.
        .animation(spring, value: shown.map(\.id))
        .animation(spring, value: expanded?.id)
    }

    private var spring: Animation? {
        model.settings.reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72)
    }

    /// The expanded row stays on screen even when the list is capped: it takes
    /// the last slot instead of reordering the rows around it.
    static func visible(_ rows: [Actor], cap: Int, focus: String?) -> [Actor] {
        guard rows.count > cap else { return rows }
        var shown = Array(rows.prefix(cap))
        if let focus, !shown.contains(where: { $0.id == focus }),
           let focused = rows.first(where: { $0.id == focus }) {
            shown[cap - 1] = focused
        }
        return shown
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(stateColor(.idle)).frame(width: 7, height: 7)
                Text("空闲").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
            }
            Text("没有正在进行的任务")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

/// One line of the session list. The header is the tap target end to end:
/// tapping it brings the glass bubble here, tapping it again releases the
/// bubble back to the automatic pick. Nothing reorders on selection.
struct SessionRow: View {
    @ObservedObject var model: PetViewModel
    let actor: Actor
    let expanded: Bool
    let roomy: Bool
    let namespace: Namespace.ID

    private var finished: Bool { actor.state == .review }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
                .padding(.horizontal, 6)
                .padding(.vertical, expanded ? 0 : 2)
            if expanded {
                details
            }
        }
        .padding(.vertical, expanded ? 6 : 0)
        .background {
            if expanded { bubbleShape }
        }
        .background {
            if !expanded && finished { redCapsule }
        }
    }

    private var header: some View {
        HStack(spacing: 3) {
            Button {
                model.select(actor)
            } label: {
                headerContent
            }
            .buttonStyle(.plain)
            .help(hint)
            .accessibilityLabel(
                "\(Actor.agentName(for: actor.source))，\(actor.state.displayLabel)，\(actor.title)")
            .accessibilityHint(hint)
            ackControl
        }
    }

    private var headerContent: some View {
        HStack(spacing: 5) {
            Circle().fill(finished ? Color.red : stateColor(actor.state))
                .frame(width: 5, height: 5)
            AgentBadge(source: actor.source, compact: true)
            Text(actor.state.displayLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(finished ? Color.red : Color.primary.opacity(0.8))
            if !expanded {
                Text(actor.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// A finished row offers its own end: the tick clears it now, so the pet
    /// stops asking while the tick is still on screen. The slot is reserved for
    /// every row, so adding or dropping it never shifts the chevron.
    @ViewBuilder private var ackControl: some View {
        if finished {
            Button {
                model.acknowledge(actor)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color(ns: 0x5F_D08A))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("标记已读")
            .accessibilityLabel("标记已读")
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(actor.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(roomy ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
            // A session without a detail keeps its line, so the card does not
            // resize as the bubble moves between rows.
            Text(actor.detail ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(roomy ? 2 : 1)
                .opacity(actor.detail == nil ? 0 : 1)
            if let options = actor.options, !options.isEmpty {
                answers(options)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func answers(_ options: [String]) -> some View {
        HStack(spacing: 6) {
            if let reply = model.reply(for: actor) {
                Label("已选择 \(reply.option)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options, id: \.self) { option in
                    PetActionButton(title: option, isPrimary: option == options.first) {
                        model.answer(actor, option)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// The frosted glass the bubble is made of. It carries the geometry match, so
    /// the same glass travels between rows instead of fading out and in.
    private var bubbleShape: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0.05)],
                startPoint: .top, endPoint: .bottom))
            if finished {
                shape.fill(Color.red.opacity(0.16))
                shape.strokeBorder(Color.red.opacity(0.6), lineWidth: 1)
            } else {
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.45), .white.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
        .matchedGeometryEffect(id: "session-bubble", in: namespace)
    }

    /// A finished session is the one asking to be looked at, so its row is
    /// wrapped in red even while it is collapsed.
    private var redCapsule: some View {
        let capsule = Capsule(style: .continuous)
        return capsule
            .fill(Color.red.opacity(0.16))
            .overlay(capsule.strokeBorder(Color.red.opacity(0.5), lineWidth: 1))
    }

    private var hint: String {
        let name = Actor.agentName(for: actor.source)
        return expanded ? "\(name) 会话已展开" : "展开 \(name) 会话"
    }
}

private func stateColor(_ state: PetState) -> Color {
    switch state.tone {
    case .warning: return .orange
    case .danger: return .red
    case .success: return .green
    case .info: return .blue
    case .neutral: return .gray
    }
}
