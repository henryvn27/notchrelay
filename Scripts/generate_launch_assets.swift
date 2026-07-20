#!/usr/bin/env swift
import AppKit
import Foundation

private struct LoadedImage {
  let image: NSImage
  let pixelSize: CGSize
}

private struct LaunchAssetGenerator {
  let root: URL
  let screenshots: URL
  let icon: NSImage

  private let background = NSColor(red: 0.075, green: 0.073, blue: 0.068, alpha: 1)
  private let foreground = NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1)
  private let accent = NSColor(red: 0.88, green: 0.68, blue: 0.38, alpha: 1)
  private let paper = NSColor(red: 0.914, green: 0.902, blue: 0.871, alpha: 1)
  private let paperInk = NSColor(red: 0.067, green: 0.067, blue: 0.059, alpha: 1)
  private let paperMuted = NSColor(red: 0.408, green: 0.400, blue: 0.373, alpha: 1)

  init() throws {
    let script = URL(fileURLWithPath: #filePath)
    root = script.deletingLastPathComponent().deletingLastPathComponent()
    screenshots = root.appendingPathComponent("Assets/Screenshots", isDirectory: true)
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
    try drawGitHubPreview(
      destination: root.appendingPathComponent("Assets/Social/github-social-preview.png"))
    try drawXLaunch(destination: root.appendingPathComponent("Assets/Social/x-launch.png"))
    try drawIconSheet()
    try synchronizePressKit()
  }

  private func drawHero(size: CGSize, destination: URL) throws {
    let approval = try loadScreenshot("approval.png")
    let bitmap = try makeCanvas(size: size) {
      paper.setFill()
      NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
      background.setFill()
      NSBezierPath(rect: CGRect(x: 0, y: 724, width: size.width, height: 176)).fill()
      NSBezierPath(
        roundedRect: CGRect(x: 420, y: 548, width: 760, height: 470),
        xRadius: 38,
        yRadius: 38
      ).fill()

      icon.draw(in: CGRect(x: 84, y: 782, width: 58, height: 58))
      drawText(
        "Cowlick", in: CGRect(x: 162, y: 789, width: 350, height: 52),
        font: .systemFont(ofSize: 38, weight: .semibold), color: foreground)
      drawImage(
        approval, anchoredAt: CGPoint(x: 474, y: 650),
        maximumSize: CGSize(width: 652, height: 242))
      drawText(
        "Approval. Enough context to decide.",
        in: CGRect(x: 560, y: 602, width: 480, height: 26),
        font: .systemFont(ofSize: 15, weight: .medium),
        color: foreground.withAlphaComponent(0.54), alignment: .center)
      drawText(
        "Codex lives\nat the notch.",
        in: CGRect(x: 84, y: 222, width: 820, height: 230),
        font: .systemFont(ofSize: 92, weight: .bold), color: paperInk, lineHeight: 0.88)
      drawText(
        "Live Codex status, safe approvals,\nand quota pace. Native on macOS.\nLocal by default.",
        in: CGRect(x: 1_050, y: 262, width: 440, height: 126),
        font: .systemFont(ofSize: 25, weight: .regular),
        color: paperMuted, lineHeight: 1.28)
      drawText(
        "github.com/henryvn27/cowlick", in: CGRect(x: 88, y: 76, width: 490, height: 32),
        font: .monospacedSystemFont(ofSize: 18, weight: .regular),
        color: paperMuted)
      drawText(
        "Current app · non-sensitive demo data",
        in: CGRect(x: 1_100, y: 78, width: 390, height: 24),
        font: .systemFont(ofSize: 14, weight: .medium),
        color: paperMuted.withAlphaComponent(0.74), alignment: .right)
    }
    try writePNG(bitmap, to: destination)
  }

  private func drawGitHubPreview(destination: URL) throws {
    let size = CGSize(width: 1_280, height: 640)
    let approval = try loadScreenshot("approval.png")
    let bitmap = try makeCanvas(size: size) {
      paper.setFill()
      NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
      background.setFill()
      NSBezierPath(rect: CGRect(x: 0, y: 516, width: size.width, height: 124)).fill()
      NSBezierPath(
        roundedRect: CGRect(x: 360, y: 366, width: 560, height: 390),
        xRadius: 30,
        yRadius: 30
      ).fill()

      icon.draw(in: CGRect(x: 52, y: 552, width: 48, height: 48))
      drawText(
        "Cowlick", in: CGRect(x: 116, y: 555, width: 250, height: 46),
        font: .systemFont(ofSize: 34, weight: .semibold), color: foreground)
      drawImage(
        approval, anchoredAt: CGPoint(x: 404, y: 448),
        maximumSize: CGSize(width: 472, height: 194))
      drawText(
        "Approval. Enough context to decide.",
        in: CGRect(x: 430, y: 405, width: 420, height: 22),
        font: .systemFont(ofSize: 13, weight: .medium),
        color: foreground.withAlphaComponent(0.54), alignment: .center)
      drawText(
        "Codex lives\nat the notch.",
        in: CGRect(x: 52, y: 120, width: 680, height: 184),
        font: .systemFont(ofSize: 76, weight: .bold), color: paperInk, lineHeight: 0.88)
      drawText(
        "Live Codex status, safe approvals,\nand quota pace. Native on macOS.\nLocal by default.",
        in: CGRect(x: 842, y: 158, width: 368, height: 108),
        font: .systemFont(ofSize: 21, weight: .regular),
        color: paperMuted, lineHeight: 1.28)
      drawText(
        "github.com/henryvn27/cowlick", in: CGRect(x: 54, y: 52, width: 420, height: 28),
        font: .monospacedSystemFont(ofSize: 15, weight: .regular), color: paperMuted)
    }
    try writePNG(bitmap, to: destination)
  }

  private func drawXLaunch(destination: URL) throws {
    let size = CGSize(width: 1_600, height: 900)
    let approval = try loadScreenshot("approval.png")
    let sessions = try loadScreenshot("multi-session.png")
    let completed = try loadScreenshot("completed.png")
    let bitmap = try makeCanvas(size: size) {
      fillBackground(size)
      icon.draw(in: CGRect(x: 70, y: 754, width: 70, height: 70))
      drawText(
        "Cowlick", in: CGRect(x: 164, y: 760, width: 340, height: 64),
        font: .systemFont(ofSize: 50, weight: .semibold), color: foreground)
      drawText(
        "Working. Approval. Done.", in: CGRect(x: 70, y: 678, width: 750, height: 58),
        font: .systemFont(ofSize: 36, weight: .semibold), color: foreground)
      drawText(
        "A native, local-first companion for Codex.",
        in: CGRect(x: 72, y: 638, width: 700, height: 32),
        font: .systemFont(ofSize: 20, weight: .regular),
        color: foreground.withAlphaComponent(0.58))

      drawImage(
        approval, anchoredAt: CGPoint(x: 64, y: 284),
        maximumSize: CGSize(width: 760, height: 312))
      drawText(
        "Explicit, request-matched decisions",
        in: CGRect(x: 76, y: 244, width: 440, height: 24),
        font: .systemFont(ofSize: 15, weight: .semibold),
        color: foreground.withAlphaComponent(0.64))
      drawImage(
        sessions, anchoredAt: CGPoint(x: 864, y: 284),
        maximumSize: CGSize(width: 672, height: 312))
      drawText(
        "Separate projects, one quiet surface",
        in: CGRect(x: 876, y: 244, width: 430, height: 24),
        font: .systemFont(ofSize: 15, weight: .semibold),
        color: foreground.withAlphaComponent(0.64))
      drawImage(
        completed, anchoredAt: CGPoint(x: 864, y: 146),
        maximumSize: CGSize(width: 316, height: 68))

      drawText(
        "github.com/henryvn27/cowlick", in: CGRect(x: 72, y: 76, width: 480, height: 30),
        font: .monospacedSystemFont(ofSize: 17, weight: .regular),
        color: foreground.withAlphaComponent(0.72))
      drawText(
        "Current app · non-notch display capture",
        in: CGRect(x: 1_060, y: 76, width: 470, height: 24),
        font: .systemFont(ofSize: 14, weight: .medium),
        color: foreground.withAlphaComponent(0.38), alignment: .right)
    }
    try writePNG(bitmap, to: destination)
  }

  private func drawIconSheet() throws {
    let size = CGSize(width: 1_400, height: 900)
    let bitmap = try makeCanvas(size: size) {
      fillBackground(size)
      drawText(
        "Cowlick app icon", in: CGRect(x: 72, y: 782, width: 600, height: 64),
        font: .systemFont(ofSize: 44, weight: .semibold), color: foreground)
      drawText(
        "Actual exported rasters, enlarged only where labeled for pixel inspection.",
        in: CGRect(x: 74, y: 736, width: 820, height: 30),
        font: .systemFont(ofSize: 20, weight: .regular),
        color: foreground.withAlphaComponent(0.56))

      let renditions: [(Int, CGFloat, String)] = [
        (16, 64, "4× inspection"),
        (32, 96, "3× inspection"),
        (64, 128, "2× inspection"),
        (128, 128, "actual size"),
        (256, 256, "actual size"),
      ]
      let renditionOrigins: [CGFloat] = [74, 200, 360, 540, 680]
      for ((pixels, shown, note), x) in zip(renditions, renditionOrigins) {
        guard let rendition = try? loadIconRendition(pixels) else { continue }
        NSGraphicsContext.current?.imageInterpolation = pixels < Int(shown) ? .none : .high
        rendition.image.draw(in: CGRect(x: x, y: 238, width: shown, height: shown))
        NSGraphicsContext.current?.imageInterpolation = .high
        drawText(
          "\(pixels) px", in: CGRect(x: x, y: 194, width: max(shown, 96), height: 24),
          font: .monospacedSystemFont(ofSize: 15, weight: .semibold),
          color: foreground.withAlphaComponent(0.72))
        drawText(
          note, in: CGRect(x: x, y: 166, width: max(shown, 110), height: 24),
          font: .systemFont(ofSize: 13, weight: .medium),
          color: foreground.withAlphaComponent(0.4))
      }

      guard let large = try? loadIconRendition(512) else { return }
      large.image.draw(in: CGRect(x: 1_000, y: 264, width: 350, height: 350))
      drawText(
        "512 px raster · editable 1024 px SVG master",
        in: CGRect(x: 1_000, y: 194, width: 360, height: 48),
        font: .monospacedSystemFont(ofSize: 14, weight: .medium),
        color: foreground.withAlphaComponent(0.5))
    }
    try writePNG(bitmap, to: root.appendingPathComponent("Assets/AppIcon/cowlick-icon-sheet.png"))
  }

  private func synchronizePressKit() throws {
    let pressKit = root.appendingPathComponent("Assets/PressKit", isDirectory: true)
    let pressScreenshots = pressKit.appendingPathComponent("Screenshots", isDirectory: true)
    let pressDemo = pressKit.appendingPathComponent("Demo", isDirectory: true)
    let pressSocial = pressKit.appendingPathComponent("Social", isDirectory: true)
    for directory in [pressKit, pressScreenshots, pressDemo, pressSocial] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let copies: [(URL, URL)] = [
      (
        root.appendingPathComponent("Assets/AppIcon/cowlick-icon.svg"),
        pressKit.appendingPathComponent("cowlick-icon.svg")
      ),
      (
        root.appendingPathComponent("Assets/AppIcon/cowlick-icon-1024.png"),
        pressKit.appendingPathComponent("cowlick-icon-1024.png")
      ),
      (
        root.appendingPathComponent("Assets/AppIcon/cowlick-icon-sheet.png"),
        pressKit.appendingPathComponent("cowlick-icon-sheet.png")
      ),
      (
        screenshots.appendingPathComponent("hero.png"),
        pressKit.appendingPathComponent("cowlick-hero.png")
      ),
      (
        root.appendingPathComponent("Assets/Demo/cowlick-demo.mp4"),
        pressDemo.appendingPathComponent("cowlick-demo.mp4")
      ),
      (
        root.appendingPathComponent("Assets/Social/github-social-preview.png"),
        pressSocial.appendingPathComponent("github-social-preview.png")
      ),
      (
        root.appendingPathComponent("Assets/Social/x-launch.png"),
        pressSocial.appendingPathComponent("x-launch.png")
      ),
      (
        root.appendingPathComponent("Assets/Social/launch-copy.md"),
        pressSocial.appendingPathComponent("launch-copy.md")
      ),
      (
        root.appendingPathComponent("Assets/capture-provenance.json"),
        pressKit.appendingPathComponent("capture-provenance.json")
      ),
      (root.appendingPathComponent("LICENSE"), pressKit.appendingPathComponent("LICENSE.txt")),
    ]
    for (source, destination) in copies { try replaceCopy(source, destination) }

    let screenshotNames = [
      "working.png", "approval.png", "completed.png", "failed.png", "failed-expanded.png",
      "multi-session.png", "settings.png", "onboarding.png", "diagnostics.png", "usage.png",
    ]
    for name in screenshotNames {
      try replaceCopy(
        screenshots.appendingPathComponent(name), pressScreenshots.appendingPathComponent(name))
    }
  }

  private func fillBackground(_ size: CGSize) {
    background.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
  }

  private func loadScreenshot(_ name: String) throws -> LoadedImage {
    try loadImage(screenshots.appendingPathComponent(name))
  }

  private func loadIconRendition(_ size: Int) throws -> LoadedImage {
    try loadImage(
      root.appendingPathComponent(
        "Cowlick/Resources/Assets.xcassets/AppIcon.appiconset/icon-\(size).png"))
  }

  private func loadImage(_ url: URL) throws -> LoadedImage {
    guard let image = NSImage(contentsOf: url),
      let data = try? Data(contentsOf: url),
      let bitmap = NSBitmapImageRep(data: data)
    else {
      throw AssetError.missing(url.lastPathComponent)
    }
    return LoadedImage(
      image: image, pixelSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
  }

  private func drawImage(_ loaded: LoadedImage, anchoredAt point: CGPoint, maximumSize: CGSize) {
    let scale = min(
      1, maximumSize.width / loaded.pixelSize.width, maximumSize.height / loaded.pixelSize.height)
    let size = CGSize(
      width: loaded.pixelSize.width * scale, height: loaded.pixelSize.height * scale)
    loaded.image.draw(
      in: CGRect(origin: point, size: size), from: .zero, operation: .sourceOver, fraction: 1)
  }

  private func drawText(
    _ value: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left,
    lineHeight: CGFloat = 1
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineHeightMultiple = lineHeight
    value.draw(
      in: rect,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
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
    NSGraphicsContext.current?.imageInterpolation = .high
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
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw AssetError.missing(source.lastPathComponent)
    }
    try Data(contentsOf: source).write(to: destination, options: .atomic)
  }
}

private enum AssetError: LocalizedError {
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
  print(
    "Generated distinct hero, social, icon-sheet, and self-contained press-kit assets from current app captures."
  )
} catch {
  FileHandle.standardError.write(
    Data("generate_launch_assets: \(error.localizedDescription)\n".utf8))
  exit(1)
}
