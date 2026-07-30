#!/usr/bin/env swift
// Renders assets/Allward.iconset from code so the mark stays versioned and
// reproducible instead of living as an opaque binary nobody can edit.
//
// The mark is the product: a split of terminal panes with one focused pane
// carrying the Room seam and a prompt caret. It reads at 16 pt as two shapes
// and at 1024 pt as a composed workspace.

import AppKit
import CoreGraphics
import Foundation

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// Apple's icon grid leaves the artwork inside roughly 0.82 of the canvas.
func draw(into ctx: CGContext, side: CGFloat) {
    let inset = side * 0.09
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * 0.2237

    ctx.saveGState()
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(platePath)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [color(0x1E242C), color(0x0C0F13)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.setStrokeColor(color(0x39414C, 0.9))
    ctx.setLineWidth(max(1, side * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    let pad = plate.width * 0.15
    let field = plate.insetBy(dx: pad, dy: pad)
    let gap = field.width * 0.075
    let leftWidth = (field.width - gap) * 0.62
    let paneRadius = field.width * 0.055

    let focused = CGRect(x: field.minX, y: field.minY, width: leftWidth, height: field.height)
    let rightX = field.minX + leftWidth + gap
    let rightWidth = field.maxX - rightX
    let rightHeight = (field.height - gap) / 2
    let upper = CGRect(
        x: rightX, y: field.minY + rightHeight + gap, width: rightWidth, height: rightHeight)
    let lower = CGRect(x: rightX, y: field.minY, width: rightWidth, height: rightHeight)

    for rect in [upper, lower] {
        ctx.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: paneRadius, cornerHeight: paneRadius,
                transform: nil))
        ctx.setFillColor(color(0x232A33))
        ctx.fillPath()
    }

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -side * 0.008), blur: side * 0.03,
        color: color(0x000000, 0.55))
    ctx.addPath(
        CGPath(
            roundedRect: focused, cornerWidth: paneRadius, cornerHeight: paneRadius,
            transform: nil))
    ctx.setFillColor(color(0x2C3540))
    ctx.fillPath()
    ctx.restoreGState()

    let seamWidth = focused.width * 0.085
    let seam = CGRect(x: focused.minX, y: focused.minY, width: seamWidth, height: focused.height)
    ctx.saveGState()
    ctx.addPath(
        CGPath(
            roundedRect: focused, cornerWidth: paneRadius, cornerHeight: paneRadius,
            transform: nil))
    ctx.clip()
    ctx.setFillColor(color(0x5FB3C9))
    ctx.fill(seam)
    ctx.restoreGState()

    // A prompt chevron plus its cursor block: the smallest mark that still
    // reads as "terminal" at 16 pt.
    let glyphOrigin = CGPoint(
        x: focused.minX + seamWidth + focused.width * 0.17, y: focused.midY)
    let chevronReach = focused.width * 0.20
    let chevronRise = chevronReach * 1.05
    ctx.saveGState()
    ctx.setLineWidth(focused.width * 0.085)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xF2F4F7))
    ctx.move(to: CGPoint(x: glyphOrigin.x, y: glyphOrigin.y + chevronRise))
    ctx.addLine(to: CGPoint(x: glyphOrigin.x + chevronReach, y: glyphOrigin.y))
    ctx.addLine(to: CGPoint(x: glyphOrigin.x, y: glyphOrigin.y - chevronRise))
    ctx.strokePath()
    ctx.restoreGState()

    let cursorWidth = focused.width * 0.20
    let cursorHeight = cursorWidth * 0.42
    let cursor = CGRect(
        x: glyphOrigin.x + chevronReach + focused.width * 0.12,
        y: glyphOrigin.y - chevronRise,
        width: cursorWidth, height: cursorHeight)
    ctx.addPath(
        CGPath(
            roundedRect: cursor, cornerWidth: cursorHeight * 0.3,
            cornerHeight: cursorHeight * 0.3, transform: nil))
    ctx.setFillColor(color(0x5FB3C9))
    ctx.fillPath()
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("assets/Allward.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in sizes {
    let side = CGFloat(entry.px)
    guard
        let ctx = CGContext(
            data: nil, width: entry.px, height: entry.px, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("cannot create bitmap context for \(entry.px)") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(into: ctx, side: side)
    guard let image = ctx.makeImage() else { fatalError("cannot snapshot \(entry.name)") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: entry.px, height: entry.px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(entry.name)")
    }
    try data.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}

print("wrote \(iconset.path)")
