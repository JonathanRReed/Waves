#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasWidth = 660
private let canvasHeight = 430

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(
    Data("usage: render-dmg-background.swift OUTPUT.png\n".utf8)
  )
  exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasWidth,
    pixelsHigh: canvasHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ),
  let context = NSGraphicsContext(bitmapImageRep: bitmap)
else {
  fatalError("Could not create the DMG background canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let bounds = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
let background = NSGradient(
  starting: NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.075, alpha: 1),
  ending: NSColor(calibratedRed: 0.075, green: 0.11, blue: 0.135, alpha: 1)
)
background?.draw(in: bounds, angle: -18)

let glowRect = NSRect(x: 165, y: 60, width: 330, height: 310)
let glow = NSGradient(
  starting: NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.82, alpha: 0.17),
  ending: NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.82, alpha: 0)
)
glow?.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

let instructionStyle = NSMutableParagraphStyle()
instructionStyle.alignment = .center
let titleAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
  .foregroundColor: NSColor.white,
  .paragraphStyle: instructionStyle,
]
let detailAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
  .foregroundColor: NSColor.white.withAlphaComponent(0.68),
  .paragraphStyle: instructionStyle,
]

("Drag Waves to Applications" as NSString).draw(
  in: NSRect(x: 90, y: 353, width: 480, height: 29),
  withAttributes: titleAttributes
)
("Keep one installed copy so updates and macOS permissions stay together." as NSString).draw(
  in: NSRect(x: 90, y: 331, width: 480, height: 17),
  withAttributes: detailAttributes
)

let route = NSBezierPath()
route.move(to: NSPoint(x: 236, y: 178))
route.curve(
  to: NSPoint(x: 424, y: 178),
  controlPoint1: NSPoint(x: 292.5, y: 217.5),
  controlPoint2: NSPoint(x: 367.5, y: 138.5)
)
route.lineWidth = 3.5
route.lineCapStyle = .round
NSColor(calibratedRed: 0.12, green: 0.83, blue: 0.86, alpha: 0.9).setStroke()
route.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 411, y: 194))
arrow.line(to: NSPoint(x: 431, y: 178))
arrow.line(to: NSPoint(x: 411, y: 162))
arrow.lineWidth = 3.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
  fatalError("Could not encode the DMG background as PNG")
}
try FileManager.default.createDirectory(
  at: outputURL.deletingLastPathComponent(),
  withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
