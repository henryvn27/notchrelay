#!/usr/bin/env swift
import AVFoundation
import AppKit
import CoreVideo
import Foundation

private struct DemoSegment {
  let screenshot: NSImage
  let pixelSize: CGSize
  let title: String
  let detail: String
  let duration: TimeInterval
}

private enum DemoError: LocalizedError {
  case missing(String)
  case writer(String)
  case pixelBuffer

  var errorDescription: String? {
    switch self {
    case .missing(let value): "Missing demo input: \(value)"
    case .writer(let value): "Could not write Cowlick demo: \(value)"
    case .pixelBuffer: "Could not allocate a demo video frame."
    }
  }
}

private let canvasSize = CGSize(width: 1_600, height: 900)
private let frameRate: Int32 = 30
private let transitionDuration: TimeInterval = 0.22

private func loadImage(_ url: URL) throws -> (NSImage, CGSize) {
  guard let image = NSImage(contentsOf: url),
    let data = try? Data(contentsOf: url),
    let bitmap = NSBitmapImageRep(data: data)
  else {
    throw DemoError.missing(url.lastPathComponent)
  }
  return (image, CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
}

private func drawText(
  _ value: String,
  at point: CGPoint,
  font: NSFont,
  color: NSColor,
  alignment: NSTextAlignment = .left,
  width: CGFloat = 1_400
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = alignment
  value.draw(
    in: CGRect(x: point.x, y: point.y, width: width, height: font.pointSize * 1.6),
    withAttributes: [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ])
}

private func drawImage(_ image: NSImage, pixelSize: CGSize, alpha: CGFloat) {
  let maximum = CGSize(width: 1_020, height: 430)
  let scale = min(1, maximum.width / pixelSize.width, maximum.height / pixelSize.height)
  let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
  let rect = CGRect(
    x: (canvasSize.width - size.width) / 2,
    y: 250 + (maximum.height - size.height) / 2,
    width: size.width,
    height: size.height)
  image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
}

private func drawFrame(
  segment: DemoSegment,
  nextSegment: DemoSegment?,
  transitionProgress: CGFloat
) {
  NSColor(red: 0.075, green: 0.073, blue: 0.068, alpha: 1).setFill()
  CGRect(origin: .zero, size: canvasSize).fill()

  drawText(
    "Cowlick", at: CGPoint(x: 72, y: 760),
    font: .systemFont(ofSize: 44, weight: .semibold),
    color: NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))
  drawText(
    "Local Codex status and safe approvals", at: CGPoint(x: 72, y: 718),
    font: .systemFont(ofSize: 22, weight: .regular),
    color: NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 0.62))
  drawText(
    "github.com/henryvn27/cowlick", at: CGPoint(x: 1_032, y: 765),
    font: .monospacedSystemFont(ofSize: 17, weight: .regular),
    color: NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 0.68),
    alignment: .right,
    width: 496)

  drawImage(segment.screenshot, pixelSize: segment.pixelSize, alpha: 1 - transitionProgress)
  if let nextSegment {
    drawImage(nextSegment.screenshot, pixelSize: nextSegment.pixelSize, alpha: transitionProgress)
  }

  let title = nextSegment == nil || transitionProgress < 0.5 ? segment.title : nextSegment!.title
  let detail = nextSegment == nil || transitionProgress < 0.5 ? segment.detail : nextSegment!.detail
  drawText(
    title, at: CGPoint(x: 72, y: 142),
    font: .systemFont(ofSize: 30, weight: .semibold),
    color: NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))
  drawText(
    detail, at: CGPoint(x: 72, y: 102),
    font: .systemFont(ofSize: 19, weight: .regular),
    color: NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 0.6))
  drawText(
    "Current app capture · non-notch display", at: CGPoint(x: 1_028, y: 108),
    font: .systemFont(ofSize: 15, weight: .medium),
    color: NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 0.42),
    alignment: .right,
    width: 500)
}

private func makePixelBuffer(pool: CVPixelBufferPool) throws -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
    let buffer
  else { throw DemoError.pixelBuffer }
  return buffer
}

private func render(
  buffer: CVPixelBuffer,
  segment: DemoSegment,
  nextSegment: DemoSegment?,
  transitionProgress: CGFloat
) throws {
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
    throw DemoError.pixelBuffer
  }
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: baseAddress,
      width: Int(canvasSize.width),
      height: Int(canvasSize.height),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
  else { throw DemoError.pixelBuffer }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  drawFrame(
    segment: segment, nextSegment: nextSegment, transitionProgress: transitionProgress)
  context.flush()
  NSGraphicsContext.restoreGraphicsState()
}

private func generate() throws {
  let scriptURL = URL(fileURLWithPath: #filePath)
  let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
  let screenshots = root.appendingPathComponent("Assets/Screenshots", isDirectory: true)
  let output = root.appendingPathComponent("Assets/Demo/cowlick-demo.mp4")
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CowlickDemo-\(UUID().uuidString).mp4")
  defer { try? FileManager.default.removeItem(at: temporary) }

  let inputs = try [
    ("working.png", "Working", "A quiet project signal that stays out of the way.", 1.6),
    (
      "multi-session.png", "Multiple sessions", "Independent projects remain easy to distinguish.",
      1.9
    ),
    (
      "approval.png", "Approval requested",
      "Allow once or Deny stays matched to the exact request.", 2.6
    ),
    (
      "usage.png", "Plan usage",
      "See quota pace, time to empty, and the separate API-price equivalent.", 2.2
    ),
    (
      "completed.png", "Completed", "The signal clears without becoming a second Codex client.", 1.7
    ),
  ].map { filename, title, detail, duration -> DemoSegment in
    let loaded = try loadImage(screenshots.appendingPathComponent(filename))
    return DemoSegment(
      screenshot: loaded.0, pixelSize: loaded.1, title: title, detail: detail,
      duration: duration)
  }

  let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(canvasSize.width),
      AVVideoHeightKey: Int(canvasSize.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 5_500_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(canvasSize.width),
      kCVPixelBufferHeightKey as String: Int(canvasSize.height),
    ])
  guard writer.canAdd(input) else { throw DemoError.writer("video input is unsupported") }
  writer.add(input)
  guard writer.startWriting() else {
    throw DemoError.writer(writer.error?.localizedDescription ?? "writer did not start")
  }
  writer.startSession(atSourceTime: .zero)
  guard let pool = adaptor.pixelBufferPool else { throw DemoError.pixelBuffer }

  var frameIndex: Int64 = 0
  for (index, segment) in inputs.enumerated() {
    let frameCount = Int((segment.duration * Double(frameRate)).rounded())
    for localFrame in 0..<frameCount {
      while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
      let remaining = segment.duration - Double(localFrame) / Double(frameRate)
      let progress: CGFloat
      if index < inputs.count - 1, remaining <= transitionDuration {
        progress = CGFloat(1 - remaining / transitionDuration)
      } else {
        progress = 0
      }
      let buffer = try makePixelBuffer(pool: pool)
      try render(
        buffer: buffer,
        segment: segment,
        nextSegment: index < inputs.count - 1 ? inputs[index + 1] : nil,
        transitionProgress: min(max(progress, 0), 1))
      let time = CMTime(value: frameIndex, timescale: frameRate)
      guard adaptor.append(buffer, withPresentationTime: time) else {
        throw DemoError.writer(writer.error?.localizedDescription ?? "frame append failed")
      }
      frameIndex += 1
    }
  }

  input.markAsFinished()
  let semaphore = DispatchSemaphore(value: 0)
  writer.finishWriting { semaphore.signal() }
  semaphore.wait()
  guard writer.status == .completed else {
    throw DemoError.writer(writer.error?.localizedDescription ?? "writer did not finish")
  }
  _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
  print("Generated a 10-second 1600x900 Cowlick demo from current non-notch app captures.")
}

do {
  try generate()
} catch {
  FileHandle.standardError.write(Data("generate_demo: \(error.localizedDescription)\n".utf8))
  exit(1)
}
