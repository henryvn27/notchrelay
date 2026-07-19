#!/usr/bin/env swift
import Darwin
import Foundation

enum InstallerFailure: LocalizedError {
  case usage
  case invalidRoot
  case invalidHooks
  case helperMissing
  case shimConflict
  case helperConflict
  case configurationChanged
  case invalidSnapshot
  case fileOperation(Int32)

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: install_hooks.swift <install --helper /path/to/cowlick-hook [--snapshot /path]|remove|status|restore --snapshot /path>"
    case .invalidRoot: "hooks.json must contain a JSON object."
    case .invalidHooks: "The existing hooks field must be a JSON object."
    case .helperMissing: "The specified Cowlick helper does not exist."
    case .shimConflict: "~/.local/bin/cowlick-hook exists and is not Cowlick's symlink."
    case .helperConflict:
      "The installed helper path is not owned by Cowlick. Move it aside before changing the integration."
    case .configurationChanged:
      "hooks.json changed during installation; no configuration was overwritten. Try again."
    case .invalidSnapshot: "The Cowlick integration snapshot is incomplete or invalid."
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
let snapshotMarkerName = ".cowlick-integration-snapshot-v1"
let snapshotMarkerContents = Data("1\n".utf8)

enum InstallerCommand {
  case help
  case install(helper: URL, snapshot: URL?)
  case remove
  case status
  case restore(snapshot: URL)
}

func parseCommand(_ arguments: [String]) throws -> InstallerCommand {
  if arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
    return .help
  }
  if arguments.count == 2, ["install", "remove", "status", "restore"].contains(arguments[0]),
    ["--help", "-h"].contains(arguments[1])
  {
    return .help
  }
  if arguments.count == 3, arguments[0] == "install", arguments[1] == "--helper",
    !arguments[2].isEmpty
  {
    return .install(helper: URL(fileURLWithPath: arguments[2]), snapshot: nil)
  }
  if arguments.count == 5, arguments[0] == "install", arguments[1] == "--helper",
    !arguments[2].isEmpty, arguments[3] == "--snapshot", !arguments[4].isEmpty
  {
    return .install(
      helper: URL(fileURLWithPath: arguments[2]),
      snapshot: URL(fileURLWithPath: arguments[4], isDirectory: true))
  }
  if arguments == ["remove"] { return .remove }
  if arguments == ["status"] { return .status }
  if arguments.count == 3, arguments[0] == "restore", arguments[1] == "--snapshot",
    !arguments[2].isEmpty
  {
    return .restore(snapshot: URL(fileURLWithPath: arguments[2], isDirectory: true))
  }
  throw InstallerFailure.usage
}

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

func restoringOwnedHandlers(in current: Data, from snapshot: Data?) throws -> Data {
  var value = removingHandlers(from: try root(from: current), where: isOurs)
  guard let snapshot else { return try encoded(value) }
  let saved = try root(from: snapshot)
  let savedHooks = saved["hooks"] as? [String: Any] ?? [:]
  var hooks = value["hooks"] as? [String: Any] ?? [:]
  if value["hooks"] != nil, !(value["hooks"] is [String: Any]) {
    throw InstallerFailure.invalidHooks
  }
  for event in events {
    let ownedGroups: [[String: Any]] =
      (savedHooks[event] as? [[String: Any]] ?? []).compactMap { group in
        guard let handlers = group["hooks"] as? [[String: Any]] else { return nil }
        let ownedHandlers = handlers.filter(isOurs)
        guard !ownedHandlers.isEmpty else { return nil }
        var copy = group
        copy["hooks"] = ownedHandlers
        return copy
      }
    guard !ownedGroups.isEmpty else { continue }
    if hooks[event] != nil, !(hooks[event] is [[String: Any]]) {
      throw InstallerFailure.invalidHooks
    }
    var groups = hooks[event] as? [[String: Any]] ?? []
    groups.append(contentsOf: ownedGroups)
    hooks[event] = groups
  }
  value["hooks"] = hooks
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

func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
  var information = stat()
  return lstat(url.path, &information) == 0
}

func ownsHelper(shim helperShim: URL, installedHelper helper: URL) -> Bool {
  (try? fileManager.destinationOfSymbolicLink(atPath: helperShim.path)) == helper.path
}

func helperMatchesSource(_ helper: URL, source: URL) -> Bool {
  var information = stat()
  guard lstat(helper.path, &information) == 0,
    information.st_mode & S_IFMT == S_IFREG,
    information.st_uid == getuid()
  else { return false }
  return fileManager.contentsEqual(atPath: helper.path, andPath: source.path)
}

func isOwnedRegularFile(_ url: URL) -> Bool {
  var information = stat()
  return lstat(url.path, &information) == 0
    && information.st_mode & S_IFMT == S_IFREG
    && information.st_uid == getuid()
}

func validateHelperInstallation(from source: URL) throws {
  guard fileManager.isExecutableFile(atPath: source.path) else {
    throw InstallerFailure.helperMissing
  }
  let ownsShim = ownsHelper(shim: shim, installedHelper: installedHelper)
  if pathExistsWithoutFollowingSymlinks(shim), !ownsShim {
    throw InstallerFailure.shimConflict
  }
  if pathExistsWithoutFollowingSymlinks(installedHelper) {
    guard isOwnedRegularFile(installedHelper) else {
      throw InstallerFailure.helperConflict
    }
    if !ownsShim, !helperMatchesSource(installedHelper, source: source) {
      throw InstallerFailure.helperConflict
    }
  }
}

func installHelper(from source: URL) throws {
  try validateHelperInstallation(from: source)
  try installOwnedHelper(from: source, shim: shim, installedHelper: installedHelper)
}

func installOwnedHelper(
  from source: URL,
  shim helperShim: URL,
  installedHelper helper: URL
) throws {
  try fileManager.createDirectory(
    at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fileManager.createDirectory(
    at: helperShim.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fileManager.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: helper.deletingLastPathComponent().path)
  let temporary = helper.deletingLastPathComponent().appendingPathComponent(
    ".cowlick-hook-\(UUID().uuidString).tmp")
  defer { try? fileManager.removeItem(at: temporary) }
  try fileManager.copyItem(at: source, to: temporary)
  try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
  guard rename(temporary.path, helper.path) == 0 else {
    throw InstallerFailure.fileOperation(errno)
  }
  if fileManager.fileExists(atPath: helperShim.path) {
    return
  } else {
    try fileManager.createSymbolicLink(at: helperShim, withDestinationURL: helper)
  }
}

func validateHelperRemoval(shim helperShim: URL, installedHelper helper: URL) throws {
  let ownsShim = ownsHelper(shim: helperShim, installedHelper: helper)
  if pathExistsWithoutFollowingSymlinks(helperShim), !ownsShim {
    throw InstallerFailure.shimConflict
  }
  if pathExistsWithoutFollowingSymlinks(helper) {
    guard isOwnedRegularFile(helper), ownsShim else {
      throw InstallerFailure.helperConflict
    }
  }
}

func removeOwnedHelper(shim helperShim: URL, installedHelper helper: URL) throws {
  guard ownsHelper(shim: helperShim, installedHelper: helper) else { return }
  try fileManager.removeItem(at: helperShim)
  if pathExistsWithoutFollowingSymlinks(helper) {
    try fileManager.removeItem(at: helper)
  }
}

func snapshotIntegration(to directory: URL) throws {
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  if fileManager.fileExists(atPath: hooksURL.path) {
    try fileManager.copyItem(at: hooksURL, to: directory.appendingPathComponent("hooks.json"))
  }
  let helpers = [
    (shim, installedHelper, "cowlick-hook"),
    (legacyShim, legacyInstalledHelper, "notchrelay-hook"),
  ]
  for (helperShim, helper, name) in helpers
  where ownsHelper(shim: helperShim, installedHelper: helper) && isOwnedRegularFile(helper) {
    try fileManager.copyItem(at: helper, to: directory.appendingPathComponent(name))
  }
  try writePrivateFile(
    snapshotMarkerContents, to: directory.appendingPathComponent(snapshotMarkerName))
}

func restoreIntegration(from directory: URL) throws {
  var directoryInformation = stat()
  guard lstat(directory.path, &directoryInformation) == 0,
    directoryInformation.st_mode & S_IFMT == S_IFDIR,
    directoryInformation.st_uid == getuid()
  else { throw InstallerFailure.fileOperation(EINVAL) }

  let marker = directory.appendingPathComponent(snapshotMarkerName)
  var markerInformation = stat()
  guard lstat(marker.path, &markerInformation) == 0,
    markerInformation.st_mode & S_IFMT == S_IFREG,
    markerInformation.st_uid == getuid(),
    markerInformation.st_mode & 0o077 == 0,
    (try? Data(contentsOf: marker)) == snapshotMarkerContents
  else { throw InstallerFailure.invalidSnapshot }

  let hooksSnapshot = directory.appendingPathComponent("hooks.json")
  let helperSnapshot = directory.appendingPathComponent("cowlick-hook")
  let legacyHelperSnapshot = directory.appendingPathComponent("notchrelay-hook")
  let savedHooks =
    fileManager.fileExists(atPath: hooksSnapshot.path)
    ? try Data(contentsOf: hooksSnapshot) : nil
  for source in [helperSnapshot, legacyHelperSnapshot]
  where fileManager.fileExists(atPath: source.path)
    && !fileManager.isExecutableFile(atPath: source.path)
  {
    throw InstallerFailure.helperMissing
  }

  let hooksExist = fileManager.fileExists(atPath: hooksURL.path)
  let existing = hooksExist ? try Data(contentsOf: hooksURL) : Data("{}".utf8)
  let hookRestoration = Result { try restoringOwnedHandlers(in: existing, from: savedHooks) }

  try validateHelperRemoval(shim: shim, installedHelper: installedHelper)
  try validateHelperRemoval(shim: legacyShim, installedHelper: legacyInstalledHelper)
  try removeOwnedHelper(shim: shim, installedHelper: installedHelper)
  try removeOwnedHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
  if fileManager.fileExists(atPath: helperSnapshot.path) {
    try installOwnedHelper(from: helperSnapshot, shim: shim, installedHelper: installedHelper)
  }
  if fileManager.fileExists(atPath: legacyHelperSnapshot.path) {
    try installOwnedHelper(
      from: legacyHelperSnapshot, shim: legacyShim, installedHelper: legacyInstalledHelper)
  }

  switch hookRestoration {
  case .success(let restored):
    if restored != existing {
      try replaceHooks(with: restored, expected: hooksExist ? existing : nil)
    }
  case .failure(let error):
    if let stripped = try? restoringOwnedHandlers(in: existing, from: nil), stripped != existing {
      try replaceHooks(with: stripped, expected: hooksExist ? existing : nil)
    }
    throw error
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  switch try parseCommand(arguments) {
  case .help:
    print(InstallerFailure.usage.localizedDescription)
  case .install(let source, let snapshot):
    try withConfigurationLock {
      try validateHelperInstallation(from: source)
      try validateHelperRemoval(shim: legacyShim, installedHelper: legacyInstalledHelper)
      let existed = fileManager.fileExists(atPath: hooksURL.path)
      let existing = existed ? try Data(contentsOf: hooksURL) : Data("{}".utf8)
      let updated = try merge(existing)
      if let snapshot { try snapshotIntegration(to: snapshot) }
      do {
        try installHelper(from: source)
        if updated != existing {
          try replaceHooks(with: updated, expected: existed ? existing : nil)
        }
        try removeOwnedHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
      } catch {
        if let snapshot { try restoreIntegration(from: snapshot) }
        throw error
      }
    }
    print("Installed SessionStart, UserPromptSubmit, PermissionRequest, and Stop hooks.")
  case .remove:
    try withConfigurationLock {
      try validateHelperRemoval(shim: shim, installedHelper: installedHelper)
      try validateHelperRemoval(shim: legacyShim, installedHelper: legacyInstalledHelper)
      if fileManager.fileExists(atPath: hooksURL.path) {
        let existing = try Data(contentsOf: hooksURL)
        let updated = try remove(existing)
        if updated != existing { try replaceHooks(with: updated, expected: existing) }
      } else {
        print("No hooks file to update.")
      }
      try removeOwnedHelper(shim: shim, installedHelper: installedHelper)
      try removeOwnedHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
    }
    print("Removed only Cowlick and legacy NotchRelay hook handlers.")
  case .status:
    let existing =
      fileManager.fileExists(atPath: hooksURL.path)
      ? try Data(contentsOf: hooksURL) : Data("{}".utf8)
    let value = try root(from: existing)
    let installed = events.filter { containsCommand(value, event: $0) }
    print(
      installed.count == events.count
        ? "healthy"
        : "missing: \(events.filter { !installed.contains($0) }.joined(separator: ", "))")
  case .restore(let snapshot):
    try withConfigurationLock { try restoreIntegration(from: snapshot) }
    print("Restored the previous Cowlick integration state.")
  }
} catch {
  FileHandle.standardError.write(Data("install_hooks.swift: \(error.localizedDescription)\n".utf8))
  exit(1)
}
