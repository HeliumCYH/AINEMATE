import AimateCore
import CoreGraphics
import Foundation
import ImageIO

/// Decodes a v2 atlas once and hands out 192x208 cells. Per-frame decoding of a
/// 1536x2288 WebP would dominate the frame budget, so cells are cached.
final class SpriteSheet {
    let image: CGImage
    let pixelSize: CGSize
    let columns: Int
    let rows: Int

    private var cache: [Int: CGImage] = [:]

    enum LoadError: LocalizedError {
        case unreadable(URL)
        case notV2(URL, CGSize)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "无法读取精灵图 \(url.lastPathComponent)"
            case .notV2(let url, let size):
                return "\(url.lastPathComponent) 不是 v2 atlas（实测 \(Int(size.width))x\(Int(size.height))，应为 1536x2288）"
            }
        }
    }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LoadError.unreadable(url)
        }
        let size = CGSize(width: cg.width, height: cg.height)
        // Height is the discriminator: v1 is 8 rows (1872), v2 is 11 rows (2288).
        guard size.width == CGFloat(AtlasLayout.widthPx),
              size.height == CGFloat(AtlasLayout.heightPx) else {
            throw LoadError.notV2(url, size)
        }
        self.image = cg
        self.pixelSize = size
        self.columns = AtlasLayout.columns
        self.rows = AtlasLayout.rows
    }

    func cell(row: Int, column: Int) -> CGImage {
        let key = row * columns + column
        if let hit = cache[key] { return hit }
        let rect = AtlasLayout.cellRect(
            row: row, column: column, atlasSize: pixelSize)
        let cropped = image.cropping(to: rect) ?? image
        cache[key] = cropped
        return cropped
    }

    func cell(index: Int) -> CGImage {
        cell(row: index / columns, column: index % columns)
    }
}
