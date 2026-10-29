import Foundation

/// Appends-only reader for a log the agent is still writing.
public final class JSONLTailer {
    private struct Cursor { var offset: UInt64; var inode: ino_t }
    private var cursors: [String: Cursor] = [:]

    /// Whole lines appended since the previous call. The cursor stops after the
    /// last newline, so a half-written record is read again once the sender
    /// finishes it instead of being lost. A replaced or truncated file restarts
    /// from zero, which keeps rotated segments in order.
    public func readLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let inode = Self.inode(of: url)

        var offset: UInt64 = 0
        if let existing = cursors[url.path], existing.inode == inode, existing.offset <= size {
            offset = existing.offset
        }
        if offset > 0 { try? handle.seek(toOffset: offset) }

        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(0x0A)) else { return nil }
        let complete = data[...lastNewline]
        cursors[url.path] = Cursor(offset: offset + UInt64(complete.count), inode: inode)

        guard let text = String(data: complete, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return lines.isEmpty ? nil : lines
    }

    public func forget(_ url: URL) { cursors.removeValue(forKey: url.path) }

    private static func inode(of url: URL) -> ino_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return info.st_ino
    }
}
