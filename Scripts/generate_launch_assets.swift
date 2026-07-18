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
        contentsOf: root.appendingPathComponent("Assets/AppIcon/notchrelay-icon-1024.png"))
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
      root.appendingPathComponent("Assets/AppIcon/notchrelay-icon.svg"),
      pressKit.appendingPathComponent("notchrelay-icon.svg"))
    try replaceCopy(
      root.appendingPathComponent("Assets/AppIcon/notchrelay-icon-1024.png"),
      pressKit.appendingPathComponent("notchrelay-icon-1024.png"))
    try replaceCopy(
      screenshots.appendingPathComponent("hero.png"),
      pressKit.appendingPathComponent("notchrelay-hero.png"))
  }

  private func drawHero(size: CGSize, destination: URL) throws {
    let scale = size.width / 1_600
    let approval = try loadScreenshot("approval.png")
    let sessions = try loadScreenshot("multi-session.png")
    let working = try loadScreenshot("working.png")
    let completed = try loadScreenshot("completed.png")
    let bitmap = try makeCanvas(size: size) {
      NSGradient(
        colors: [
          NSColor(red: 0.015, green: 0.022, blue: 0.035, alpha: 1),
          NSColor(red: 0.03, green: 0.035, blue: 0.055, alpha: 1),
        ])!.draw(in: CGRect(origin: .zero, size: size), angle: -28)

      let glow = NSBezierPath(
        ovalIn: CGRect(
          x: size.width * 0.56, y: -120 * scale, width: 820 * scale,
          height: 820 * scale))
      NSColor(red: 0.14, green: 0.74, blue: 0.88, alpha: 0.075).setFill()
      glow.fill()

      icon.draw(
        in: CGRect(
          x: 96 * scale, y: size.height - 196 * scale, width: 92 * scale,
          height: 92 * scale))
      drawText(
        "NotchRelay", at: CGPoint(x: 216 * scale, y: size.height - 164 * scale),
        font: .systemFont(ofSize: 58 * scale, weight: .bold), color: .white)
      drawText(
        "Local Codex status and safe approvals, right at the notch.",
        at: CGPoint(x: 100 * scale, y: size.height - 250 * scale),
        font: .systemFont(ofSize: 26 * scale, weight: .medium),
        color: NSColor.white.withAlphaComponent(0.72))

      let commandRect = CGRect(
        x: 100 * scale, y: size.height - 330 * scale, width: 560 * scale,
        height: 54 * scale)
      NSColor(red: 0.05, green: 0.065, blue: 0.085, alpha: 1).setFill()
      NSBezierPath(roundedRect: commandRect, xRadius: 14 * scale, yRadius: 14 * scale)
        .fill()
      drawText(
        "Source available: github.com/henryvn27/notchrelay",
        at: CGPoint(x: 122 * scale, y: commandRect.minY + 16 * scale),
        font: .monospacedSystemFont(ofSize: 17 * scale, weight: .medium),
        color: NSColor(red: 0.49, green: 0.91, blue: 1, alpha: 1))

      drawPanel(
        approval,
        in: CGRect(x: 100 * scale, y: 92 * scale, width: 665 * scale, height: 273 * scale))
      label("APPROVAL", at: CGPoint(x: 112 * scale, y: 60 * scale), scale: scale)
      drawPanel(
        sessions,
        in: CGRect(x: 845 * scale, y: 96 * scale, width: 594 * scale, height: 231 * scale))
      label("MULTI-SESSION", at: CGPoint(x: 857 * scale, y: 64 * scale), scale: scale)
      drawPanel(
        working,
        in: CGRect(x: 950 * scale, y: 426 * scale, width: 316 * scale, height: 68 * scale))
      drawPanel(
        completed,
        in: CGRect(x: 1_100 * scale, y: 362 * scale, width: 316 * scale, height: 68 * scale))
    }

    try writePNG(bitmap, to: destination)
  }

  private func drawIconSheet() throws {
    let size = CGSize(width: 1_400, height: 900)
    let bitmap = try makeCanvas(size: size) {
      NSColor(red: 0.018, green: 0.023, blue: 0.034, alpha: 1).setFill()
      NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
      drawText(
        "NotchRelay app icon", at: CGPoint(x: 80, y: 796),
        font: .systemFont(ofSize: 44, weight: .bold), color: .white)
      drawText(
        "A local relay signal in the negative space of a MacBook notch.",
        at: CGPoint(x: 82, y: 748), font: .systemFont(ofSize: 22, weight: .medium),
        color: NSColor.white.withAlphaComponent(0.62))

      let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512]
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

      icon.draw(in: CGRect(x: 870, y: 278, width: 420, height: 420))
      drawText(
        "SOURCE: SVG  •  MASTER: 1024 × 1024", at: CGPoint(x: 880, y: 238),
        font: .monospacedSystemFont(ofSize: 15, weight: .medium),
        color: NSColor(red: 0.49, green: 0.91, blue: 1, alpha: 0.88))
    }
    try writePNG(
      bitmap, to: root.appendingPathComponent("Assets/AppIcon/notchrelay-icon-sheet.png"))
  }

  private func drawPanel(_ image: NSImage, in rect: CGRect) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.58)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = CGSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
  }

  private func label(_ value: String, at point: CGPoint, scale: CGFloat) {
    drawText(
      value, at: point, font: .monospacedSystemFont(ofSize: 13 * scale, weight: .semibold),
      color: NSColor.white.withAlphaComponent(0.42))
  }

  private func drawText(_ value: String, at point: CGPoint, font: NSFont, color: NSColor) {
    value.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
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
