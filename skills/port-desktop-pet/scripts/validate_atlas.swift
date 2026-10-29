#!/usr/bin/env swift
// Validates a sprite sheet against the Codex v2 contract the pet enforces:
// 1536x2288, 8x11 cells of 192x208, transparent background, and every frame
// column the runtime plays actually painted.
//
//   swift validate_atlas.swift <sheet.(png|webp)>
//
// Exit code 0 = usable, 1 = rejected by the app (or visibly broken), 2 = usage.

import CoreGraphics
import Foundation
import ImageIO

let columns = 8
let rows = 11
let cellW = 192
let cellH = 208
let canvasW = columns * cellW
let canvasH = rows * cellH
/// Frames the runtime actually plays, per row; rows 9-10 are the 16 look poses.
let expectedFrames = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]
let opaqueFloor = 32

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 else { fail("usage: swift validate_atlas.swift <sheet.(png|webp)>") }
let url = URL(fileURLWithPath: args[0])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("FAIL cannot decode \(url.lastPathComponent)")
    exit(1)
}

guard image.width == canvasW, image.height == canvasH else {
    print("FAIL \(url.lastPathComponent) is \(image.width)x\(image.height), the app needs \(canvasW)x\(canvasH) (8x11 of \(cellW)x\(cellH))")
    exit(1)
}

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
        bytesPerRow: canvasW * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let raw = ctx.data else {
    fail("cannot allocate \(canvasW)x\(canvasH) inspection bitmap")
}
// A bitmap context's first row is the top of the image, so row index maps
// straight onto the atlas row the runtime crops.
ctx.draw(image, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

let pixels = raw.bindMemory(to: UInt8.self, capacity: canvasW * canvasH * 4)
let bytesPerRow = ctx.bytesPerRow

func cellStats(row: Int, column: Int) -> (count: Int, box: CGRect?) {
    var count = 0
    var minX = cellW, minY = cellH, maxX = -1, maxY = -1
    for y in 0..<cellH {
        let rowStart = (row * cellH + y) * bytesPerRow
        for x in 0..<cellW {
            let alpha = pixels[rowStart + (column * cellW + x) * 4 + 3]
            guard alpha >= 8 else { continue }
            count += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard count > 0 else { return (0, nil) }
    return (count, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
}

var failures: [String] = []
var notes: [String] = []
var opaqueTotal = 0
var stats: [[(count: Int, box: CGRect?)]] = []

for row in 0..<rows {
    var line: [(count: Int, box: CGRect?)] = []
    for column in 0..<columns {
        let cell = cellStats(row: row, column: column)
        opaqueTotal += cell.count
        line.append(cell)
    }
    stats.append(line)
}

for row in 0..<9 {
    let wanted = expectedFrames[row]
    for column in 0..<wanted where stats[row][column].count < opaqueFloor {
        failures.append("row \(row) col \(column) is empty — the app plays \(wanted) frames from this row")
    }
    for column in wanted..<columns where stats[row][column].count >= opaqueFloor {
        notes.append("row \(row) col \(column) is painted but beyond the \(wanted) frames the app uses")
    }
}
for row in 9..<11 {
    for column in 0..<columns where stats[row][column].count < opaqueFloor {
        failures.append("row \(row) col \(column) is empty — all 16 look poses must be painted")
    }
}

let opaqueRatio = Double(opaqueTotal) / Double(canvasW * canvasH)
if opaqueRatio > 0.95 {
    failures.append(String(format: "%.1f%% of the sheet is opaque — the background must be transparent", opaqueRatio * 100))
}

// A cell whose art runs off its own edge loses pixels when the runtime crops.
for row in 0..<rows {
    for column in 0..<columns {
        guard let box = stats[row][column].box else { continue }
        let touches = box.minX < 1 || box.minY < 1
            || box.maxX > CGFloat(cellW - 2) || box.maxY > CGFloat(cellH - 2)
        if touches, row < 9, column < expectedFrames[row] {
            notes.append("row \(row) col \(column) art touches the cell edge (\(Int(box.width))x\(Int(box.height))) — check it is not clipped")
        }
    }
}

if !failures.isEmpty {
    print("FAIL \(url.lastPathComponent)")
    for failure in failures { print("  - \(failure)") }
} else {
    print("PASS \(url.lastPathComponent) — \(canvasW)x\(canvasH), \(String(format: "%.1f%%", opaqueRatio * 100)) painted")
}
for note in notes { print("  note: \(note)") }
exit(failures.isEmpty ? 0 : 1)
