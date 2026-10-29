import AimateCore
import AppKit
import SwiftUI

/// Borderless floating panel. It stays click-through unless the pointer is over
/// the pet or an open card, which is what lets it sit on top of real work.
final class PetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        title = "AINEMATE Pet"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit's default pins the window's top edge under the menu bar. The pet
    /// sits on the window's *bottom* edge when its card is above, so that default
    /// stopped the sprite the card's height short of the top and made the drag
    /// feel stuck. The sprite is what the user drags, so placement is worked out
    /// against the sprite instead (`PetWindowController.placeSprite`).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Transparent capture layer above the SwiftUI content. The panel never becomes
/// key, so button events are handled here rather than through the responder chain.
final class PetEventLayer: NSView {
    var onPress: (@MainActor (NSEvent, Bool) -> Void)?
    var onDrag: (@MainActor (NSEvent) -> Void)?
    var onRelease: (@MainActor () -> Void)?
    var onMenu: (@MainActor (NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the layer invisible to clicks outside the pet's own box.
        isPointInPetBox(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onPress?(event, isPointInPetBox(event.locationInWindow)) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onRelease?() }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    private var petBoxProvider: (@MainActor () -> NSRect)?
    func setPetBox(_ provider: @escaping @MainActor () -> NSRect) { petBoxProvider = provider }

    private func isPointInPetBox(_ pointInWindow: NSPoint) -> Bool {
        petBoxProvider?().contains(pointInWindow) ?? true
    }
}

@MainActor
final class PetWindowController: NSObject {
    private(set) var panel: PetPanel!
    private let model: PetViewModel
    private let hosting: NSHostingView<AnyView>
    private let eventLayer = PetEventLayer()

    private var pointerTimer: Timer?
    private var isDragging = false
    private var dragCursorOrigin: CGPoint = .zero
    private var lastDragPoint: CGPoint = .zero
    private var dragSpriteOrigin: CGPoint = .zero
    private var acceptsPointer = false

    /// Extra reach around the sprite so the hover target matches what is drawn:
    /// the atlas cell has transparent padding the eye does not count.
    private let hoverPadding: CGFloat = 12

    init(model: PetViewModel) {
        self.model = model
        self.hosting = NSHostingView(rootView: AnyView(PetRootView(model: model)))
        super.init()

        panel = PetPanel(contentRect: NSRect(origin: .zero, size: model.envelopeSize))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        eventLayer.autoresizingMask = [.width, .height]

        panel.contentView?.addSubview(hosting)
        panel.contentView?.addSubview(eventLayer)
        panel.isExcludedFromWindowsMenu = true
        // NSHostingView starts at zero size, and a borderless panel never lays its
        // content out on its own, so pin the overlays to the content bounds.
        syncFrames()

        eventLayer.setPetBox { [weak self] in self?.petRectInWindow() ?? .zero }
        eventLayer.onPress = { [weak self] _, insidePet in
            guard let self, insidePet else { return }
            self.beginDrag()
        }
        eventLayer.onDrag = { [weak self] _ in self?.continueDrag() }
        eventLayer.onRelease = { [weak self] in self?.endDrag() }
        eventLayer.onMenu = { [weak self] event in self?.presentMenu(for: event) }
    }

    func show() {
        positionOnLaunch()
        panel.orderFrontRegardless()
        startPointerPolling()
    }

    // MARK: - Geometry

    /// The sprite is centred horizontally and owns the window edge the card does
    /// not. The card's slot is the rest of the envelope.
    private var sidePadding: CGFloat { (panel.frame.width - model.mascotWidth) / 2 }

    /// Bottom-left corner of the sprite in screen coordinates. This is the point
    /// that is dragged, so it is also what placement and the saved anchor use.
    private var spriteOrigin: CGPoint {
        CGPoint(x: panel.frame.origin.x + sidePadding,
                y: panel.frame.origin.y + model.cardInset)
    }

    private func petRectInWindow() -> NSRect {
        NSRect(
            x: sidePadding,
            y: model.cardInset,
            width: model.mascotWidth,
            height: model.spriteHeight)
    }

    private func cardRectInWindow() -> NSRect {
        NSRect(
            x: 0,
            y: model.cardBelow ? 0 : model.spriteHeight,
            width: panel.frame.width,
            height: PetViewModel.cardSlot)
    }

    private func petRectOnScreen() -> NSRect {
        panel.convertToScreen(petRectInWindow())
    }

    // MARK: - Placement

    private func positionOnLaunch() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        /// Parking the pet half off-screen, behind the Dock or across a display
        /// seam is something people do on purpose, so a saved anchor only loses
        /// when the sprite — the part that can be grabbed — is off every screen,
        /// which is what a disconnected display leaves behind.
        func reachable(_ origin: CGPoint) -> Bool {
            let area = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            return area.contains(Placement.spriteRect(
                windowOrigin: origin,
                windowSize: size,
                spriteSize: CGSize(width: model.mascotWidth, height: model.spriteHeight)))
        }
        var origin = model.savedAnchor ?? defaultAnchor(in: screen, size: size)
        if !reachable(origin) {
            origin = defaultAnchor(in: screen, size: size)
        }
        // The anchor is stored in the card-above frame, where the sprite sits on
        // the window's bottom edge; the side itself is decided from where it lands.
        model.cardBelow = false
        placeSprite(at: CGPoint(x: origin.x + sidePadding, y: origin.y))
    }

    /// Put the sprite's bottom-left corner on a point, moving the window around
    /// it and picking the side with room for the card. Only the window moves, so
    /// flipping sides mid-drag never shifts the pet out from under the cursor.
    private func placeSprite(at point: CGPoint) {
        let sprite = CGRect(
            origin: point,
            size: CGSize(width: model.mascotWidth, height: model.spriteHeight))
        let centre = CGPoint(x: sprite.midX, y: sprite.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            model.cardBelow = Placement.cardOpensBelow(
                sprite: sprite, in: area,
                cardHeight: PetViewModel.cardMaxHeight,
                spacing: PetViewModel.cardSpacing,
                currentlyBelow: model.cardBelow)
        }
        panel.setFrameOrigin(Placement.windowOrigin(
            forSpriteAt: point,
            windowSize: panel.frame.size,
            spriteSize: sprite.size,
            cardInset: model.cardInset))
    }

    /// Place the sprite itself, not the wider envelope, a fixed distance from the
    /// corner; the card space above it stays off-screen-neutral.
    private func defaultAnchor(in screen: NSScreen, size: NSSize) -> CGPoint {
        let sidePadding = (size.width - model.mascotWidth) / 2
        return Placement.clamp(
            CGPoint(x: screen.visibleFrame.maxX - size.width + sidePadding - 40,
                    y: screen.visibleFrame.minY + 32),
            size: size, in: screen.visibleFrame)
    }

    // MARK: - Pointer tracking

    /// `NSEvent.mouseLocation` needs no Accessibility grant, unlike a global
    /// `.mouseMoved` monitor, so the hover gate works on a fresh machine.
    private func startPointerPolling() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        trackPointer()
    }

    private func trackPointer() {
        guard !isDragging else { return }
        let point = NSEvent.mouseLocation
        let pet = petRectOnScreen().insetBy(dx: -hoverPadding, dy: -hoverPadding)
        var over = pet.contains(point)
        if !over && model.isExpanded {
            over = panel.convertToScreen(cardRectInWindow()).contains(point)
        }

        if over != acceptsPointer {
            acceptsPointer = over
            panel.ignoresMouseEvents = !over
        }
        let wantCard = model.settings.showCardOnHover && over
        if wantCard != model.isExpanded {
            model.isExpanded = wantCard
        }

        // The original only forwards a cursor point inside the overlay's bounds;
        // ours reaches further out, and yields while the cursor is on the body —
        // a pet staring at the pointer resting on its head looks wrong. The open
        // card counts as body too: the eye follows on the way over, then settles
        // back on the state loop while the pointer is reading the card.
        let sprite = petRectOnScreen()
        let card = model.isExpanded ? panel.convertToScreen(cardRectInWindow()) : nil
        guard Placement.gazeFollows(sprite: sprite, card: card, pointer: point) else {
            model.clearGaze()
            return
        }
        let dx = point.x - sprite.midX
        let dy = point.y - sprite.midY
        model.updateGaze(pointerDX: dx, pointerDY: dy, distance: hypot(dx, dy))
    }

    /// Resize around the sprite's bottom edge so the pet never appears to jump.
    private func applyEnvelopeSize() {
        let size = model.envelopeSize
        guard size != panel.frame.size else { return }
        // The sprite is centred, so its bottom-centre is the point to hold; the
        // window's own corners move freely around it.
        let spriteBottom = CGPoint(x: panel.frame.midX - model.mascotWidth / 2,
                                   y: panel.frame.minY + model.cardInset)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
        syncFrames()
        placeSprite(at: spriteBottom)
    }

    private func syncFrames() {
        guard let bounds = panel.contentView?.bounds else { return }
        hosting.frame = bounds
        eventLayer.frame = bounds
    }

    // MARK: - Drag

    private func beginDrag() {
        isDragging = true
        dragCursorOrigin = NSEvent.mouseLocation
        lastDragPoint = dragCursorOrigin
        dragSpriteOrigin = spriteOrigin
        model.dragDX = 0
        // Dragging suppresses the look frame in the original, so the state loop
        // plays while the pet is being moved.
        model.clearGaze()
    }

    private func continueDrag() {
        guard isDragging else { return }
        let point = NSEvent.mouseLocation
        // The sprite is pinned to the cursor; the window grows and shrinks on the
        // other side when the card flips, so it is not the thing to track.
        placeSprite(at: CGPoint(
            x: dragSpriteOrigin.x + point.x - dragCursorOrigin.x,
            y: dragSpriteOrigin.y + point.y - dragCursorOrigin.y))
        // The runtime samples the step since the previous move, not the travel
        // since mouse-down: that is what lets a carried pet turn around mid-drag.
        let stepX = point.x - lastDragPoint.x
        lastDragPoint = point
        guard abs(stepX) >= 4 else { return }
        model.dragDX = stepX
        model.applyStateToPlayer()
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        model.dragDX = 0
        model.applyStateToPlayer()
        // Dropped fully past every edge there is nothing left to grab and nothing
        // to hover, so the pet comes back to the nearest screen instead of
        // becoming unreachable until the next launch.
        if !NSScreen.screens.contains(where: { $0.frame.intersects(petRectOnScreen()) }) {
            let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
            if let screen {
                placeSprite(at: Placement.clamp(
                    spriteOrigin,
                    size: CGSize(width: model.mascotWidth, height: model.spriteHeight),
                    in: screen.visibleFrame))
            }
        }
        // Stored in the card-above frame the anchor has always used, so the
        // sprite relaunches exactly where it was let go, card side and all.
        model.setAnchor(CGPoint(x: spriteOrigin.x - sidePadding, y: spriteOrigin.y))
    }

    // MARK: - Menu

    private func presentMenu(for event: NSEvent) {
        // Rescanning here is what lets a pet copied into either folder show up
        // on the next right-click instead of after a relaunch.
        model.reloadPets()
        let menu = NSMenu()
        addItem(to: menu, title: "宠物", action: nil)
        for pet in model.pets {
            let item = NSMenuItem(title: pet.displayName, action: #selector(choosePet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pet.id
            item.state = pet.id == model.currentPet?.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "打开宠物文件夹", action: #selector(openPetsFolder))
        addItem(to: menu, title: "重新扫描宠物", action: #selector(rescanPets))
        menu.addItem(.separator())
        addItem(to: menu, title: "缩小", action: #selector(scalePet(_:)), tag: -16)
        addItem(to: menu, title: "放大", action: #selector(scalePet(_:)), tag: 16)
        let sizeItem = NSMenuItem()
        sizeItem.view = sizeSliderRow()
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        let motion = NSMenuItem(title: "减少动效", action: #selector(toggleReduceMotion), keyEquivalent: "")
        motion.target = self
        motion.state = model.settings.reduceMotion ? .on : .off
        menu.addItem(motion)
        addItem(to: menu, title: "立即刷新", action: #selector(refreshNow))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        menu.popUp(positioning: nil, at: event.locationInWindow, in: panel.contentView)
    }

    /// A menu row whose content is a slider, so the size can be dragged instead
    /// of stepped. The window resizes live with it; the value is only written to
    /// disk once, when the menu closes.
    private func sizeSliderRow() -> NSView {
        let width: CGFloat = 208
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))

        let title = NSTextField(labelWithString: "大小")
        title.frame = NSRect(x: 2, y: 4, width: 32, height: 18)

        let slider = NSSlider(
            value: Double(model.mascotWidth),
            minValue: Double(AtlasLayout.minMascotWidth),
            maxValue: Double(AtlasLayout.maxMascotWidth),
            target: self, action: #selector(sizeSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 38, y: 2, width: width - 38 - 46, height: 22)
        slider.setAccessibilityLabel("桌宠大小")

        let value = NSTextField(labelWithString: "\(Int(model.mascotWidth))")
        value.tag = Self.sizeValueTag
        value.alignment = .right
        value.frame = NSRect(x: width - 44, y: 4, width: 42, height: 18)

        row.addSubview(title)
        row.addSubview(slider)
        row.addSubview(value)
        return row
    }

    private static let sizeValueTag = 1

    @objc private func sizeSliderChanged(_ sender: NSSlider) {
        model.setMascotWidth(CGFloat(sender.doubleValue), persist: false)
        // The label follows the knob so the point size is readable mid-drag.
        (sender.superview?.viewWithTag(Self.sizeValueTag) as? NSTextField)?
            .stringValue = "\(Int(model.mascotWidth))"
        applyEnvelopeSize()
    }

    @objc private func choosePet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.selectPet(id)
        applyEnvelopeSize()
    }

    /// Lands in the folder the next pet should be dropped into, created first so
    /// the window never opens on a missing path.
    @objc private func openPetsFolder() {
        AimatePaths.ensureDirectories()
        NSWorkspace.shared.open(AimatePaths.petsDir)
    }

    /// The menu's own rescan skips a pet that is still installed, so this is the
    /// one path that picks up a spritesheet replaced under the same id.
    @objc private func rescanPets() {
        model.reloadPets(force: true)
    }

    @objc private func scalePet(_ sender: NSMenuItem) {
        model.setMascotWidth(model.mascotWidth + CGFloat(sender.tag))
        applyEnvelopeSize()
    }

    @objc private func toggleReduceMotion() {
        model.setReduceMotion(!model.settings.reduceMotion)
    }

    @objc private func refreshNow() {
        model.discoverNow()
    }
}

private extension PetWindowController {
    func addItem(to menu: NSMenu, title: String, action: Selector?, tag: Int = 0) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.tag = tag
        menu.addItem(item)
    }
}

extension PetWindowController: NSMenuDelegate {
    /// A slider drag fires on every point but must cost one settings write, so
    /// the live value is saved when the menu goes away.
    func menuDidClose(_ menu: NSMenu) {
        model.persistSettings()
    }
}
