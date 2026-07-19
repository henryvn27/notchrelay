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

private enum CaptureError: LocalizedError {
  case usage
  case missingApp(String)
  case nonRetina(CGFloat)
  case launch(String)
  case windowTimeout(String)
  case screenshot(String)
  case image(String)
  case notRetina(String, CGSize, CGRect)

  var errorDescription: String? {
    switch self {
    case .usage:
      "Usage: capture_launch_assets.swift --app /path/to/Cowlick.app"
    case .missingApp(let path):
      "Cowlick executable is missing at \(path)."
    case .nonRetina(let scale):
      "Launch-asset capture requires a 2x Retina display; the active display scale is \(scale)."
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
    }
  }
}

private let specifications = [
  CaptureSpec(
    filename: "working.png", arguments: ["--state=working"],
    minimumLogicalSize: CGSize(width: 140, height: 28), settleDelay: 0.25),
  CaptureSpec(
    filename: "approval.png", arguments: ["--state=approvalRequested"],
    minimumLogicalSize: CGSize(width: 340, height: 130), settleDelay: 0.35),
  CaptureSpec(
    filename: "completed.png", arguments: ["--state=completed"],
    minimumLogicalSize: CGSize(width: 140, height: 28), settleDelay: 0.2),
  CaptureSpec(
    filename: "failed.png", arguments: ["--state=failed"],
    minimumLogicalSize: CGSize(width: 140, height: 28), settleDelay: 0.2),
  CaptureSpec(
    filename: "failed-expanded.png", arguments: ["--state=failed", "--expanded"],
    minimumLogicalSize: CGSize(width: 320, height: 110), settleDelay: 0.3),
  CaptureSpec(
    filename: "multi-session.png", arguments: ["--state=multiple"],
    minimumLogicalSize: CGSize(width: 320, height: 130), settleDelay: 0.35),
  CaptureSpec(
    filename: "onboarding.png", arguments: ["--open-onboarding"],
    minimumLogicalSize: CGSize(width: 500, height: 400), settleDelay: 0.5),
  CaptureSpec(
    filename: "settings.png", arguments: ["--open-settings"],
    minimumLogicalSize: CGSize(width: 560, height: 430), settleDelay: 0.5),
  CaptureSpec(
    filename: "diagnostics.png", arguments: ["--open-diagnostics"],
    minimumLogicalSize: CGSize(width: 520, height: 430), settleDelay: 1.0),
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
  let activeScale = NSScreen.main?.backingScaleFactor ?? 1
  guard activeScale >= 1.9 else { throw CaptureError.nonRetina(activeScale) }

  let scriptURL = URL(fileURLWithPath: #filePath)
  let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
  let outputDirectory = root.appendingPathComponent("Assets/Screenshots", isDirectory: true)
  let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CowlickLaunchCapture-\(UUID().uuidString)", isDirectory: true)
  let isolatedHome = stagingDirectory.appendingPathComponent("Home", isDirectory: true)
  try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: stagingDirectory) }

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
    let stagedURL = stagingDirectory.appendingPathComponent(specification.filename)
    do {
      try capture(window: window, to: stagedURL)
    } catch {
      stop(process)
      throw error
    }
    stop(process)
  }

  for specification in specifications {
    let source = stagingDirectory.appendingPathComponent(specification.filename)
    let destination = outputDirectory.appendingPathComponent(specification.filename)
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
  }
  print("Captured \(specifications.count) current Cowlick surfaces at 2x on a non-notch display.")
}

do {
  try run()
} catch {
  FileHandle.standardError.write(
    Data("capture_launch_assets: \(error.localizedDescription)\n".utf8))
  exit(1)
}
