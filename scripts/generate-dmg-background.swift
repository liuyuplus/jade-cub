#!/usr/bin/env swift

import AppKit
import Foundation

struct Configuration {
    let outputPath: String
    let width: Int
    let height: Int
    let mascotPath: String?
}

struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1
        return state
    }

    mutating func nextCGFloat() -> CGFloat {
        CGFloat(next() % 10_000) / 10_000.0
    }
}

func scriptURL() -> URL {
    let rawPath = CommandLine.arguments.first ?? "scripts/generate-dmg-background.swift"
    if rawPath.hasPrefix("/") {
        return URL(fileURLWithPath: rawPath).standardizedFileURL
    }

    return URL(fileURLWithPath: rawPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

func defaultMascotPath() -> String {
    scriptURL()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("PingIsland/Assets.xcassets/CodexMintBearIdle.imageset/CodexMintBearIdle.png")
        .path
}

func bundledMascotPath(named assetName: String) -> String {
    scriptURL()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("PingIsland/Assets.xcassets/\(assetName).imageset/\(assetName).png")
        .path
}

func parseArguments() throws -> Configuration {
    var outputPath: String?
    var mascotPath: String?
    var width = 520
    var height = 360

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--output":
            outputPath = iterator.next()
        case "--width":
            if let value = iterator.next(), let parsed = Int(value) {
                width = parsed
            }
        case "--height":
            if let value = iterator.next(), let parsed = Int(value) {
                height = parsed
            }
        case "--mascot":
            mascotPath = iterator.next()
        default:
            continue
        }
    }

    guard let outputPath else {
        throw NSError(
            domain: "JadeCubDMG",
            code: 64,
            userInfo: [NSLocalizedDescriptionKey: "Usage: generate-dmg-background.swift --output <png-path> [--width <pixels>] [--height <pixels>] [--mascot <png-path>]"]
        )
    }

    let resolvedMascot = mascotPath ?? defaultMascotPath()
    return Configuration(outputPath: outputPath, width: width, height: height, mascotPath: resolvedMascot)
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillLinearGradient(in rect: NSRect, colors: [NSColor], angle: CGFloat) {
    NSGradient(colors: colors)?.draw(in: rect, angle: angle)
}

func strokeRoundedRect(_ rect: NSRect, radius: CGFloat, color: NSColor, lineWidth: CGFloat, dashPattern: [CGFloat] = []) {
    let path = roundedRect(rect, radius: radius)
    path.lineWidth = lineWidth
    if !dashPattern.isEmpty {
        path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
    }
    color.setStroke()
    path.stroke()
}

func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .center,
    kern: CGFloat = 0
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: kern
    ]

    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
}

func drawMascot(_ image: NSImage?, in rect: NSRect, alpha: CGFloat = 1.0) {
    guard let image else { return }
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
}

func drawScatteredStateMascots(width: CGFloat, height: CGFloat) {
    let mascotSize = width <= 900 ? width * 0.06 : 74
    let states: [(assetName: String, xRatio: CGFloat, yRatio: CGFloat, scale: CGFloat, alpha: CGFloat)] = [
        ("CodexMintBearIdle", 0.78, 0.675, 1.0, 0.88),
        ("CodexMintBearWaiting", 0.075, 0.165, 0.92, 0.92),
        ("CodexMintBearFailed", 0.855, 0.205, 0.88, 0.90)
    ]

    for state in states {
        let assetName = state.assetName
        let path = bundledMascotPath(named: assetName)
        let image = NSImage(contentsOfFile: path)
        let size = mascotSize * state.scale
        drawMascot(
            image,
            in: NSRect(x: width * state.xRatio, y: height * state.yRatio, width: size, height: size),
            alpha: state.alpha
        )
    }
}

func drawPaw(at point: CGPoint, scale: CGFloat, color: NSColor, rotation: CGFloat) {
    let context = NSGraphicsContext.current?.cgContext
    context?.saveGState()
    context?.translateBy(x: point.x, y: point.y)
    context?.rotate(by: rotation)

    color.setFill()
    let pad = NSBezierPath(ovalIn: NSRect(x: -4 * scale, y: -5 * scale, width: 8 * scale, height: 7 * scale))
    pad.fill()

    for toe in [
        NSRect(x: -8 * scale, y: 3 * scale, width: 5 * scale, height: 5 * scale),
        NSRect(x: -2.5 * scale, y: 6 * scale, width: 5 * scale, height: 5 * scale),
        NSRect(x: 3 * scale, y: 3 * scale, width: 5 * scale, height: 5 * scale)
    ] {
        NSBezierPath(ovalIn: toe).fill()
    }

    context?.restoreGState()
}

func drawInstallTrail(from start: CGPoint, to end: CGPoint) {
    let path = NSBezierPath()
    path.move(to: start)
    path.curve(
        to: end,
        controlPoint1: CGPoint(x: start.x + 145, y: start.y + 44),
        controlPoint2: CGPoint(x: end.x - 165, y: end.y - 44)
    )
    path.lineWidth = 7
    path.lineCapStyle = .round
    path.setLineDash([24, 18], count: 2, phase: 0)
    NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.39, alpha: 0.75).setStroke()
    path.stroke()

    let arrow = NSBezierPath()
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: CGPoint(x: end.x - 34, y: end.y + 25))
    arrow.line(to: end)
    arrow.line(to: CGPoint(x: end.x - 36, y: end.y - 23))
    NSColor(calibratedRed: 0.13, green: 0.49, blue: 0.34, alpha: 0.86).setStroke()
    arrow.stroke()

    let pawColor = NSColor(calibratedRed: 0.15, green: 0.54, blue: 0.37, alpha: 0.34)
    drawPaw(at: CGPoint(x: start.x + 86, y: start.y + 25), scale: 1.75, color: pawColor, rotation: -0.18)
    drawPaw(at: CGPoint(x: start.x + 205, y: start.y + 13), scale: 1.55, color: pawColor, rotation: 0.1)
    drawPaw(at: CGPoint(x: end.x - 150, y: end.y - 15), scale: 1.6, color: pawColor, rotation: 0.28)
}

func drawGround(width: CGFloat, height: CGFloat) {
    let shadow = NSBezierPath()
    shadow.move(to: CGPoint(x: 0, y: 0))
    shadow.line(to: CGPoint(x: width, y: 0))
    shadow.line(to: CGPoint(x: width, y: height * 0.14))
    shadow.curve(
        to: CGPoint(x: 0, y: height * 0.11),
        controlPoint1: CGPoint(x: width * 0.70, y: height * 0.22),
        controlPoint2: CGPoint(x: width * 0.26, y: height * 0.04)
    )
    shadow.close()
    NSColor(calibratedRed: 0.88, green: 0.96, blue: 0.90, alpha: 0.82).setFill()
    shadow.fill()

    let ridge = NSBezierPath()
    ridge.move(to: CGPoint(x: 0, y: height * 0.11))
    ridge.curve(
        to: CGPoint(x: width, y: height * 0.14),
        controlPoint1: CGPoint(x: width * 0.26, y: height * 0.04),
        controlPoint2: CGPoint(x: width * 0.70, y: height * 0.22)
    )
    ridge.lineWidth = 3
    NSColor(calibratedRed: 0.42, green: 0.74, blue: 0.53, alpha: 0.28).setStroke()
    ridge.stroke()
}

func drawBackground(configuration: Configuration) throws {
    let width = configuration.width
    let height = configuration.height
    let canvasWidth = CGFloat(width)
    let canvasHeight = CGFloat(height)

    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw NSError(domain: "JadeCubDMG", code: 65, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap"])
    }

    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "JadeCubDMG", code: 66, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context"])
    }

    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    context.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    fillLinearGradient(
        in: canvas,
        colors: [
            NSColor(calibratedRed: 0.985, green: 0.992, blue: 0.972, alpha: 1),
            NSColor(calibratedRed: 0.958, green: 0.984, blue: 0.948, alpha: 1)
        ],
        angle: 92
    )

    var random = LCG(seed: 20260601)
    let speckCount = Int(max(54, min(120, (canvasWidth * canvasHeight) / 13_000)))
    for _ in 0..<speckCount {
        let x = random.nextCGFloat() * canvasWidth
        let y = random.nextCGFloat() * canvasHeight
        let size = max(1.0, random.nextCGFloat() * 3.2)
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size))
        NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.25, alpha: 0.045 + random.nextCGFloat() * 0.045).setFill()
        dot.fill()
    }

    drawGround(width: canvasWidth, height: canvasHeight)

    drawScatteredStateMascots(width: canvasWidth, height: canvasHeight)

    let slotSize = canvasWidth <= 900 ? canvasWidth * 0.16 : 250
    let appCenter = CGPoint(x: canvasWidth * 0.276, y: canvasHeight * 0.48)
    let appSlot = NSRect(x: appCenter.x - slotSize / 2, y: appCenter.y - slotSize / 2, width: slotSize, height: slotSize)
    roundedRect(appSlot, radius: slotSize * 0.18)
        .addClip()
    NSColor(calibratedRed: 0.90, green: 0.98, blue: 0.92, alpha: 0.56).setFill()
    appSlot.fill()
    context.cgContext.resetClip()
    strokeRoundedRect(
        appSlot,
        radius: slotSize * 0.18,
        color: NSColor(calibratedRed: 0.22, green: 0.54, blue: 0.38, alpha: 0.34),
        lineWidth: 5,
        dashPattern: [16, 12]
    )

    let appsCenter = CGPoint(x: canvasWidth * 0.784, y: canvasHeight * 0.485)
    let appsHalo = NSRect(x: appsCenter.x - slotSize * 0.58, y: appsCenter.y - slotSize * 0.52, width: slotSize * 1.16, height: slotSize * 1.04)
    fillLinearGradient(
        in: appsHalo,
        colors: [
            NSColor(calibratedRed: 0.85, green: 0.96, blue: 0.88, alpha: 0.38),
            NSColor(calibratedRed: 0.94, green: 0.99, blue: 0.95, alpha: 0.12)
        ],
        angle: 10
    )
    strokeRoundedRect(
        appsHalo,
        radius: 36,
        color: NSColor(calibratedRed: 0.29, green: 0.62, blue: 0.45, alpha: 0.12),
        lineWidth: 3
    )

    drawInstallTrail(
        from: CGPoint(x: appSlot.maxX + canvasWidth * 0.026, y: canvasHeight * 0.50),
        to: CGPoint(x: appsHalo.minX - canvasWidth * 0.045, y: canvasHeight * 0.50)
    )

    let titleFontSize: CGFloat = canvasWidth <= 900 ? 48 : 86
    let subtitleFontSize: CGFloat = canvasWidth <= 900 ? 16 : 25
    drawText(
        "Jade Cub",
        in: NSRect(x: canvasWidth * 0.18, y: canvasHeight * 0.735, width: canvasWidth * 0.64, height: 112),
        font: NSFont.systemFont(ofSize: titleFontSize, weight: .semibold),
        color: NSColor(calibratedRed: 0.11, green: 0.18, blue: 0.15, alpha: 0.96),
        kern: 0
    )
    drawText(
        "Codex-first status island",
        in: NSRect(x: canvasWidth * 0.25, y: canvasHeight * 0.695, width: canvasWidth * 0.50, height: 42),
        font: NSFont.systemFont(ofSize: subtitleFontSize, weight: .medium),
        color: NSColor(calibratedRed: 0.26, green: 0.40, blue: 0.34, alpha: 0.72),
        kern: 0.4
    )
    drawText(
        "drag to install",
        in: NSRect(x: canvasWidth * 0.38, y: canvasHeight * 0.392, width: canvasWidth * 0.24, height: 44),
        font: NSFont.monospacedSystemFont(ofSize: canvasWidth <= 900 ? 16 : 27, weight: .regular),
        color: NSColor(calibratedRed: 0.22, green: 0.35, blue: 0.29, alpha: 0.62),
        kern: 1.0
    )

    drawPaw(
        at: CGPoint(x: canvasWidth * 0.905, y: canvasHeight * 0.16),
        scale: canvasWidth <= 900 ? 1.1 : 1.9,
        color: NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.35, alpha: 0.16),
        rotation: -0.16
    )
    drawPaw(
        at: CGPoint(x: canvasWidth * 0.84, y: canvasHeight * 0.20),
        scale: canvasWidth <= 900 ? 1.0 : 1.7,
        color: NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.35, alpha: 0.12),
        rotation: 0.24
    )

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "JadeCubDMG", code: 67, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    let outputURL = URL(fileURLWithPath: configuration.outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    try data.write(to: outputURL)
}

do {
    let configuration = try parseArguments()
    try drawBackground(configuration: configuration)
} catch {
    fputs("Failed to generate DMG background: \(error.localizedDescription)\n", stderr)
    exit(1)
}
