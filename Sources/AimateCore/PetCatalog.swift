import Foundation

/// A pet package found on disk. Layout follows the Codex custom-pet contract:
/// `pets/<id>/pet.json` + `spritesheet.webp`, with two conveniences accepted
/// too — a directory holding one image, and a loose `name.webp`.
public struct PetPackage: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let spriteVersion: Int
    public let sheetURL: URL

    public static func == (lhs: PetPackage, rhs: PetPackage) -> Bool { lhs.id == rhs.id }
}

struct PetManifest: Decodable {
    let id: String?
    let displayName: String?
    let description: String?
    let spriteVersionNumber: Int?
    let spritesheetPath: String?
}

public enum PetCatalog {
    /// Bundle resources last: the OpenAI atlases are dev fixtures and are never
    /// shipped inside a release artifact.
    public static func searchDirectories(devOverride: String? =
        ProcessInfo.processInfo.environment["AIMATE_DEV_PETS_DIR"]) -> [URL] {
        var dirs = [AimatePaths.petsDir, AimatePaths.codexPetsDir]
        if let devOverride {
            dirs.insert(URL(fileURLWithPath: devOverride, isDirectory: true), at: 0)
        }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func load() -> [PetPackage] {
        var found: [PetPackage] = []
        var seen = Set<String>()
        for dir in searchDirectories() {
            for pet in load(from: dir) where seen.insert(pet.id).inserted { found.append(pet) }
        }
        return found
    }

    static func load(from directory: URL) -> [PetPackage] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var pets: [PetPackage] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if isImage(entry) {
                if let loose = packageForLooseFile(entry) { pets.append(loose) }
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let packaged = packageForDirectory(entry) { pets.append(packaged) }
        }
        return pets
    }

    private static func packageForDirectory(_ url: URL) -> PetPackage? {
        let manifestURL = url.appendingPathComponent("pet.json")
        if let data = fm_contents(at: manifestURL),
           let manifest = try? JSONDecoder().decode(PetManifest.self, from: data) {
            let sheetName = manifest.spritesheetPath ?? "spritesheet.webp"
            let sheet = url.appendingPathComponent(sheetName)
            guard isImage(sheet) else { return nil }
            let id = manifest.id ?? url.lastPathComponent
            return PetPackage(
                id: id,
                displayName: manifest.displayName ?? id,
                description: manifest.description,
                spriteVersion: manifest.spriteVersionNumber ?? 1,
                sheetURL: sheet)
        }
        // No manifest: take the first image in the directory.
        guard let images = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        guard let sheet = images.sorted(by: { $0.path < $1.path }).first(where: isImage) else { return nil }
        return PetPackage(
            id: url.lastPathComponent,
            displayName: url.lastPathComponent,
            description: nil,
            spriteVersion: 2,
            sheetURL: sheet)
    }

    private static func packageForLooseFile(_ url: URL) -> PetPackage? {
        guard isImage(url) else { return nil }
        // `codex-spritesheet-v6.webp` -> `codex`; `-spritesheet-vN` is the dev
        // fixture naming that keeps nine atlases apart in one flat directory.
        let stem = url.deletingPathExtension().lastPathComponent
        let name = stem.components(separatedBy: "-spritesheet").first ?? stem
        return PetPackage(
            id: name,
            displayName: name,
            description: nil,
            spriteVersion: 2,
            sheetURL: url)
    }

    private static func fm_contents(at url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    public static func isImage(_ url: URL) -> Bool {
        ["webp", "png"].contains(url.pathExtension.lowercased())
    }
}
