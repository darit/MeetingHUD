#!/usr/bin/env swift
// Generates the MeetingHUD app icon — a clean, modern macOS icon.
// Design: Dark rounded-rect with a stylized audio waveform + HUD visor motif.

import AppKit
import CoreGraphics

let size = 1024
let cgSize = CGSize(width: size, height: size)

// Create bitmap context
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("Failed to create context")
    exit(1)
}

let rect = CGRect(origin: .zero, size: cgSize)

// macOS icon shape: squircle (continuous rounded rect)
let iconInset: CGFloat = 20
let iconRect = rect.insetBy(dx: iconInset, dy: iconInset)
let cornerRadius: CGFloat = 200

// Background gradient — deep navy to dark blue
let gradientColors = [
    CGColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0),
    CGColor(red: 0.12, green: 0.16, blue: 0.28, alpha: 1.0),
    CGColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 1.0),
] as CFArray
let gradientLocations: [CGFloat] = [0.0, 0.5, 1.0]
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: gradientColors,
    locations: gradientLocations
)!

// Draw squircle background
let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(squirclePath)
ctx.clip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 984), end: CGPoint(x: 512, y: 40), options: [])
ctx.resetClip()

// Subtle inner border
ctx.addPath(squirclePath)
ctx.setStrokeColor(CGColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 0.3))
ctx.setLineWidth(3)
ctx.strokePath()

// === Central waveform bars ===
// Five bars of varying height, representing audio waveform
let barWidth: CGFloat = 52
let barSpacing: CGFloat = 32
let barCount = 5
let barHeights: [CGFloat] = [180, 320, 420, 280, 160]
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
let startX = (CGFloat(size) - totalWidth) / 2
let centerY = CGFloat(size) / 2 + 20 // slightly below center

// Accent gradient for bars — teal to cyan
let barGradientColors = [
    CGColor(red: 0.0, green: 0.75, blue: 0.85, alpha: 1.0),
    CGColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1.0),
] as CFArray
let barGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: barGradientColors,
    locations: [0.0, 1.0]
)!

for i in 0..<barCount {
    let x = startX + CGFloat(i) * (barWidth + barSpacing)
    let h = barHeights[i]
    let barRect = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)

    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    ctx.drawLinearGradient(
        barGradient,
        start: CGPoint(x: x, y: centerY - h / 2),
        end: CGPoint(x: x, y: centerY + h / 2),
        options: []
    )
    ctx.restoreGState()

    // Subtle glow around each bar
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 20, color: CGColor(red: 0.0, green: 0.7, blue: 0.9, alpha: 0.3))
    ctx.addPath(barPath)
    ctx.setFillColor(CGColor(red: 0.0, green: 0.7, blue: 0.9, alpha: 0.15))
    ctx.fillPath()
    ctx.restoreGState()
}

// === HUD visor arc — subtle curved line above the waveform ===
ctx.saveGState()
let visorY: CGFloat = centerY - 260
let visorPath = CGMutablePath()
visorPath.move(to: CGPoint(x: startX - 40, y: visorY))
visorPath.addQuadCurve(
    to: CGPoint(x: startX + totalWidth + 40, y: visorY),
    control: CGPoint(x: CGFloat(size) / 2, y: visorY - 60)
)
ctx.addPath(visorPath)
ctx.setStrokeColor(CGColor(red: 0.3, green: 0.8, blue: 0.95, alpha: 0.5))
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.strokePath()

// Small dot at the center of the visor arc (like a recording indicator)
let dotCenter = CGPoint(x: CGFloat(size) / 2, y: visorY - 28)
let dotRadius: CGFloat = 10
let dotRect = CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
ctx.setFillColor(CGColor(red: 0.0, green: 0.9, blue: 0.7, alpha: 0.9))
ctx.fillEllipse(in: dotRect)

// Glow on the dot
ctx.setShadow(offset: .zero, blur: 16, color: CGColor(red: 0.0, green: 0.9, blue: 0.7, alpha: 0.6))
ctx.fillEllipse(in: dotRect)
ctx.restoreGState()

// === "HUD" text label at the bottom ===
ctx.saveGState()
let textY: CGFloat = centerY + 240
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .heavy),
    .foregroundColor: NSColor(red: 0.7, green: 0.8, blue: 0.9, alpha: 0.6),
    .kern: 18
]
let text = NSAttributedString(string: "HUD", attributes: attributes)
let textSize = text.size()
let textOrigin = CGPoint(x: (CGFloat(size) - textSize.width) / 2, y: CGFloat(size) - textY - textSize.height / 2)

// NSAttributedString draws in flipped coordinates, so flip the context
ctx.textMatrix = .identity
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = nsCtx
text.draw(at: textOrigin)
NSGraphicsContext.current = nil
ctx.restoreGState()

// Save as PNG
guard let cgImage = ctx.makeImage() else {
    print("Failed to create image")
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    print("Failed to create image destination")
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
CGImageDestinationFinalize(dest)
print("Generated \(size)x\(size) icon at \(outputPath)")
