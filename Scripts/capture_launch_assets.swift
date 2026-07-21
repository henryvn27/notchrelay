#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

private struct CaptureSpec {
  let filename: String
  let arguments: [String]
  let minimumLogicalSize: CGSize
  let settleDelay: TimeInterval
}

private struct WindowCandidate {
  let number: CGWindowID
  let bounds: CGRect
}

private struct DisplayGeometry {
  let id: CGDirectDisplayID
  let bounds: CGRect
  let backingScaleFactor: CGFloat
  let safeAreaTopInset: CGFloat
}

private enum CaptureError: LocalizedError {
  case usage
  case missingApp(String)
  case displayNotFound(CGRect)
  case nonRetina(CGDirectDisplayID, CGFloat)
  case notchedDisplay(CGDirectDisplayID, CGFloat)
  case launch(String)
  case windowTimeout(String)
  case screenshot(String)
  case image(String)
  case notRetina(String, CGSize, CGRect)
  case selfCheck(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      "Usage: capture_launch_assets.swift --app /path/to/Cowlick.app"
    case .missingApp(let path):
      "Cowlick executable is missing at \(path)."
    case .displayNotFound(let bounds):
      "Could not resolve a display for the capture window at \(bounds)."
    case .nonRetina(let displayID, let scale):
      "Launch-asset capture requires a 2x Retina display; capture display \(displayID) has scale \(scale)."
    case .notchedDisplay(let displayID, let inset):
      "Capture display \(displayID) has a \(inset)-point top safe-area inset; non-notch evidence requires a display without notched geometry."
    case .launch(let message):
      "Could not launch Cowlick for capture: \(message)"
    case .windowTimeout(let filename):
      "Timed out waiting for Cowlick's \(filename) window."
    case .screenshot(let filename):
      "screencapture failed for \(filename)."
    case .image(let filename):
      "Could not decode captured image \(filename)."
    case .notRetina(let filename, let pixels, let bounds):
      "\(filename) is not a 2x capture (pixels \(Int(pixels.width))x\(Int(pixels.height)), window \(Int(bounds.width))x\(Int(bounds.height)) points)."
    case .selfCheck(let message):
      "Capture self-check failed: \(message)"
    }
  }
}

private let specifications = [
  CaptureSpec(
    filename: "working.png", arguments: ["--simulate-notch", "--state=working"],
    minimumLogicalSize: CGSize(width: 140, height: 28), settleDelay: 0.25),
  CaptureSpec(
    filename: "approval.png", arguments: ["--simulate-notch", "--state=approvalRequested"],
    minimumLogicalSize: CGSize(width: 340, height: 110), settleDelay: 0.35),
  CaptureSpec(
    filename: "completed.png", arguments: ["--simulate-notch", "--state=completed"],
    minimumLogicalSize: CGSize(width: 140, height: 28), settleDelay: 0.2),
  CaptureSpec(
    filename: "failed.png", arguments: ["--simulate-notch", "--state=failed"],
    minimumLogicalSize: CGSize(width: 140, height: 28), settleDelay: 0.2),
  CaptureSpec(
    filename: "failed-expanded.png",
    arguments: ["--simulate-notch", "--state=failed", "--expanded"],
    minimumLogicalSize: CGSize(width: 320, height: 90), settleDelay: 0.3),
  CaptureSpec(
    filename: "multi-session.png", arguments: ["--simulate-notch", "--state=multiple"],
    minimumLogicalSize: CGSize(width: 320, height: 100), settleDelay: 0.35),
  CaptureSpec(
    filename: "onboarding.png", arguments: ["--open-onboarding"],
    minimumLogicalSize: CGSize(width: 500, height: 400), settleDelay: 0.5),
  CaptureSpec(
    filename: "settings.png", arguments: ["--open-settings"],
    minimumLogicalSize: CGSize(width: 560, height: 430), settleDelay: 0.5),
  CaptureSpec(
    filename: "diagnostics.png", arguments: ["--open-diagnostics"],
    minimumLogicalSize: CGSize(width: 520, height: 430), settleDelay: 1.0),
  CaptureSpec(
    filename: "usage.png", arguments: ["--usage-demo", "--open-usage-demo"],
    minimumLogicalSize: CGSize(width: 380, height: 500), settleDelay: 1.0),
]

private func argumentValue(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return CommandLine.arguments[index + 1]
}

private func windowCandidates(processID: pid_t, minimumSize: CGSize) -> [WindowCandidate] {
  guard
    let rawWindows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
  else { return [] }

  return rawWindows.compactMap { window in
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
      let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let boundsValue = window[kCGWindowBounds as String] as? [String: Any],
      let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary),
      bounds.width >= minimumSize.width,
      bounds.height >= minimumSize.height,
      (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01
    else { return nil }
    return WindowCandidate(number: number, bounds: bounds)
  }
  .sorted { first, second in
    first.bounds.width * first.bounds.height > second.bounds.width * second.bounds.height
  }
}

private func displayGeometries() -> [DisplayGeometry] {
  NSScreen.screens.compactMap { screen in
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else { return nil }
    let displayID = CGDirectDisplayID(number.uint32Value)
    return DisplayGeometry(
      id: displayID,
      bounds: CGDisplayBounds(displayID),
      backingScaleFactor: screen.backingScaleFactor,
      safeAreaTopInset: screen.safeAreaInsets.top)
  }
}

private func captureDisplay(
  for windowBounds: CGRect, displays: [DisplayGeometry]
) -> DisplayGeometry? {
  displays
    .map { ($0, windowBounds.intersection($0.bounds)) }
    .filter { !$0.1.isNull && !$0.1.isEmpty }
    .max {
      $0.1.width * $0.1.height < $1.1.width * $1.1.height
    }?
    .0
}

private func validateCaptureDisplay(_ display: DisplayGeometry) throws {
  guard display.safeAreaTopInset < 1 else {
    throw CaptureError.notchedDisplay(display.id, display.safeAreaTopInset)
  }
  guard display.backingScaleFactor >= 1.9 else {
    throw CaptureError.nonRetina(display.id, display.backingScaleFactor)
  }
}

private func waitForStableWindow(
  processID: pid_t,
  specification: CaptureSpec,
  timeout: TimeInterval = 7
) -> WindowCandidate? {
  let deadline = Date().addingTimeInterval(timeout)
  var previous: WindowCandidate?
  var stableSamples = 0

  while Date() < deadline {
    if let current = windowCandidates(
      processID: processID, minimumSize: specification.minimumLogicalSize
    ).first {
      if let previous,
        previous.number == current.number,
        abs(previous.bounds.width - current.bounds.width) < 0.5,
        abs(previous.bounds.height - current.bounds.height) < 0.5
      {
        stableSamples += 1
      } else {
        stableSamples = 0
      }
      previous = current
      if stableSamples >= 3 {
        Thread.sleep(forTimeInterval: specification.settleDelay)
        return windowCandidates(
          processID: processID, minimumSize: specification.minimumLogicalSize
        ).first
      }
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
  return nil
}

private func capture(window: WindowCandidate, to destination: URL) throws {
  let screenshot = Process()
  screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  screenshot.arguments = ["-x", "-o", "-l", String(window.number), destination.path]
  try screenshot.run()
  screenshot.waitUntilExit()
  guard screenshot.terminationStatus == 0 else {
    throw CaptureError.screenshot(destination.lastPathComponent)
  }

  guard let data = try? Data(contentsOf: destination),
    let image = NSBitmapImageRep(data: data)
  else {
    throw CaptureError.image(destination.lastPathComponent)
  }
  let pixels = CGSize(width: image.pixelsWide, height: image.pixelsHigh)
  guard pixels.width >= window.bounds.width * 1.9,
    pixels.height >= window.bounds.height * 1.9
  else {
    throw CaptureError.notRetina(destination.lastPathComponent, pixels, window.bounds)
  }
}

private func stop(_ process: Process) {
  guard process.isRunning else { return }
  process.terminate()
  let deadline = Date().addingTimeInterval(2)
  while process.isRunning, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  process.waitUntilExit()
}

private func run() throws {
  guard let appArgument = argumentValue("--app") else { throw CaptureError.usage }
  let appURL = URL(fileURLWithPath: appArgument).standardizedFileURL
  let executableURL = appURL.appendingPathComponent("Contents/MacOS/Cowlick")
  guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
    throw CaptureError.missingApp(executableURL.path)
  }
  let scriptURL = URL(fileURLWithPath: #filePath)
  let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
  let outputDirectory = root.appendingPathComponent("Assets/Screenshots", isDirectory: true)
  let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CowlickLaunchCapture-\(UUID().uuidString)", isDirectory: true)
  let isolatedHome = stagingDirectory.appendingPathComponent("Home", isDirectory: true)
  try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: stagingDirectory) }
  var captureDisplayIDs = Set<CGDirectDisplayID>()

  for specification in specifications {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--ui-testing", "--disable-auto-hover"] + specification.arguments
    var environment = ProcessInfo.processInfo.environment
    environment["CFFIXED_USER_HOME"] = isolatedHome.path
    environment["COWLICK_ASSET_CAPTURE"] = "1"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw CaptureError.launch(error.localizedDescription)
    }

    guard
      let window = waitForStableWindow(
        processID: process.processIdentifier, specification: specification)
    else {
      stop(process)
      throw CaptureError.windowTimeout(specification.filename)
    }
    guard let display = captureDisplay(for: window.bounds, displays: displayGeometries()) else {
      stop(process)
      throw CaptureError.displayNotFound(window.bounds)
    }
    let stagedURL = stagingDirectory.appendingPathComponent(specification.filename)
    do {
      try validateCaptureDisplay(display)
      try capture(window: window, to: stagedURL)
    } catch {
      stop(process)
      throw error
    }
    captureDisplayIDs.insert(display.id)
    stop(process)
  }

  for specification in specifications {
    let source = stagingDirectory.appendingPathComponent(specification.filename)
    let destination = outputDirectory.appendingPathComponent(specification.filename)
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
  }
  let displayList = captureDisplayIDs.sorted().map(String.init).joined(separator: ", ")
  print(
    "Captured \(specifications.count) current Cowlick surfaces at 2x on verified non-notch display \(displayList)."
  )
}

private func runSelfCheck() throws {
  let left = DisplayGeometry(
    id: 1, bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
    backingScaleFactor: 2, safeAreaTopInset: 0)
  let right = DisplayGeometry(
    id: 2, bounds: CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440),
    backingScaleFactor: 2, safeAreaTopInset: 0)
  guard
    captureDisplay(
      for: CGRect(x: 2_100, y: 100, width: 700, height: 300), displays: [left, right])?.id
      == right.id
  else {
    throw CaptureError.selfCheck("a window on the second display did not resolve there")
  }
  try validateCaptureDisplay(right)

  let notched = DisplayGeometry(
    id: 3, bounds: right.bounds, backingScaleFactor: 2, safeAreaTopInset: 74)
  do {
    try validateCaptureDisplay(notched)
    throw CaptureError.selfCheck("notched geometry was accepted")
  } catch CaptureError.notchedDisplay {
  }

  let nonRetina = DisplayGeometry(
    id: 4, bounds: right.bounds, backingScaleFactor: 1, safeAreaTopInset: 0)
  do {
    try validateCaptureDisplay(nonRetina)
    throw CaptureError.selfCheck("a 1x capture display was accepted")
  } catch CaptureError.nonRetina {
  }

  print("Launch-asset capture display self-check passed.")
}

do {
  if CommandLine.arguments.contains("--self-check") {
    try runSelfCheck()
  } else {
    try run()
  }
} catch {
  FileHandle.standardError.write(
    Data("capture_launch_assets: \(error.localizedDescription)\n".utf8))
  exit(1)
}
