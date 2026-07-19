#!/usr/bin/env swift
import AVFoundation
import AppKit
import Foundation
import Vision

private enum ValidationError: LocalizedError {
  case failed([String])
  case selfCheck(String)

  var errorDescription: String? {
    switch self {
    case .failed(let failures): failures.joined(separator: "\n")
    case .selfCheck(let message): "Launch-asset validator self-check failed: \(message)"
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
private let synchronizedCopies = [
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
  ("LICENSE", "Assets/PressKit/LICENSE.txt"),
]
private let pressKitAllowlist: Set<String> = [
  "README.md",
  "LICENSE.txt",
  "cowlick-icon.svg",
  "cowlick-icon-1024.png",
  "cowlick-icon-sheet.png",
  "cowlick-hero.png",
  "Demo/cowlick-demo.mp4",
  "Screenshots/working.png",
  "Screenshots/approval.png",
  "Screenshots/completed.png",
  "Screenshots/failed.png",
  "Screenshots/failed-expanded.png",
  "Screenshots/multi-session.png",
  "Screenshots/settings.png",
  "Screenshots/onboarding.png",
  "Screenshots/diagnostics.png",
  "Social/github-social-preview.png",
  "Social/x-launch.png",
  "Social/launch-copy.md",
]

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
      minimumSize: nil, requiredText: ["Cowlick", "Local-first", "non-notch display capture"]),
    ImageExpectation(
      path: "Assets/Social/github-social-preview.png", exactSize: CGSize(width: 1_280, height: 640),
      minimumSize: nil, requiredText: ["Cowlick", "Local-first", "non-notch display capture"]),
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

private func pressKitIssues(at validationRoot: URL) -> [String] {
  let fileManager = FileManager.default
  var issues: [String] = []
  let readme = validationRoot.appendingPathComponent("Assets/PressKit/README.md")
  if !fileManager.fileExists(atPath: readme.path) {
    issues.append("Press kit is not self-contained; missing Assets/PressKit/README.md")
  }

  for (source, pressCopy) in synchronizedCopies {
    let sourceURL = validationRoot.appendingPathComponent(source)
    let pressURL = validationRoot.appendingPathComponent(pressCopy)
    let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
    let pressCopyExists = fileManager.fileExists(atPath: pressURL.path)
    if !sourceExists { issues.append("Missing source asset endpoint: \(source)") }
    if !pressCopyExists { issues.append("Missing press-kit endpoint: \(pressCopy)") }
    guard sourceExists, pressCopyExists else { continue }

    guard let sourceData = try? Data(contentsOf: sourceURL) else {
      issues.append("Could not read source asset endpoint: \(source)")
      continue
    }
    guard let pressData = try? Data(contentsOf: pressURL) else {
      issues.append("Could not read press-kit endpoint: \(pressCopy)")
      continue
    }
    if sourceData != pressData {
      issues.append("Press-kit copy is stale: \(pressCopy) does not match \(source).")
    }
  }

  let pressKit = validationRoot.appendingPathComponent("Assets/PressKit", isDirectory: true)
  if fileManager.fileExists(atPath: pressKit.path) {
    let resolvedPressKit = pressKit.resolvingSymlinksInPath()
    guard
      let enumerator = fileManager.enumerator(
        at: resolvedPressKit, includingPropertiesForKeys: [.isDirectoryKey])
    else {
      issues.append("Could not enumerate Assets/PressKit")
      return issues
    }
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
        continue
      }
      let resolvedURL = url.resolvingSymlinksInPath()
      let relativePath = String(resolvedURL.path.dropFirst(resolvedPressKit.path.count + 1))
      if !pressKitAllowlist.contains(relativePath) {
        issues.append("Unexpected press-kit content: Assets/PressKit/\(relativePath)")
      }
    }
  }
  return issues
}

private func validatePressKit() {
  for issue in pressKitIssues(at: root) { fail(issue) }
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
    if lowered.contains("local only") {
      fail(
        "\(url.path.replacingOccurrences(of: root.path + "/", with: "")) uses inaccurate local-only copy; use local-first."
      )
    }
  }

  if let pressReadme = try? String(
    contentsOf: absolute("Assets/PressKit/README.md"), encoding: .utf8),
    pressReadme.contains("../")
  {
    fail("Press-kit README contains paths outside the self-contained folder.")
  }
}

private func runPressKitSelfCheck() throws {
  let fileManager = FileManager.default
  let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
    "CowlickLaunchAssetValidator-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: temporaryRoot) }

  func write(_ value: String, to path: String) throws {
    let url = temporaryRoot.appendingPathComponent(path)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
  }

  try write("press kit", to: "Assets/PressKit/README.md")
  for (source, pressCopy) in synchronizedCopies {
    try write(source, to: source)
    try write(source, to: pressCopy)
  }
  let baselineIssues = pressKitIssues(at: temporaryRoot)
  guard baselineIssues.isEmpty else {
    throw ValidationError.selfCheck(
      "a complete synchronized fixture did not pass: \(baselineIssues.joined(separator: "; "))")
  }

  let source = "Assets/Screenshots/working.png"
  let pressCopy = "Assets/PressKit/Screenshots/working.png"
  try fileManager.removeItem(at: temporaryRoot.appendingPathComponent(source))
  guard pressKitIssues(at: temporaryRoot).contains("Missing source asset endpoint: \(source)")
  else {
    throw ValidationError.selfCheck("a missing screenshot source was not rejected")
  }
  try write(source, to: source)

  try fileManager.removeItem(at: temporaryRoot.appendingPathComponent(pressCopy))
  guard pressKitIssues(at: temporaryRoot).contains("Missing press-kit endpoint: \(pressCopy)")
  else {
    throw ValidationError.selfCheck("a missing press-kit screenshot was not rejected")
  }
  try write(source, to: pressCopy)

  try write("mismatched license", to: "Assets/PressKit/LICENSE.txt")
  guard
    pressKitIssues(at: temporaryRoot).contains(
      "Press-kit copy is stale: Assets/PressKit/LICENSE.txt does not match LICENSE.")
  else {
    throw ValidationError.selfCheck("a stale press-kit license was not rejected")
  }
  try write("LICENSE", to: "Assets/PressKit/LICENSE.txt")

  try write("unexpected", to: "Assets/PressKit/Screenshots/unexpected.png")
  guard
    pressKitIssues(at: temporaryRoot).contains(
      "Unexpected press-kit content: Assets/PressKit/Screenshots/unexpected.png")
  else {
    throw ValidationError.selfCheck("unexpected press-kit content was not rejected")
  }

  print("Launch-asset validator self-check passed.")
}

if CommandLine.arguments.contains("--self-check") {
  do {
    try runPressKitSelfCheck()
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
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
