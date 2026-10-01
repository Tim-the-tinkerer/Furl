#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func loadSourceImage() -> CGImage? {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let png = root.appendingPathComponent("Assets/AppIcon-1024.png")
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func drawFallback(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let margin = s * 0.06
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.05, green: 0.12, blue: 0.20, alpha: 1),
        CGColor(srgbRed: 0.10, green: 0.22, blue: 0.32, alpha: 1),
    ] as CFArray
    if let g = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.86, blue: 0.77, alpha: 1))
    let sail = CGMutablePath()
    sail.move(to: CGPoint(x: rect.midX - s * 0.18, y: rect.midY - s * 0.22))
    sail.addLine(to: CGPoint(x: rect.midX + s * 0.22, y: rect.midY))
    sail.addLine(to: CGPoint(x: rect.midX - s * 0.18, y: rect.midY + s * 0.22))
    sail.closeSubpath()
    ctx.addPath(sail)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(srgbRed: 0.77, green: 0.47, blue: 0.23, alpha: 1))
    ctx.setLineWidth(s * 0.03)
    ctx.move(to: CGPoint(x: rect.midX - s * 0.18, y: rect.midY - s * 0.26))
    ctx.addLine(to: CGPoint(x: rect.midX - s * 0.18, y: rect.midY + s * 0.26))
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()
}

func scaled(_ image: CGImage, to size: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

func renderIcon(size: Int, source: CGImage?) -> CGImage? {
    if let source { return scaled(source, to: size) }
    return drawFallback(size: size)
}

func savePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create image destination for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(url.path)") }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let source = loadSourceImage()
if source == nil {
    fputs("No Assets/AppIcon-1024.png — drawing fallback sail icon.\n", stderr)
}
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
let legalNames = Set(sizes.map(\.1))
for (size, name) in sizes {
    guard let image = renderIcon(size: size, source: source) else { fatalError("Failed to render icon at \(size)") }
    savePNG(image, to: iconset.appendingPathComponent(name))
}
if let leftovers = try? FileManager.default.contentsOfDirectory(at: iconset, includingPropertiesForKeys: nil) {
    for url in leftovers where !legalNames.contains(url.lastPathComponent) {
        try? FileManager.default.removeItem(at: url)
    }
}
let icns = assets.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    fputs("iconutil failed with status \(process.terminationStatus)\n", stderr)
    exit(1)
}
print("Generated \(icns.path)")
