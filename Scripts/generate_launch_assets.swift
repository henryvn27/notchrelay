#!/usr/bin/env swift
import AppKit
import Foundation

struct LaunchAssetGenerator {
  let root: URL
  let screenshots: URL
  let icon: NSImage

  init() throws {
    let script = URL(fileURLWithPath: #filePath)
    root = script.deletingLastPathComponent().deletingLastPathComponent()
    screenshots = root.appendingPathComponent("Assets/Screenshots")
    guard
      let loadedIcon = NSImage(
        contentsOf: root.appendingPathComponent("Assets/AppIcon/cowlick-icon-1024.png"))
    else { throw AssetError.missing("1024-point app icon") }
    icon = loadedIcon
  }

  func run() throws {
    try drawHero(
      size: CGSize(width: 1_600, height: 900),
      destination: screenshots.appendingPathComponent("hero.png"))
    try drawHero(
      size: CGSize(width: 1_280, height: 640),
      destination: root.appendingPathComponent("Assets/Social/github-social-preview.png"))
    try drawHero(
      size: CGSize(width: 1_600, height: 900),
      destination: root.appendingPathComponent("Assets/Social/x-launch.png"))
    try drawIconSheet()

    let pressKit = root.appendingPathComponent("Assets/PressKit")
    try FileManager.default.createDirectory(at: pressKit, withIntermediateDirectories: true)
    try replaceCopy(
      root.appendingPathComponent("Assets/AppIcon/cowlick-icon.svg"),
      pressKit.appendingPathComponent("cowlick-icon.svg"))
    try replaceCopy(
      root.appendingPathComponent("Assets/AppIcon/cowlick-icon-1024.png"),
      pressKit.appendingPathComponent("cowlick-icon-1024.png"))
    try replaceCopy(
      screenshots.appendingPathComponent("hero.png"),
      pressKit.appendingPathComponent("cowlick-hero.png"))
  }

  private func drawHero(size: CGSize, destination: URL) throws {
    let scale = size.width / 1_600
    let approval = try loadScreenshot("approval.png")
    let bitmap = try makeCanvas(size: size) {
      let background = NSGradient(
        starting: NSColor(red: 0.12, green: 0.115, blue: 0.105, alpha: 1),
        ending: NSColor(red: 0.045, green: 0.045, blue: 0.042, alpha: 1))
      background?.draw(in: CGRect(origin: .zero, size: size), angle: -32)
      drawGrain(in: size)

      // The actual product surface owns the top center. It meets the edge exactly as it does on
      // a notched display; the empty center is where the camera housing sits on the MacBook.
      approval.draw(
        in: CGRect(
          x: 420 * scale,
          y: size.height - 388 * scale,
          width: 760 * scale,
          height: 388 * scale),
        from: .zero,
        operation: .sourceOver,
        fraction: 1)

      drawText(
        "Cowlick", at: CGPoint(x: 96 * scale, y: 246 * scale),
        font: .systemFont(ofSize: 86 * scale, weight: .semibold),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 1))
      drawText(
        "Codex status and safe approvals,\nright at the notch.",
        at: CGPoint(x: 650 * scale, y: 282 * scale),
        font: .systemFont(ofSize: 30 * scale, weight: .regular),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 0.7))

      drawText(
        "Open source. Local only. No analytics.",
        at: CGPoint(x: 654 * scale, y: 208 * scale),
        font: .systemFont(ofSize: 18 * scale, weight: .medium),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 0.46))

      drawText(
        "$ brew install --cask henryvn27/cowlick/cowlick",
        at: CGPoint(x: 654 * scale, y: 118 * scale),
        font: .monospacedSystemFont(ofSize: 18 * scale, weight: .regular),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 0.82))
    }

    try writePNG(bitmap, to: destination)
  }

  private func drawIconSheet() throws {
    let size = CGSize(width: 1_400, height: 900)
    let bitmap = try makeCanvas(size: size) {
      let background = NSGradient(
        starting: NSColor(red: 0.12, green: 0.115, blue: 0.105, alpha: 1),
        ending: NSColor(red: 0.045, green: 0.045, blue: 0.042, alpha: 1))
      background?.draw(in: CGRect(origin: .zero, size: size), angle: -32)
      drawGrain(in: size)
      drawText(
        "Cowlick app icon", at: CGPoint(x: 80, y: 796),
        font: .systemFont(ofSize: 44, weight: .semibold),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 1))
      drawText(
        "One continuous surface. One deliberate break in the edge.",
        at: CGPoint(x: 82, y: 748), font: .systemFont(ofSize: 22, weight: .medium),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 0.58))

      let sizes: [CGFloat] = [16, 32, 64, 128, 256]
      var x: CGFloat = 80
      for side in sizes {
        let shown = max(side, 48)
        icon.draw(in: CGRect(x: x, y: 118, width: shown, height: shown))
        drawText(
          "\(Int(side))", at: CGPoint(x: x, y: 82),
          font: .monospacedSystemFont(ofSize: 16, weight: .medium),
          color: NSColor.white.withAlphaComponent(0.58))
        x += shown + 48
      }

      icon.draw(in: CGRect(x: 820, y: 210, width: 500, height: 500))
      drawText(
        "512", at: CGPoint(x: 820, y: 164),
        font: .monospacedSystemFont(ofSize: 16, weight: .medium),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 0.52))
      drawText(
        "Editable SVG · 1024 px master", at: CGPoint(x: 880, y: 164),
        font: .systemFont(ofSize: 16, weight: .medium),
        color: NSColor(red: 0.92, green: 0.91, blue: 0.87, alpha: 0.52))
    }
    try writePNG(
      bitmap, to: root.appendingPathComponent("Assets/AppIcon/cowlick-icon-sheet.png"))
  }

  private func drawText(_ value: String, at point: CGPoint, font: NSFont, color: NSColor) {
    value.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
  }

  private func drawGrain(in size: CGSize) {
    var state: UInt64 = 0xC0_57_1C_A1
    let sampleCount = max(1, Int(size.width * size.height / 180))
    for _ in 0..<sampleCount {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let x = CGFloat(state & 0xFFFF) / CGFloat(UInt16.max) * size.width
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let y = CGFloat(state & 0xFFFF) / CGFloat(UInt16.max) * size.height
      let isLight = state & 1 == 0
      NSColor(white: isLight ? 1 : 0, alpha: isLight ? 0.018 : 0.012).setFill()
      NSBezierPath(rect: CGRect(x: x, y: y, width: 1, height: 1)).fill()
    }
  }

  private func loadScreenshot(_ name: String) throws -> NSImage {
    guard let image = NSImage(contentsOf: screenshots.appendingPathComponent(name)) else {
      throw AssetError.missing(name)
    }
    return image
  }

  private func makeCanvas(size: CGSize, drawing: () -> Void) throws -> NSBitmapImageRep {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw AssetError.encoding("canvas") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawing()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  private func writePNG(_ bitmap: NSBitmapImageRep, to destination: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw AssetError.encoding(destination.lastPathComponent)
    }
    try data.write(to: destination, options: .atomic)
  }

  private func replaceCopy(_ source: URL, _ destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
  }
}

enum AssetError: LocalizedError {
  case missing(String)
  case encoding(String)

  var errorDescription: String? {
    switch self {
    case .missing(let value): "Missing launch asset: \(value)"
    case .encoding(let value): "Could not encode launch asset: \(value)"
    }
  }
}

do {
  try LaunchAssetGenerator().run()
  print("Generated hero, social, icon-sheet, and press-kit assets from real app captures.")
} catch {
  FileHandle.standardError.write(
    Data("generate_launch_assets.swift: \(error.localizedDescription)\n".utf8))
  exit(1)
}
