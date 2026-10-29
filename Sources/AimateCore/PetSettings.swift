import Foundation

/// User choices that survive relaunch: which pet, how big, where it sits.
public struct PetSettings: Codable, Equatable, Sendable {
    public var petID: String?
    /// Points, not pixels — `mascotWidthPx` is clamped before use.
    public var mascotWidth: Double
    /// Bottom-left corner in screen coordinates, flipped so a display change
    /// does not bury the pet off-screen.
    public var anchorX: Double?
    public var anchorY: Double?
    public var reduceMotion: Bool
    public var showCardOnHover: Bool

    public init(
        petID: String? = nil,
        mascotWidth: Double = 128,
        anchorX: Double? = nil,
        anchorY: Double? = nil,
        reduceMotion: Bool = false,
        showCardOnHover: Bool = true
    ) {
        self.petID = petID
        self.mascotWidth = mascotWidth
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.reduceMotion = reduceMotion
        self.showCardOnHover = showCardOnHover
    }

    public static func load(from url: URL = AimatePaths.settingsFile) -> PetSettings {
        guard let data = FileManager.default.contents(atPath: url.path),
              let decoded = try? JSONDecoder().decode(PetSettings.self, from: data) else {
            return PetSettings()
        }
        return decoded
    }

    public func save(to url: URL = AimatePaths.settingsFile) {
        AimatePaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
