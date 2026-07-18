#!/usr/bin/env swift
import Darwin
import Foundation

enum InstallerFailure: LocalizedError {
  case usage
  case invalidRoot
  case invalidHooks
  case helperMissing
  case shimConflict
  case configurationChanged
  case fileOperation(Int32)

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: install_hooks.swift <install|remove|status> [--helper /path/to/cowlick-hook]"
    case .invalidRoot: "hooks.json must contain a JSON object."
    case .invalidHooks: "The existing hooks field must be a JSON object."
    case .helperMissing: "The specified Cowlick helper does not exist."
    case .shimConflict: "~/.local/bin/cowlick-hook exists and is not Cowlick's symlink."
    case .configurationChanged:
      "hooks.json changed during installation; no configuration was overwritten. Try again."
    case .fileOperation(let code): "A protected file operation failed (errno \(code))."
    }
  }
}

let fileManager = FileManager.default
let environment = ProcessInfo.processInfo.environment
let home = URL(
  fileURLWithPath: environment["COWLICK_HOME"] ?? environment["NOTCHRELAY_HOME"]
    ?? NSHomeDirectory(), isDirectory: true)
let hooksURL = home.appendingPathComponent(".codex/hooks.json")
let installedHelper = home.appendingPathComponent(
  "Library/Application Support/Cowlick/bin/cowlick-hook")
let shim = home.appendingPathComponent(".local/bin/cowlick-hook")
let legacyInstalledHelper = home.appendingPathComponent(
  "Library/Application Support/NotchRelay/bin/notchrelay-hook")
let legacyShim = home.appendingPathComponent(".local/bin/notchrelay-hook")
let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"]

func shellQuote(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

let hookCommand = "\(shellQuote(shim.path)) hook"
let legacyHookCommand = "\(shellQuote(legacyShim.path)) hook"

func normalized(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func handlerCommand(_ handler: [String: Any]) -> String? {
  (handler["command"] as? String).map(normalized)
}

func isCurrent(_ handler: [String: Any]) -> Bool {
  if let marker = handler["cowlick"] as? [String: Any],
    marker["product"] as? String == "Cowlick"
  {
    return true
  }
  return handlerCommand(handler) == normalized(hookCommand)
}

func isLegacy(_ handler: [String: Any]) -> Bool {
  if let marker = handler["notchRelay"] as? [String: Any],
    marker["product"] as? String == "NotchRelay"
  {
    return true
  }
  return handlerCommand(handler) == normalized(legacyHookCommand)
}

func isOurs(_ handler: [String: Any]) -> Bool {
  isCurrent(handler) || isLegacy(handler)
}

func root(from data: Data) throws -> [String: Any] {
  guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw InstallerFailure.invalidRoot
  }
  return value
}

func containsCommand(_ root: [String: Any], event: String) -> Bool {
  guard let hooks = root["hooks"] as? [String: Any],
    let groups = hooks[event] as? [[String: Any]]
  else { return false }
  return groups.contains { group in
    (group["hooks"] as? [[String: Any]])?.contains {
      isCurrent($0)
    } == true
  }
}

func encoded(_ root: [String: Any]) throws -> Data {
  let data =
    try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    + Data([0x0A])
  _ = try JSONSerialization.jsonObject(with: data)
  return data
}

func removingHandlers(
  from original: [String: Any],
  where shouldRemove: ([String: Any]) -> Bool
) -> [String: Any] {
  var value = original
  guard var hooks = value["hooks"] as? [String: Any] else { return value }
  for event in events {
    guard let groups = hooks[event] as? [[String: Any]] else { continue }
    let updated: [[String: Any]] = groups.compactMap { group in
      guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
      let remaining = handlers.filter { !shouldRemove($0) }
      guard !remaining.isEmpty else { return nil }
      var copy = group
      copy["hooks"] = remaining
      return copy
    }
    if updated.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = updated }
  }
  value["hooks"] = hooks
  return value
}

func merge(_ original: Data) throws -> Data {
  var value = try root(from: original)
  if value["hooks"] != nil, !(value["hooks"] is [String: Any]) {
    throw InstallerFailure.invalidHooks
  }
  value = removingHandlers(from: value, where: isLegacy)
  var hooks = value["hooks"] as? [String: Any] ?? [:]
  for event in events where !containsCommand(value, event: event) {
    var groups = hooks[event] as? [[String: Any]] ?? []
    groups.append([
      "hooks": [
        [
          "type": "command",
          "command": hookCommand,
          "timeout": event == "PermissionRequest" ? 75 : 5,
          "statusMessage": "Cowlick",
          "cowlick": ["product": "Cowlick", "protocol": 1],
        ]
      ]
    ])
    hooks[event] = groups
  }
  value["hooks"] = hooks
  return try encoded(value)
}

func remove(_ original: Data) throws -> Data {
  let value = removingHandlers(from: try root(from: original), where: isOurs)
  return try encoded(value)
}

func writePrivateFile(_ data: Data, to url: URL) throws {
  let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  guard descriptor >= 0 else { throw InstallerFailure.fileOperation(errno) }
  let succeeded = data.withUnsafeBytes { bytes -> Bool in
    guard let base = bytes.baseAddress else { return data.isEmpty }
    var written = 0
    while written < bytes.count {
      let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
      if count <= 0 { return false }
      written += count
    }
    return true
  }
  fsync(descriptor)
  Darwin.close(descriptor)
  guard succeeded else {
    unlink(url.path)
    throw InstallerFailure.fileOperation(errno)
  }
}

func replaceHooks(with data: Data, expected original: Data?) throws {
  if let original {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let backup = hooksURL.deletingLastPathComponent().appendingPathComponent(
      "hooks.json.backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
    try writePrivateFile(original, to: backup)
  }
  let temporary = hooksURL.deletingLastPathComponent().appendingPathComponent(
    ".hooks.cowlick-\(UUID().uuidString).tmp")
  try writePrivateFile(data, to: temporary)
  defer { try? fileManager.removeItem(at: temporary) }
  _ = try root(from: Data(contentsOf: temporary))
  if let original {
    guard (try? Data(contentsOf: hooksURL)) == original else {
      throw InstallerFailure.configurationChanged
    }
  } else if fileManager.fileExists(atPath: hooksURL.path) {
    throw InstallerFailure.configurationChanged
  }
  guard rename(temporary.path, hooksURL.path) == 0 else {
    throw InstallerFailure.fileOperation(errno)
  }
}

func withConfigurationLock<Result>(_ body: () throws -> Result) throws -> Result {
  try fileManager.createDirectory(
    at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let lock = hooksURL.deletingLastPathComponent().appendingPathComponent(
    ".hooks.json.cowlick.lock")
  let descriptor = Darwin.open(lock.path, O_RDWR | O_CREAT, 0o600)
  guard descriptor >= 0 else { throw InstallerFailure.fileOperation(errno) }
  guard flock(descriptor, LOCK_EX) == 0 else {
    let code = errno
    Darwin.close(descriptor)
    throw InstallerFailure.fileOperation(code)
  }
  defer {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
  return try body()
}

func installHelper(from source: URL) throws {
  guard fileManager.isExecutableFile(atPath: source.path) else {
    throw InstallerFailure.helperMissing
  }
  if fileManager.fileExists(atPath: shim.path),
    (try? fileManager.destinationOfSymbolicLink(atPath: shim.path)) != installedHelper.path
  {
    throw InstallerFailure.shimConflict
  }
  try fileManager.createDirectory(
    at: installedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fileManager.createDirectory(
    at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fileManager.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: installedHelper.deletingLastPathComponent().path)
  let temporary = installedHelper.deletingLastPathComponent().appendingPathComponent(
    ".cowlick-hook-\(UUID().uuidString).tmp")
  defer { try? fileManager.removeItem(at: temporary) }
  try fileManager.copyItem(at: source, to: temporary)
  try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
  if fileManager.fileExists(atPath: installedHelper.path) {
    _ = try fileManager.replaceItemAt(installedHelper, withItemAt: temporary)
  } else {
    try fileManager.moveItem(at: temporary, to: installedHelper)
  }
  if fileManager.fileExists(atPath: shim.path) {
    return
  } else {
    try fileManager.createSymbolicLink(at: shim, withDestinationURL: installedHelper)
  }
}

func removeHelper(shim helperShim: URL, installedHelper helper: URL) throws {
  if (try? fileManager.destinationOfSymbolicLink(atPath: helperShim.path)) == helper.path {
    try fileManager.removeItem(at: helperShim)
  }
  if fileManager.fileExists(atPath: helper.path) {
    try fileManager.removeItem(at: helper)
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else { throw InstallerFailure.usage }
  switch command {
  case "install":
    guard let helperFlag = arguments.firstIndex(of: "--helper"),
      arguments.indices.contains(helperFlag + 1)
    else { throw InstallerFailure.usage }
    try installHelper(from: URL(fileURLWithPath: arguments[helperFlag + 1]))
    try withConfigurationLock {
      let existed = fileManager.fileExists(atPath: hooksURL.path)
      let existing = existed ? try Data(contentsOf: hooksURL) : Data("{}".utf8)
      let updated = try merge(existing)
      if updated != existing { try replaceHooks(with: updated, expected: existed ? existing : nil) }
    }
    try removeHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
    print("Installed SessionStart, UserPromptSubmit, PermissionRequest, and Stop hooks.")
  case "remove":
    try withConfigurationLock {
      guard fileManager.fileExists(atPath: hooksURL.path) else {
        print("No hooks file to update.")
        return
      }
      let existing = try Data(contentsOf: hooksURL)
      let updated = try remove(existing)
      if updated != existing { try replaceHooks(with: updated, expected: existing) }
    }
    try removeHelper(shim: shim, installedHelper: installedHelper)
    try removeHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
    print("Removed only Cowlick and legacy NotchRelay hook handlers.")
  case "status":
    let existing =
      fileManager.fileExists(atPath: hooksURL.path)
      ? try Data(contentsOf: hooksURL) : Data("{}".utf8)
    let value = try root(from: existing)
    let installed = events.filter { containsCommand(value, event: $0) }
    print(
      installed.count == events.count
        ? "healthy"
        : "missing: \(events.filter { !installed.contains($0) }.joined(separator: ", "))")
  default: throw InstallerFailure.usage
  }
} catch {
  FileHandle.standardError.write(Data("install_hooks.swift: \(error.localizedDescription)\n".utf8))
  exit(1)
}
