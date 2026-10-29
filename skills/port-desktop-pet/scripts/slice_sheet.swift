#!/usr/bin/env swift
// Cuts any grid sheet into per-cell PNGs so another app's layout can be
// remapped into rows/columns the pet understands.
//
//   swift slice_sheet.swift <sheet> <cols> <rows> <out-dir> [cellWxH]
//
// Writes <out-dir>/<row>/<col>.png — exactly the frames-directory layout that
// build_atlas.swift consumes.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    fail("usage: swift slice_sheet.swift <sheet> <cols> <rows> <out-dir> [cellWxH]")
}
let sourceURL = URL(fileURLWithPath: args[0])
guard let columns = Int(args[1]), let rows = Int(args[2]), columns > 0, rows > 0 else {
    fail("cols and rows must be positive integers")
}
let outDir = URL(fileURLWithPath: args[3], isDirectory: true)

var cellWidth = 0
var cellHeight = 0
if args.count >= 5 {
    let parts = args[4].lowercased().split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
        fail("cell size must look like 192x208")
    }
    cellWidth = w
    cellHeight = h
}

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot decode \(sourceURL.path)")
}
if cellWidth == 0 { cellWidth = sheet.width / columns }
if cellHeight == 0 { cellHeight = sheet.height / rows }
guard cellWidth * columns <= sheet.width, cellHeight * rows <= sheet.height else {
    fail("\(cellWidth)x\(cellHeight) x \(columns)x\(rows) does not fit \(sheet.width)x\(sheet.height)")
}

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

var written = 0
for row in 0..<rows {
    for column in 0..<columns {
        let rect = CGRect(
            x: column * cellWidth, y: row * cellHeight,
            width: cellWidth, height: cellHeight)
        guard let cell = sheet.cropping(to: rect), let data = pngData(cell) else { continue }
        let url = outDir
            .appendingPathComponent("\(row)", isDirectory: true)
            .appendingPathComponent("\(column).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        written += 1
    }
}
print("wrote \(written) cells to \(outDir.path) (\(cellWidth)x\(cellHeight) each)")
