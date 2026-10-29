#!/usr/bin/env swift
// Assembles a Codex v2 sprite atlas (1536x2288, 8x11 cells of 192x208) from
// per-frame images laid out by row.
//
//   swift build_atlas.swift <frames-dir> <out.png>
//
// frames-dir/<row>/<col>.png — row 0..10, col 0..7. Missing cells stay fully
// transparent. Cell-sized frames land pixel-exact; smaller frames are centred
// at their own aspect ratio, never stretched.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let columns = 8
let rows = 11
let cellW = 192
let cellH = 208
let canvasW = columns * cellW
let canvasH = rows * cellH

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    fail("""
        usage: swift build_atlas.swift <frames-dir> <out.png>
          frames-dir/<row>/<col>.(png|webp|jpg)  row 0..10, col 0..7
        """)
}
let framesDir = URL(fileURLWithPath: args[0], isDirectory: true)
let outURL = URL(fileURLWithPath: args[1])

var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: framesDir.path, isDirectory: &isDir), isDir.boolValue else {
    fail("frames dir not found: \(framesDir.path)")
}

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("cannot create \(canvasW)x\(canvasH) bitmap")
}
// A bitmap context stores its first row at the top of the saved image while its
// coordinates grow upward, so cells are placed from the bottom and the frames
// are never mirrored.
ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
ctx.interpolationQuality = .high

let extensions: Set<String> = ["png", "webp", "jpg", "jpeg"]
var drawn = 0
var missing: [String] = []

for row in 0..<rows {
    let rowDir = framesDir.appendingPathComponent("\(row)", isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(
        at: rowDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    for column in 0..<columns {
        let name = "\(column)"
        guard let url = files.first(where: {
            $0.deletingPathExtension().lastPathComponent == name
                && extensions.contains($0.pathExtension.lowercased())
        }),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            missing.append("\(row)/\(column)")
            continue
        }
        let scale = min(Double(cellW) / Double(image.width), Double(cellH) / Double(image.height))
        let w = Double(image.width) * scale
        let h = Double(image.height) * scale
        let rect = CGRect(
            x: Double(column * cellW) + (Double(cellW) - w) / 2,
            y: Double(canvasH) - Double((row + 1) * cellH) + (Double(cellH) - h) / 2,
            width: w, height: h)
        ctx.draw(image, in: rect)
        drawn += 1
    }
}

guard let sheet = ctx.makeImage() else { fail("cannot render atlas") }
try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot write \(outURL.path)")
}
CGImageDestinationAddImage(destination, sheet, nil)
guard CGImageDestinationFinalize(destination) else { fail("PNG write failed") }

print("wrote \(outURL.path) — \(drawn) frames, \(missing.count) empty cells")
if !missing.isEmpty {
    print("empty: \(missing.joined(separator: " "))")
}
print("next: swift validate_atlas.swift \(outURL.path)")
