#!/usr/bin/env swift
// Objective read-out of a capture PNG: where content actually sits, and where
// vertical seams are. Vision judgements at 13 pt are not reliable evidence, so
// layout claims are checked against pixels instead.

import AppKit
import Foundation

guard CommandLine.arguments.count > 1,
    let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
    let rep = image.representations.first as? NSBitmapImageRep
else {
    FileHandle.standardError.write(Data("usage: inspect-capture.swift <png>\n".utf8))
    exit(1)
}

let width = rep.pixelsWide
let height = rep.pixelsHigh

func luminance(_ x: Int, _ y: Int) -> Double {
    guard let color = rep.colorAt(x: x, y: y) else { return 0 }
    return 0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent)
        + 0.0722 * Double(color.blueComponent)
}

// The modal luminance is the background; anything far from it is content.
var histogram = [Int](repeating: 0, count: 101)
let step = max(1, min(width, height) / 200)
for y in stride(from: 0, to: height, by: step) {
    for x in stride(from: 0, to: width, by: step) {
        histogram[Int((luminance(x, y) * 100).rounded())] += 1
    }
}
let background = Double(histogram.firstIndex(of: histogram.max()!) ?? 0) / 100

/// Columns whose content differs from the background, as coverage per column.
var columnCoverage = [Double](repeating: 0, count: width)
for x in stride(from: 0, to: width, by: 1) {
    var hits = 0
    var samples = 0
    for y in stride(from: 0, to: height, by: 2) {
        samples += 1
        if abs(luminance(x, y) - background) > 0.08 { hits += 1 }
    }
    columnCoverage[x] = samples > 0 ? Double(hits) / Double(samples) : 0
}

/// Contiguous runs of columns that carry content, which is what distinguishes
/// one pane from two.
var runs: [(Int, Int)] = []
var start: Int?
for x in 0..<width {
    let occupied = columnCoverage[x] > 0.01
    if occupied, start == nil { start = x }
    if !occupied, let s = start {
        if x - s > 12 { runs.append((s, x - 1)) }
        start = nil
    }
}
if let s = start, width - s > 12 { runs.append((s, width - 1)) }

/// A divider is a narrow full-height column band that differs from background.
var seams: [Int] = []
for x in 1..<(width - 1) where columnCoverage[x] > 0.6 {
    if columnCoverage[x - 1] < 0.3 || columnCoverage[x + 1] < 0.3 { seams.append(x) }
}

print("size=\(width)x\(height) backgroundLuma=\(String(format: "%.3f", background))")
print("contentColumnRuns=\(runs.map { "\($0.0)-\($0.1)" }.joined(separator: ", "))")
print("fullHeightSeamColumns=\(seams.prefix(12).map(String.init).joined(separator: ", "))")

var rowsWithContent = 0
for y in 0..<height {
    var hit = false
    for x in stride(from: 0, to: width, by: 3) where abs(luminance(x, y) - background) > 0.08 {
        hit = true
        break
    }
    if hit { rowsWithContent += 1 }
}
print("rowsWithContent=\(rowsWithContent) of \(height)")
