#!/usr/bin/env swift
import AVFoundation
import AppKit
import Foundation
import Vision

private enum ValidationError: LocalizedError {
  case failed([String])

  var errorDescription: String? {
    switch self {
    case .failed(let failures): failures.joined(separator: "\n")
    }
  }
}

private struct ImageExpectation {
  let path: String
  let exactSize: CGSize?
  let minimumSize: CGSize?
  let requiredText: [String]
}

private let scriptURL = URL(fileURLWithPath: #filePath)
private let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private var failures: [String] = []

private func absolute(_ path: String) -> URL { root.appendingPathComponent(path) }

private func fail(_ message: String) { failures.append("- \(message)") }

private func imageSize(at url: URL) -> CGSize? {
  guard let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else {
    return nil
  }
  return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
}

private func recognizedText(at url: URL) -> String {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = true
  request.recognitionLanguages = ["en-US"]
  do {
    try VNImageRequestHandler(url: url).perform([request])
  } catch {
    fail("OCR failed for \(url.lastPathComponent): \(error.localizedDescription)")
    return ""
  }
  return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: " ")
}

private func validateImages() {
  let expectations = [
    ImageExpectation(
      path: "Assets/AppIcon/cowlick-icon-1024.png", exactSize: CGSize(width: 1_024, height: 1_024),
      minimumSize: nil, requiredText: []),
    ImageExpectation(
      path: "Assets/AppIcon/cowlick-icon-sheet.png", exactSize: CGSize(width: 1_400, height: 900),
      minimumSize: nil, requiredText: ["Cowlick app icon", "16 px", "32 px", "512 px"]),
    ImageExpectation(
      path: "Assets/Screenshots/hero.png", exactSize: CGSize(width: 1_600, height: 900),
      minimumSize: nil, requiredText: ["Cowlick", "non-notch display capture"]),
    ImageExpectation(
      path: "Assets/Social/github-social-preview.png", exactSize: CGSize(width: 1_280, height: 640),
      minimumSize: nil, requiredText: ["Cowlick", "non-notch display capture"]),
    ImageExpectation(
      path: "Assets/Social/x-launch.png", exactSize: CGSize(width: 1_600, height: 900),
      minimumSize: nil, requiredText: ["Cowlick", "Working", "Approval", "Done"]),
    ImageExpectation(
      path: "Assets/Screenshots/working.png", exactSize: nil,
      minimumSize: CGSize(width: 300, height: 60), requiredText: ["Scoutly"]),
    ImageExpectation(
      path: "Assets/Screenshots/approval.png", exactSize: nil,
      minimumSize: CGSize(width: 740, height: 300),
      requiredText: ["ActivityPilot", "Deny", "Open Codex", "Allow once"]),
    ImageExpectation(
      path: "Assets/Screenshots/completed.png", exactSize: nil,
      minimumSize: CGSize(width: 300, height: 60), requiredText: ["Meetly"]),
    ImageExpectation(
      path: "Assets/Screenshots/failed.png", exactSize: nil,
      minimumSize: CGSize(width: 300, height: 60), requiredText: ["Scoutly"]),
    ImageExpectation(
      path: "Assets/Screenshots/failed-expanded.png", exactSize: nil,
      minimumSize: CGSize(width: 680, height: 220), requiredText: ["Scoutly", "Open Diagnostics"]),
    ImageExpectation(
      path: "Assets/Screenshots/multi-session.png", exactSize: nil,
      minimumSize: CGSize(width: 680, height: 280), requiredText: ["ActivityPilot", "Scoutly"]),
    ImageExpectation(
      path: "Assets/Screenshots/settings.png", exactSize: nil,
      minimumSize: CGSize(width: 1_100, height: 850),
      requiredText: ["General", "Integration", "Quota", "Accounts", "Signals"]),
    ImageExpectation(
      path: "Assets/Screenshots/onboarding.png", exactSize: nil,
      minimumSize: CGSize(width: 1_000, height: 800), requiredText: ["Cowlick", "Step 1 of 7"]),
    ImageExpectation(
      path: "Assets/Screenshots/diagnostics.png", exactSize: nil,
      minimumSize: CGSize(width: 1_000, height: 800),
      requiredText: ["Codex hook trust", "Codex quota", "Third-party reset forecast"]),
  ]

  for expectation in expectations {
    let url = absolute(expectation.path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      fail("Missing \(expectation.path)")
      continue
    }
    guard let size = imageSize(at: url) else {
      fail("Could not decode \(expectation.path)")
      continue
    }
    if let exact = expectation.exactSize,
      Int(size.width) != Int(exact.width) || Int(size.height) != Int(exact.height)
    {
      fail(
        "\(expectation.path) is \(Int(size.width))x\(Int(size.height)); expected \(Int(exact.width))x\(Int(exact.height))"
      )
    }
    if let minimum = expectation.minimumSize,
      size.width < minimum.width || size.height < minimum.height
    {
      fail(
        "\(expectation.path) is \(Int(size.width))x\(Int(size.height)); minimum is \(Int(minimum.width))x\(Int(minimum.height))"
      )
    }
    guard !expectation.requiredText.isEmpty else { continue }
    let text = recognizedText(at: url).lowercased()
    for required in expectation.requiredText where !text.contains(required.lowercased()) {
      fail("\(expectation.path) does not visibly contain “\(required)”.")
    }
    if text.contains("notchrelay") || text.contains("notch relay") {
      fail("\(expectation.path) contains stale NotchRelay branding.")
    }
  }

  for size in [16, 32, 64, 128, 256, 512, 1_024] {
    let path = "Cowlick/Resources/Assets.xcassets/AppIcon.appiconset/icon-\(size).png"
    guard let actual = imageSize(at: absolute(path)) else {
      fail("Missing or invalid \(path)")
      continue
    }
    if Int(actual.width) != size || Int(actual.height) != size {
      fail("\(path) is \(Int(actual.width))x\(Int(actual.height)); expected \(size)x\(size)")
    }
  }

  let hero = try? Data(contentsOf: absolute("Assets/Screenshots/hero.png"))
  let xLaunch = try? Data(contentsOf: absolute("Assets/Social/x-launch.png"))
  if hero == xLaunch { fail("The X launch image must not be byte-identical to the hero image.") }
}

private func validateVideo() async {
  let url = absolute("Assets/Demo/cowlick-demo.mp4")
  guard FileManager.default.fileExists(atPath: url.path) else {
    fail("Missing Assets/Demo/cowlick-demo.mp4")
    return
  }
  let asset = AVURLAsset(url: url)
  let duration: Double
  do {
    duration = CMTimeGetSeconds(try await asset.load(.duration))
  } catch {
    fail("Could not read demo duration: \(error.localizedDescription)")
    return
  }
  guard duration.isFinite, duration >= 5, duration <= 15 else {
    fail("Demo duration is \(duration)s; expected 5–15 seconds.")
    return
  }
  let videoTracks: [AVAssetTrack]
  do {
    videoTracks = try await asset.loadTracks(withMediaType: .video)
  } catch {
    fail("Could not read demo video track: \(error.localizedDescription)")
    return
  }
  guard let track = videoTracks.first else {
    fail("Demo contains no video track.")
    return
  }
  let naturalSize: CGSize
  let transform: CGAffineTransform
  let frameRate: Float
  do {
    naturalSize = try await track.load(.naturalSize)
    transform = try await track.load(.preferredTransform)
    frameRate = try await track.load(.nominalFrameRate)
  } catch {
    fail("Could not read demo video properties: \(error.localizedDescription)")
    return
  }
  let transformed = naturalSize.applying(transform)
  let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
  if Int(size.width) != 1_600 || Int(size.height) != 900 {
    fail("Demo is \(Int(size.width))x\(Int(size.height)); expected 1600x900.")
  }
  if frameRate < 24 { fail("Demo frame rate is below 24 fps.") }
  do {
    if !(try await asset.loadTracks(withMediaType: .audio)).isEmpty {
      fail("Demo must not contain an unnecessary audio track.")
    }
  } catch {
    fail("Could not inspect demo audio tracks: \(error.localizedDescription)")
  }
}

private func validatePressKit() {
  let required = [
    "Assets/PressKit/README.md",
    "Assets/PressKit/LICENSE.txt",
    "Assets/PressKit/cowlick-icon.svg",
    "Assets/PressKit/cowlick-icon-1024.png",
    "Assets/PressKit/cowlick-icon-sheet.png",
    "Assets/PressKit/cowlick-hero.png",
    "Assets/PressKit/Demo/cowlick-demo.mp4",
    "Assets/PressKit/Screenshots/working.png",
    "Assets/PressKit/Screenshots/approval.png",
    "Assets/PressKit/Screenshots/completed.png",
    "Assets/PressKit/Screenshots/multi-session.png",
    "Assets/PressKit/Screenshots/settings.png",
    "Assets/PressKit/Social/github-social-preview.png",
    "Assets/PressKit/Social/x-launch.png",
    "Assets/PressKit/Social/launch-copy.md",
  ]
  for path in required where !FileManager.default.fileExists(atPath: absolute(path).path) {
    fail("Press kit is not self-contained; missing \(path)")
  }

  let synchronizedCopies = [
    ("Assets/AppIcon/cowlick-icon.svg", "Assets/PressKit/cowlick-icon.svg"),
    ("Assets/AppIcon/cowlick-icon-1024.png", "Assets/PressKit/cowlick-icon-1024.png"),
    ("Assets/AppIcon/cowlick-icon-sheet.png", "Assets/PressKit/cowlick-icon-sheet.png"),
    ("Assets/Screenshots/hero.png", "Assets/PressKit/cowlick-hero.png"),
    ("Assets/Demo/cowlick-demo.mp4", "Assets/PressKit/Demo/cowlick-demo.mp4"),
    ("Assets/Screenshots/working.png", "Assets/PressKit/Screenshots/working.png"),
    ("Assets/Screenshots/approval.png", "Assets/PressKit/Screenshots/approval.png"),
    ("Assets/Screenshots/completed.png", "Assets/PressKit/Screenshots/completed.png"),
    ("Assets/Screenshots/failed.png", "Assets/PressKit/Screenshots/failed.png"),
    ("Assets/Screenshots/failed-expanded.png", "Assets/PressKit/Screenshots/failed-expanded.png"),
    ("Assets/Screenshots/multi-session.png", "Assets/PressKit/Screenshots/multi-session.png"),
    ("Assets/Screenshots/settings.png", "Assets/PressKit/Screenshots/settings.png"),
    ("Assets/Screenshots/onboarding.png", "Assets/PressKit/Screenshots/onboarding.png"),
    ("Assets/Screenshots/diagnostics.png", "Assets/PressKit/Screenshots/diagnostics.png"),
    ("Assets/Social/github-social-preview.png", "Assets/PressKit/Social/github-social-preview.png"),
    ("Assets/Social/x-launch.png", "Assets/PressKit/Social/x-launch.png"),
    ("Assets/Social/launch-copy.md", "Assets/PressKit/Social/launch-copy.md"),
  ]
  for (source, pressCopy) in synchronizedCopies {
    guard let sourceData = try? Data(contentsOf: absolute(source)),
      let pressData = try? Data(contentsOf: absolute(pressCopy))
    else { continue }
    if sourceData != pressData {
      fail("Press-kit copy is stale: \(pressCopy) does not match \(source).")
    }
  }
}

private func validateTextAssets() {
  let assetRoot = absolute("Assets")
  guard
    let enumerator = FileManager.default.enumerator(
      at: assetRoot, includingPropertiesForKeys: nil)
  else {
    fail("Could not enumerate Assets")
    return
  }
  for case let url as URL in enumerator {
    guard ["md", "svg", "txt"].contains(url.pathExtension.lowercased()),
      let value = try? String(contentsOf: url, encoding: .utf8)
    else { continue }
    let lowered = value.lowercased()
    if lowered.contains("notchrelay") || lowered.contains("notch relay") {
      fail(
        "\(url.path.replacingOccurrences(of: root.path + "/", with: "")) contains stale branding.")
    }
  }

  if let pressReadme = try? String(
    contentsOf: absolute("Assets/PressKit/README.md"), encoding: .utf8),
    pressReadme.contains("../")
  {
    fail("Press-kit README contains paths outside the self-contained folder.")
  }
}

Task {
  validateImages()
  await validateVideo()
  validatePressKit()
  validateTextAssets()

  if failures.isEmpty {
    print(
      "Cowlick launch assets passed dimensions, OCR, duration, branding, and press-kit validation.")
    exit(0)
  }
  let error = ValidationError.failed(failures)
  FileHandle.standardError.write(
    Data("Launch-asset validation failed:\n\(error.localizedDescription)\n".utf8))
  exit(1)
}
dispatchMain()
