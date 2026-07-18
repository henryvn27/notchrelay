import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
  FileHandle.standardError.write(
    Data("usage: measure_window_latency <helper> <working|completed>\n".utf8))
  exit(2)
}

let helperURL = URL(fileURLWithPath: CommandLine.arguments[1])
let event = CommandLine.arguments[2]
guard ["working", "completed"].contains(event) else {
  FileHandle.standardError.write(Data("unsupported event: \(event)\n".utf8))
  exit(2)
}

func islandIsVisible() -> Bool {
  guard
    let windowInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]]
  else { return false }

  return windowInfo.contains { window in
    guard window[kCGWindowOwnerName as String] as? String == "Cowlick",
      let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let width = bounds["Width"] as? Double,
      let height = bounds["Height"] as? Double
    else { return false }
    return width >= 100 && height >= 30
  }
}

guard !islandIsVisible() else {
  FileHandle.standardError.write(Data("island is already visible\n".utf8))
  exit(1)
}

let helper = Process()
helper.executableURL = helperURL
helper.arguments = ["demo", event]
var environment = ProcessInfo.processInfo.environment
environment["COWLICK_DEMO_SESSION_ID"] = "latency-session"
helper.environment = environment
helper.standardOutput = FileHandle.nullDevice
helper.standardError = FileHandle.nullDevice

let started = DispatchTime.now().uptimeNanoseconds
try helper.run()

let deadline = started + 5_000_000_000
while DispatchTime.now().uptimeNanoseconds < deadline {
  if islandIsVisible() {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    print(String(format: "%.1f ms", elapsed))
    helper.waitUntilExit()
    exit(helper.terminationStatus == 0 ? 0 : 1)
  }
  Thread.sleep(forTimeInterval: 0.005)
}

if helper.isRunning { helper.terminate() }
FileHandle.standardError.write(Data("island did not appear within 5 seconds\n".utf8))
exit(1)
