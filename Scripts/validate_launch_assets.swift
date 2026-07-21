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

private struct CaptureProvenance: Decodable {
  let schemaVersion: Int
  let sourceCommit: String
  let productSourceAlgorithm: String
  let productSourceSHA256: String
  let bundleIdentifier: String
  let marketingVersion: String
  let buildVersion: String
  let appExecutableSHA256: String
  let helperExecutableSHA256: String
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
  ("Assets/Screenshots/usage.png", "Assets/PressKit/Screenshots/usage.png"),
  ("Assets/Social/github-social-preview.png", "Assets/PressKit/Social/github-social-preview.png"),
  ("Assets/Social/x-launch.png", "Assets/PressKit/Social/x-launch.png"),
  ("Assets/Social/launch-copy.md", "Assets/PressKit/Social/launch-copy.md"),
  ("Assets/capture-provenance.json", "Assets/PressKit/capture-provenance.json"),
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
  "Screenshots/usage.png",
  "Social/github-social-preview.png",
  "Social/x-launch.png",
  "Social/launch-copy.md",
  "capture-provenance.json",
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

private func failureCopyIssues(in recognizedText: String) -> [String] {
  let text = recognizedText.lowercased()
  var issues: [String] = []
  if !text.contains("bridge self-test failed") {
    issues.append(
      "Assets/Screenshots/failed-expanded.png does not visibly contain “Bridge self-test failed”.")
  }
  if text.contains("build verification failed") {
    issues.append(
      "Assets/Screenshots/failed-expanded.png contains stale “Build verification failed” copy.")
  }
  return issues
}

private func diagnosticsCopyIssues(in recognizedText: String) -> [String] {
  let text = recognizedText.lowercased()
  var issues: [String] = []
  for required in [
    "launch-asset demo snapshot",
    "not live device data",
    "hook status: installed",
    "codex hook trust: trusted (demo)",
    "helper installed: true",
    "socket status: listening",
  ] where !text.contains(required) {
    issues.append("Assets/Screenshots/diagnostics.png does not visibly contain “\(required)”.")
  }
  for stale in [
    "hooks are not installed",
    "hooks are missing or disabled",
    "helper installed: false",
  ] where text.contains(stale) {
    issues.append("Assets/Screenshots/diagnostics.png contains stale “\(stale)” copy.")
  }
  for unhealthyTrust in ["untrusted", "needs review", "unavailable", "missing", "disabled"]
  where text.contains("hook trust: \(unhealthyTrust)") {
    issues.append(
      "Assets/Screenshots/diagnostics.png contains unhealthy hook trust “\(unhealthyTrust)”.")
  }
  if text.range(
    of: #"(^|\s)macos:\s*version\s*[0-9]"#, options: .regularExpression) != nil
  {
    issues.append("Assets/Screenshots/diagnostics.png exposes a capture-machine macOS version.")
  }
  if text.range(
    of: #"architecture:\s*(arm64|x86_64)"#, options: .regularExpression) != nil
  {
    issues.append("Assets/Screenshots/diagnostics.png exposes a capture-machine architecture.")
  }
  if text.range(
    of: #"display\s+[0-9]+:\s*[0-9]+[x×][0-9]+"#, options: .regularExpression) != nil
  {
    issues.append("Assets/Screenshots/diagnostics.png exposes capture-machine display dimensions.")
  }
  return issues
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
      minimumSize: nil,
      requiredText: ["Cowlick", "Codex lives", "Local by default", "non-sensitive demo data"]),
    ImageExpectation(
      path: "Assets/Social/github-social-preview.png", exactSize: CGSize(width: 1_280, height: 640),
      minimumSize: nil, requiredText: ["Cowlick", "Codex lives", "Local by default"]),
    ImageExpectation(
      path: "Assets/Social/x-launch.png", exactSize: CGSize(width: 1_600, height: 900),
      minimumSize: nil, requiredText: ["Cowlick", "Working", "Approval", "Done"]),
    ImageExpectation(
      path: "Assets/Screenshots/working.png", exactSize: nil,
      minimumSize: CGSize(width: 300, height: 60), requiredText: ["Scoutly"]),
    ImageExpectation(
      path: "Assets/Screenshots/approval.png", exactSize: nil,
      minimumSize: CGSize(width: 740, height: 220),
      requiredText: ["ActivityPilot", "Deny", "Open Codex", "Allow once"]),
    ImageExpectation(
      path: "Assets/Screenshots/completed.png", exactSize: nil,
      minimumSize: CGSize(width: 300, height: 60), requiredText: ["Meetly"]),
    ImageExpectation(
      path: "Assets/Screenshots/failed.png", exactSize: nil,
      minimumSize: CGSize(width: 300, height: 60), requiredText: ["Scoutly"]),
    ImageExpectation(
      path: "Assets/Screenshots/failed-expanded.png", exactSize: nil,
      minimumSize: CGSize(width: 680, height: 180), requiredText: ["Scoutly", "Open Diagnostics"]),
    ImageExpectation(
      path: "Assets/Screenshots/multi-session.png", exactSize: nil,
      minimumSize: CGSize(width: 680, height: 200), requiredText: ["ActivityPilot", "Scoutly"]),
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
      requiredText: [
        "Codex hook trust", "Codex quota", "API-price equivalent",
        "Third-party reset forecast",
      ]),
    ImageExpectation(
      path: "Assets/Screenshots/usage.png", exactSize: nil,
      minimumSize: CGSize(width: 760, height: 1_000),
      requiredText: [
        "Codex quota", "Runs out in", "API-price equivalent", "Will Codex Reset?",
        "not your subscription charge",
      ]),
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
    if expectation.path == "Assets/Screenshots/failed-expanded.png" {
      for issue in failureCopyIssues(in: text) { fail(issue) }
    }
    if expectation.path == "Assets/Screenshots/diagnostics.png" {
      for issue in diagnosticsCopyIssues(in: text) { fail(issue) }
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

private func provenanceIssues(data: Data?) -> [String] {
  guard let data else { return ["Missing Assets/capture-provenance.json"] }
  let expectedKeys: Set<String> = [
    "schemaVersion", "sourceCommit", "productSourceAlgorithm", "productSourceSHA256",
    "bundleIdentifier", "marketingVersion", "buildVersion", "appExecutableSHA256",
    "helperExecutableSHA256",
  ]
  guard
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    Set(object.keys) == expectedKeys,
    let provenance = try? JSONDecoder().decode(CaptureProvenance.self, from: data)
  else {
    return ["Assets/capture-provenance.json does not match the required schema."]
  }

  var issues: [String] = []
  if provenance.schemaVersion != 2 {
    issues.append("Assets/capture-provenance.json has an unsupported schema version.")
  }
  if provenance.sourceCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) == nil {
    issues.append("Assets/capture-provenance.json does not contain a full source commit SHA.")
  }
  if provenance.productSourceSHA256.range(
    of: "^[0-9a-f]{64}$", options: .regularExpression) == nil
  {
    issues.append("Assets/capture-provenance.json has an invalid product source SHA-256.")
  }
  if provenance.productSourceAlgorithm != "sha256(git-ls-tree-r-z-full-tree-v1)" {
    issues.append("Assets/capture-provenance.json has an unsupported product source algorithm.")
  }
  if provenance.bundleIdentifier != "com.henryvn27.Cowlick" {
    issues.append("Assets/capture-provenance.json has the wrong bundle identifier.")
  }
  for (label, value) in [
    ("marketing version", provenance.marketingVersion), ("build version", provenance.buildVersion),
  ] where value.isEmpty {
    issues.append("Assets/capture-provenance.json has an empty \(label).")
  }
  for (label, value) in [
    ("app executable", provenance.appExecutableSHA256),
    ("helper executable", provenance.helperExecutableSHA256),
  ] where value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
    issues.append("Assets/capture-provenance.json has an invalid \(label) SHA-256.")
  }
  return issues
}

private func sourceBindingIssues(
  expectedSource: String,
  checkoutHead: String,
  provenanceProductSourceSHA256: String,
  currentProductSourceSHA256: String?
) -> [String] {
  var issues: [String] = []
  if expectedSource != checkoutHead {
    issues.append("The requested source commit is not the current checkout HEAD.")
  }
  if currentProductSourceSHA256 == nil {
    issues.append("Cowlick product sources could not be read from the requested source commit.")
  } else if provenanceProductSourceSHA256 != currentProductSourceSHA256 {
    issues.append("Cowlick product sources changed after the captured app was built.")
  }
  return issues
}

private func gitOutput(_ arguments: [String]) -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  process.currentDirectoryURL = root
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return (127, "")
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func productSourceDigest(_ sourceCommit: String) -> String? {
  let process = Process()
  process.executableURL = absolute("Scripts/product_source_digest.sh")
  process.arguments = ["--require-clean", sourceCommit]
  process.currentDirectoryURL = root
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return nil
  }
  guard process.terminationStatus == 0 else { return nil }
  return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func validateProvenance(expectedSourceCommit: String) {
  let data = try? Data(contentsOf: absolute("Assets/capture-provenance.json"))
  for issue in provenanceIssues(data: data) { fail(issue) }
  guard let data,
    let provenance = try? JSONDecoder().decode(CaptureProvenance.self, from: data)
  else { return }

  let headResult = gitOutput(["rev-parse", "HEAD"])
  let checkoutHead = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
  for issue in sourceBindingIssues(
    expectedSource: expectedSourceCommit,
    checkoutHead: checkoutHead,
    provenanceProductSourceSHA256: provenance.productSourceSHA256,
    currentProductSourceSHA256: productSourceDigest(expectedSourceCommit)
  ) {
    fail("Assets/capture-provenance.json: \(issue)")
  }
}

private let launchDraftHeadings = [
  "X / Twitter", "Hacker News", "Reddit", "Product Hunt", "GitHub release notes draft",
]
private let disclaimer = "Unofficial community project; not affiliated with or endorsed by OpenAI."

private func launchCopyIssues(_ value: String) -> [String] {
  var issues: [String] = []
  for heading in launchDraftHeadings {
    let marker = "## \(heading)"
    guard let start = value.range(of: marker) else {
      issues.append("Assets/Social/launch-copy.md is missing the \(heading) draft.")
      continue
    }
    let remainder = value[start.upperBound...]
    let end = remainder.range(of: "\n## ")?.lowerBound ?? value.endIndex
    if !value[start.lowerBound..<end].contains(disclaimer) {
      issues.append("The \(heading) draft is missing the OpenAI affiliation disclaimer.")
    }
  }
  for link in [
    "https://github.com/henryvn27/cowlick/blob/main/Assets/Demo/cowlick-demo.mp4",
    "https://github.com/henryvn27/cowlick/tree/main/Assets/PressKit",
  ] where !value.contains(link) {
    issues.append("Assets/Social/launch-copy.md is missing direct link \(link).")
  }
  return issues
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

  if let launchCopy = try? String(
    contentsOf: absolute("Assets/Social/launch-copy.md"), encoding: .utf8)
  {
    for issue in launchCopyIssues(launchCopy) { fail(issue) }
  } else {
    fail("Missing Assets/Social/launch-copy.md")
  }

  if let readme = try? String(contentsOf: absolute("README.md"), encoding: .utf8) {
    for link in ["(Assets/Demo/cowlick-demo.mp4)", "(Assets/PressKit/README.md)"]
    where !readme.contains(link) {
      fail("README.md is missing direct launch-asset link \(link).")
    }
  }

  if let pressReadme = try? String(
    contentsOf: absolute("Assets/PressKit/README.md"), encoding: .utf8)
  {
    for link in [
      "[capture-provenance.json](capture-provenance.json)",
      "[Demo/cowlick-demo.mp4](Demo/cowlick-demo.mp4)",
    ] where !pressReadme.contains(link) {
      fail("Assets/PressKit/README.md is missing direct asset link \(link).")
    }
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

  let validProvenance = Data(
    """
    {
      "schemaVersion": 2,
      "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
      "productSourceAlgorithm": "sha256(git-ls-tree-r-z-full-tree-v1)",
      "productSourceSHA256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "bundleIdentifier": "com.henryvn27.Cowlick",
      "marketingVersion": "1.0.0",
      "buildVersion": "1",
      "appExecutableSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "helperExecutableSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
    """.utf8)
  guard provenanceIssues(data: validProvenance).isEmpty else {
    throw ValidationError.selfCheck("valid capture provenance was rejected")
  }
  guard !provenanceIssues(data: nil).isEmpty else {
    throw ValidationError.selfCheck("missing capture provenance was accepted")
  }
  func mutatedProvenance(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
    guard
      var object = try JSONSerialization.jsonObject(with: validProvenance) as? [String: Any]
    else {
      throw ValidationError.selfCheck("valid capture provenance could not be mutated")
    }
    mutation(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  for (label, invalidProvenance) in [
    ("schema 1", try mutatedProvenance { $0["schemaVersion"] = 1 }),
    ("unknown algorithm", try mutatedProvenance { $0["productSourceAlgorithm"] = "unknown" }),
    ("malformed digest", try mutatedProvenance { $0["productSourceSHA256"] = "invalid" }),
    ("unknown key", try mutatedProvenance { $0["unexpected"] = true }),
  ] where provenanceIssues(data: invalidProvenance).isEmpty {
    throw ValidationError.selfCheck("\(label) capture provenance was accepted")
  }
  let validSource = "0123456789abcdef0123456789abcdef01234567"
  guard
    sourceBindingIssues(
      expectedSource: validSource,
      checkoutHead: validSource,
      provenanceProductSourceSHA256:
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      currentProductSourceSHA256:
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ).isEmpty
  else {
    throw ValidationError.selfCheck("an exact captured source binding was rejected")
  }
  guard
    sourceBindingIssues(
      expectedSource: "fedcba9876543210fedcba9876543210fedcba98",
      checkoutHead: "fedcba9876543210fedcba9876543210fedcba98",
      provenanceProductSourceSHA256:
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      currentProductSourceSHA256:
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ).isEmpty
  else {
    throw ValidationError.selfCheck("a byte-identical rebased source binding was rejected")
  }
  guard
    !sourceBindingIssues(
      expectedSource: "fedcba9876543210fedcba9876543210fedcba98",
      checkoutHead: "fedcba9876543210fedcba9876543210fedcba98",
      provenanceProductSourceSHA256:
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      currentProductSourceSHA256:
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ).isEmpty
  else {
    throw ValidationError.selfCheck("changed product sources after capture were accepted")
  }
  guard
    !sourceBindingIssues(
      expectedSource: validSource,
      checkoutHead: validSource,
      provenanceProductSourceSHA256:
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      currentProductSourceSHA256: nil
    ).isEmpty
  else {
    throw ValidationError.selfCheck("an unreadable product source tree was accepted")
  }
  guard failureCopyIssues(in: "Bridge self-test failed").isEmpty else {
    throw ValidationError.selfCheck("current failure copy was rejected")
  }
  guard !failureCopyIssues(in: "Build verification failed").isEmpty else {
    throw ValidationError.selfCheck("stale failure copy was accepted")
  }
  let healthyDiagnostics =
    "Launch-asset demo snapshot not live device data Hook status: Installed "
    + "Codex hook trust: Trusted (demo) "
    + "Helper installed: true Socket status: listening Supported macOS: 14 or newer"
  guard diagnosticsCopyIssues(in: healthyDiagnostics).isEmpty else {
    throw ValidationError.selfCheck("healthy launch-asset diagnostics copy was rejected")
  }
  let staleDiagnostics =
    "macOS: Version 26.3.1 Architecture: arm64 Hook status: Codex hooks are not installed "
    + "Codex hook trust: Needs review Helper installed: false Socket status: listening "
    + "Display 1: 1512x949"
  guard !diagnosticsCopyIssues(in: staleDiagnostics).isEmpty else {
    throw ValidationError.selfCheck("stale capture-machine diagnostics copy was accepted")
  }
  let validDrafts =
    launchDraftHeadings.map { "## \($0)\n\n\(disclaimer)" }
    .joined(separator: "\n\n")
    + "\nhttps://github.com/henryvn27/cowlick/blob/main/Assets/Demo/cowlick-demo.mp4"
    + "\nhttps://github.com/henryvn27/cowlick/tree/main/Assets/PressKit"
  guard launchCopyIssues(validDrafts).isEmpty else {
    throw ValidationError.selfCheck("complete launch-copy disclaimers or links were rejected")
  }
  var incompleteDrafts = validDrafts
  if let range = incompleteDrafts.range(of: disclaimer) { incompleteDrafts.removeSubrange(range) }
  guard !launchCopyIssues(incompleteDrafts).isEmpty else {
    throw ValidationError.selfCheck("a missing launch-copy disclaimer was accepted")
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

private func argumentValue(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return CommandLine.arguments[index + 1]
}

guard let expectedSourceCommit = argumentValue("--source-ref"),
  expectedSourceCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
else {
  FileHandle.standardError.write(
    Data("Launch-asset validation requires --source-ref with the full checkout HEAD SHA.\n".utf8))
  exit(2)
}

Task {
  validateImages()
  await validateVideo()
  validateProvenance(expectedSourceCommit: expectedSourceCommit)
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
