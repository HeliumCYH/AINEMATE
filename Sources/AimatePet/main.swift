import AimateCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: PetViewModel?
    private var controller: PetWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AimatePaths.ensureDirectories()
        let model = PetViewModel()
        model.start()
        let controller = PetWindowController(model: model)
        controller.show()
        self.model = model
        self.controller = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)

// Dev-only visual check: `AIMATE_SNAPSHOT=/tmp/card.png AimatePet` renders the task
// card offscreen and exits. It exists so the card can be inspected pixel by pixel
// when no display is awake; a normal launch never takes this branch.
if let path = ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT"] {
    application.appearance = NSAppearance(named: .darkAqua)
    MainActor.assumeIsolated {
        SnapshotCard.write(to: URL(fileURLWithPath: path), model: SnapshotCard.model())
    }
    exit(0)
}

// Dev-only visual check for the completion pill: renders the whole envelope, so
// the pill's position inside the card slot can be measured without hovering.
if let path = ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT_PET"] {
    application.appearance = NSAppearance(named: .darkAqua)
    MainActor.assumeIsolated {
        let model = SnapshotCard.noticeModel()
        // `AIMATE_SNAPSHOT_PET_WAIT=3.4` lets the notice's own timer run before
        // the render, so the end of the 3 s window is checked rather than assumed.
        if let wait = ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT_PET_WAIT"]
            .flatMap(Double.init) {
            RunLoop.main.run(until: Date().addingTimeInterval(wait))
        }
        SnapshotCard.writePet(to: URL(fileURLWithPath: path), model: model)
    }
    exit(0)
}

application.run()

@MainActor
enum SnapshotCard {
    /// `AIMATE_SNAPSHOT_LIVE=1` renders the card from the actor files the running
    /// pet is looking at, which is how a real two-session card gets inspected
    /// without hovering the pointer over it.
    static func model() -> PetViewModel {
        let live = ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT_LIVE"] != nil
        let model = live
            ? PetViewModel(store: ActorStore(), adapters: [], settings: PetSettings.load())
            : fixture()
        model.refresh()
        // `AIMATE_SNAPSHOT_PIN=<id>` renders the same card with the bubble on
        // another row, which is how the "expand in place" layout is checked.
        if let pin = ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT_PIN"],
           let actor = model.snapshot.actors.first(where: { $0.id == pin }) {
            model.select(actor)
        }
        return model
    }

    /// Drives the pill through the same running → review path the app uses, so
    /// the render shows what a live finish produces rather than a mock.
    static func noticeModel() -> PetViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aimate-notice-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ActorStore(directory: directory)
        let running = Actor(id: "snap:qoder", source: "qoder", state: .running,
                            title: "修复登录卡顿", ttl: 900)
        store.publish(running)
        let model = PetViewModel(store: store, adapters: [], settings: PetSettings.load())
        model.reloadPets()
        model.refresh()
        var finished = running
        finished.state = .review
        finished.detail = "用时 1 分 5 秒"
        finished.updatedAt = Date()
        store.publish(finished)
        model.refresh()
        model.cardBelow = ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT_PET_BELOW"] != nil
        // Opening the card is what ends the notice; this mode renders that
        // hand-over, pill gone and card in the same slot.
        if ProcessInfo.processInfo.environment["AIMATE_SNAPSHOT_PET_CARD"] != nil {
            model.isExpanded = true
        }
        return model
    }

    private static func fixture() -> PetViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aimate-snapshot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ActorStore(directory: directory)
        for actor in [
            Actor(id: "snap:qoder", source: "qoder", state: .waiting,
                  title: "重构桌宠的悬浮任务卡，让它在四个 agent 同时在场时也读得清楚",
                  detail: "正在调用 Bash：swift build --target AimateCore，已经跑了 1 分 42 秒"),
            Actor(id: "snap:oc", source: "opencode", state: .failed, title: "会话中断"),
            Actor(id: "snap:dsh", source: "dsh", state: .review, title: "等待审阅"),
            Actor(id: "snap:cx", source: "codex", state: .running, title: "生成中"),
            Actor(id: "snap:cx2", source: "codex", state: .running, title: "第二个会话"),
            Actor(id: "snap:mine", source: "mine", state: .running, title: "自建通道"),
            Actor(id: "snap:qd2", source: "qoder", state: .running, title: "另一个会话"),
            Actor(id: "snap:dsh2", source: "dsh", state: .running, title: "第二个会话"),
            // Published last so it wins the recency tie-break and the render shows
            // the ask on top of a full roster. These are OpenCode's real labels:
            // the widest row the pet has to draw.
            Actor(id: "snap:ask", source: "opencode", state: .waiting,
                  title: "允许编辑 /Users/me/Projects/aimate/Sources/AimateCore/ActorStore.swift 吗？",
                  detail: "edit · 写入 12 行",
                  options: OpenCodePermission.options),
        ] { store.publish(actor) }
        return PetViewModel(store: store, adapters: [], settings: PetSettings.load())
    }

    static func write(to url: URL, model: PetViewModel) {
        // The window is bottom-aligned and never resizes, so clipping the render the
        // same way is what shows whether the card actually fits its envelope.
        let content = TaskCardView(model: model)
            .frame(width: model.cardWidth, height: PetViewModel.cardMaxHeight, alignment: .bottom)
            .clipped()
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("AIMATE_SNAPSHOT: render failed\n".utf8))
            return
        }
        try? png.write(to: url)
    }

    static func writePet(to url: URL, model: PetViewModel) {
        // A mid-dark plate rather than transparency: the pill is glass, and the
        // edge of the pet is what shows whether it sits where the slot is.
        let content = PetRootView(model: model)
            .frame(width: model.envelopeSize.width, height: model.envelopeSize.height)
            .background(Color(red: 0.16, green: 0.18, blue: 0.21))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("AIMATE_SNAPSHOT_PET: render failed\n".utf8))
            return
        }
        try? png.write(to: url)
    }
}
