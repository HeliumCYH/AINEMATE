import AimateCore
import AppKit
import Combine

@MainActor
final class PetViewModel: ObservableObject {
    @Published private(set) var snapshot = ActorSnapshot.empty
    /// The card's rows: start order, with finished sessions floated to the top.
    /// It is separate from `snapshot.actors`, which stays urgency-sorted for the
    /// pet's own pose.
    @Published private(set) var orderedActors: [Actor] = []
    @Published private(set) var pets: [PetPackage] = []
    @Published private(set) var currentPet: PetPackage?
    @Published var settings: PetSettings
    @Published var isExpanded = false {
        didSet {
            if isExpanded {
                // The card covers the slot the pill lives in, and opening it is
                // itself the "I looked" the notice was waiting for.
                if completion != nil {
                    endCompletion()
                    applyStateToPlayer()
                }
                // Freeze the automatic pick when the card opens: with several
                // agents reporting every tick the most-recently-updated one
                // changes every second, and the bubble would slide between rows.
                if selectedActorID == nil { selectedActorID = snapshot.dominant?.id }
            } else {
                // Closing the card returns the bubble to the automatic pick.
                selectedActorID = nil
            }
        }
    }
    /// Set by tapping a row, or seeded from the dominant actor when the card
    /// opens: the bubble expands at that row and the rows keep their order. The
    /// pet's own state still follows the aggregation.
    @Published private(set) var selectedActorID: String?
    /// Which side of the pet the card opens on. A pet at the top of the screen
    /// has no room above it, so the card drops below; the rows inside keep their
    /// order either way.
    @Published var cardBelow = false
    @Published var dragDX: CGFloat = 0
    @Published private(set) var lastError: String?
    /// The "完成 N 项" pill over the pet. Non-nil for the length of the notice;
    /// the count grows if another session finishes inside that window.
    @Published private(set) var completion: CompletionNotice?

    let player = SpritePlayer()
    private var roster = SessionRoster()
    private var completionWatch = CompletionWatch()
    private var completionTimer: Timer?
    private let store: ActorStore
    private let engine: DiscoveryEngine
    private var eventStream: DirectoryEventStream?
    private var expiryTimer: Timer?
    private let bridge = BridgeSupervisor()

    init(store: ActorStore = ActorStore(),
         adapters: [AgentAdapter] = [
             QoderAdapter(), CodexAdapter(), DeepSeekHarnessAdapter(), OpenCodeAdapter(),
         ],
         settings: PetSettings? = nil) {
        self.store = store
        self.engine = DiscoveryEngine(store: store, adapters: adapters)
        self.settings = settings ?? PetSettings.load()
    }

    var dominant: Actor? { snapshot.dominant }

    /// The actor the card speaks for: the selected one while it is still live,
    /// otherwise the aggregation's choice.
    var displayedActor: Actor? {
        guard let selectedActorID else { return snapshot.dominant }
        return snapshot.actors.first { $0.id == selectedActorID } ?? snapshot.dominant
    }

    func select(_ actor: Actor) {
        selectedActorID = actor.id
    }

    func start() {
        AimatePaths.ensureDirectories()
        player.reduceMotion = settings.reduceMotion
        reloadPets()
        eventStream = DirectoryEventStream { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        eventStream?.start(directory: store.watchDirectory)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
        engine.start()
        // OpenCode keeps its pending asks inside its own server, so the pet has
        // to keep a poller alive while it is on screen.
        bridge.start()
        refresh()
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        completionTimer?.invalidate()
        completionTimer = nil
        bridge.stop()
        eventStream?.stop()
        engine.stop()
    }

    /// Menu-triggered re-observation, independent of the timer cadence.
    func discoverNow() {
        engine.tick()
        refresh()
    }

    func refresh(now: Date = Date()) {
        store.markAlive(now: now)
        snapshot = store.snapshot(now: now)
        let finished = completionWatch.observe(snapshot.actors)
        orderedActors = roster.arrange(snapshot.actors)
        if let selectedActorID, !snapshot.actors.contains(where: { $0.id == selectedActorID }) {
            self.selectedActorID = nil
        }
        // A new ask outranks the frozen bubble: its buttons are the only way to
        // unblock the sender, and a row collapsed by a tap cannot answer.
        if let ask = snapshot.actors.first(where: { !($0.options ?? []).isEmpty }),
           ask.id != selectedActorID,
           snapshot.actors.first(where: { $0.id == selectedActorID })?
               .options?.isEmpty != false {
            selectedActorID = ask.id
        }
        if !finished.isEmpty { announce(finished, now: now) }
        // A question or a failure outranks the celebration: both are the thing
        // the user has to act on, and the jump would pull the eye off them.
        if completion != nil, let dominant = snapshot.dominant,
           dominant.state == .waiting || dominant.state == .failed {
            endCompletion()
        }
        applyStateToPlayer()
    }

    // MARK: - Completion notice

    /// The pill is the only time the pet plays a gesture instead of its state
    /// loop, so it is kept short and its end is what hands the pet back to
    /// whatever is actually still running.
    static let completionDuration: TimeInterval = 3

    private func announce(_ finished: [Actor], now: Date) {
        guard !isExpanded,
              let dominant = snapshot.dominant,
              dominant.state != .waiting, dominant.state != .failed else { return }
        completion = CompletionNotice.starting(
            finished: finished, now: now,
            duration: Self.completionDuration, extending: completion)
        scheduleCompletionEnd()
        clearGaze()
    }

    private func scheduleCompletionEnd() {
        completionTimer?.invalidate()
        let timer = Timer(timeInterval: Self.completionDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.endCompletion()
                self.applyStateToPlayer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    private func endCompletion() {
        completionTimer?.invalidate()
        completionTimer = nil
        completion = nil
    }

    // MARK: - Answers

    /// The click is only a write: the sender owns what happens next, so a hook
    /// blocked on `pet-cli reply` picks it up and the card follows the actor file.
    func answer(_ actor: Actor, _ option: String) {
        store.record(ActorReply(actorId: actor.id, option: option))
        refresh()
    }

    func reply(for actor: Actor) -> ActorReply? { store.reply(for: actor) }

    /// The user's own "I have seen it": a finished row leaves the card at once
    /// instead of waiting out the review ttl.
    func acknowledge(_ actor: Actor) {
        store.acknowledge(actor)
        refresh()
    }

    // MARK: - Pet art

    /// `force` re-reads the current sheet too, for when the art was replaced in
    /// place under the same id. Otherwise a pet that is still installed keeps
    /// playing: rebuilding the catalog must not restart its animation.
    func reloadPets(force: Bool = false) {
        pets = PetCatalog.load()
        if !force, let current = currentPet, pets.contains(where: { $0.id == current.id }) { return }
        selectPet(settings.petID ?? pets.first?.id)
    }

    /// Only a sheet that actually decodes may become the saved pick: a petID that
    /// points at a v1 atlas used to persist, so every later launch came up blank.
    func selectPet(_ id: String?) {
        let wanted = id.flatMap { want in pets.first { $0.id == want } }
        var order = pets
        if let wanted, let index = pets.firstIndex(where: { $0.id == wanted.id }) {
            order.remove(at: index)
            order.insert(wanted, at: 0)
        }
        var failure: String?
        var loaded = false
        for pet in order {
            do {
                player.load(try SpriteSheet(url: pet.sheetURL))
                currentPet = pet
                settings.petID = pet.id
                lastError = pet.id == wanted?.id ? nil : failure
                loaded = true
                break
            } catch {
                failure = error.localizedDescription
            }
        }
        if !loaded { lastError = failure ?? "没有找到可用的宠物包" }
        persistSettings()
        applyStateToPlayer(force: true)
    }

    // MARK: - Rendering

    func applyStateToPlayer(force: Bool = false) {
        let state = snapshot.dominant?.state ?? .idle
        let carried = dragDX >= 4 || dragDX <= -4
        // While the pill is up the pet keeps jumping, which is also what keeps
        // it out of idle when the finished session is all there was. Carrying
        // the pet and a state that needs the user still win; with reduced motion
        // the pose stays on the state and the pill carries the news alone.
        let celebrating = completion != nil && !carried && !settings.reduceMotion
            && state != .waiting && state != .failed
        let animation = celebrating ? .jumping : state.atlasRow(dragDX: dragDX)
        if force { player.restart() } else { player.setAnimation(animation) }
        player.setPaused(false)
    }

    /// The shipped renderer paints a look frame and returns without ever starting
    /// the state loop, so a live pointer outranks the status animation. The reach
    /// is ours rather than the original's 1px window rule: the pet should notice
    /// the cursor well before it arrives.
    func updateGaze(pointerDX: CGFloat, pointerDY: CGFloat, distance: CGFloat) {
        // A look frame would freeze the completion jump on one pose; the notice
        // is the pet's own beat, so the eye sits it out.
        guard completion == nil else {
            clearGaze()
            return
        }
        guard distance > Self.gazeDeadzone, distance <= gazeReach else {
            clearGaze()
            return
        }
        player.setGaze(AtlasLayout.lookIndex(pointerDX: pointerDX, pointerDY: pointerDY))
    }

    func clearGaze() { player.setGaze(nil) }

    // MARK: - Settings

    /// `persist: false` is for a live control that fires on every step of a drag;
    /// the caller saves once when the interaction ends, not once per point.
    func setMascotWidth(_ value: CGFloat, persist: Bool = true) {
        settings.mascotWidth = Double(AtlasLayout.mascotWidthPx(value))
        if persist { persistSettings() }
    }

    var mascotWidth: CGFloat {
        AtlasLayout.mascotWidthPx(CGFloat(settings.mascotWidth))
    }

    // MARK: - Layout

    /// Gap between the card and the sprite.
    static let cardSpacing: CGFloat = 6

    /// The panel is sized once for the largest card and never grows when the
    /// card opens; `NSHostingView.fittingSize` lags a frame behind `isExpanded`,
    /// which showed up as a clipped card. The height is the worst case the card
    /// can now build: one expanded row (title, detail, answer buttons) plus
    /// `TaskCardView.shortRows` rows around it.
    static let cardMaxHeight: CGFloat = 176

    /// `E = 1` in the shipped look-frame helper: a pointer anywhere but exactly on
    /// the sprite centre produces a pose.
    static let gazeDeadzone: CGFloat = 1

    /// How far the pet keeps watching the cursor, measured from the sprite centre.
    var gazeReach: CGFloat { mascotWidth * 2.25 }

    var spriteHeight: CGFloat {
        mascotWidth / CGFloat(AtlasLayout.aspectRatio)
    }

    var cardWidth: CGFloat {
        max(mascotWidth + 96, 232)
    }

    var envelopeSize: NSSize {
        NSSize(
            width: cardWidth,
            height: spriteHeight + Self.cardSpacing + Self.cardMaxHeight)
    }

    /// Height of the card's reserved slot, measured from the window edge it is
    /// on. The sprite sits on the opposite edge, so this is also the sprite's
    /// distance from the window's bottom.
    static let cardSlot = cardMaxHeight + cardSpacing

    var cardInset: CGFloat { cardBelow ? Self.cardSlot : 0 }

    func setReduceMotion(_ value: Bool) {
        settings.reduceMotion = value
        player.reduceMotion = value
        persistSettings()
    }

    /// The anchor is stored in the frame it always used: the window origin with
    /// the card slot above the sprite. Keeping that convention means a relaunch
    /// lands the sprite where the user let go, whichever side the card was on.
    func setAnchor(_ point: CGPoint) {
        settings.anchorX = Double(point.x)
        settings.anchorY = Double(point.y)
        persistSettings()
    }

    var savedAnchor: CGPoint? {
        guard let x = settings.anchorX, let y = settings.anchorY else { return nil }
        return CGPoint(x: x, y: y)
    }

    func persistSettings() {
        settings.save()
    }
}
