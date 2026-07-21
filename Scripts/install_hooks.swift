#!/usr/bin/env swift
import Darwin
import Foundation

enum InstallerFailure: LocalizedError {
  case usage
  case invalidRoot
  case invalidHooks
  case unsafeHooksFile
  case helperMissing
  case shimConflict
  case helperConflict
  case configurationChanged
  case invalidSnapshot
  case unsafeOwnershipMarker
  case fileOperation(Int32)

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: install_hooks.swift <install --helper /path/to/cowlick-hook [--snapshot /path]|remove|status|restore --snapshot /path>"
    case .invalidRoot: "hooks.json must contain a JSON object."
    case .invalidHooks:
      "A supported hook event uses an unsupported group or handler container shape."
    case .unsafeHooksFile:
      "hooks.json must be a regular file owned by the current user, not a symbolic link."
    case .helperMissing: "The specified Cowlick helper does not exist."
    case .shimConflict: "~/.local/bin/cowlick-hook exists and is not Cowlick's symlink."
    case .helperConflict:
      "The installed helper path is not owned by Cowlick. Move it aside before changing the integration."
    case .configurationChanged:
      "hooks.json changed during installation; no configuration was overwritten. Try again."
    case .invalidSnapshot: "The Cowlick integration snapshot is incomplete or invalid."
    case .unsafeOwnershipMarker:
      "Cowlick's hooks-file ownership marker is missing required owner-only protections."
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
let events = [
  "SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop", "Stop",
]
let bridgeProtocolVersion = 2
let snapshotMarkerName = ".cowlick-integration-snapshot-v1"
let snapshotMarkerContents = Data("1\n".utf8)
let hooksAbsentSnapshotName = ".hooks-json-was-absent"
let hooksOwnershipMarkerName = ".hooks-json-created-by-cowlick"
let hooksOwnershipMarker = home.appendingPathComponent(
  "Library/Application Support/Cowlick/\(hooksOwnershipMarkerName)")

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

func isCurrentOwned(_ handler: [String: Any]) -> Bool {
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
  isCurrentOwned(handler) || isLegacy(handler)
}

func root(from data: Data) throws -> [String: Any] {
  guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw InstallerFailure.invalidRoot
  }
  try validateSupportedHookShapes(in: value)
  return value
}

func validateSupportedHookShapes(in root: [String: Any]) throws {
  guard root["hooks"] == nil || root["hooks"] is [String: Any] else {
    throw InstallerFailure.invalidHooks
  }
  guard let hooks = root["hooks"] as? [String: Any] else { return }
  for event in events where hooks[event] != nil {
    guard let groups = hooks[event] as? [Any] else { throw InstallerFailure.invalidHooks }
    for rawGroup in groups {
      guard let group = rawGroup as? [String: Any],
        let handlers = group["hooks"] as? [Any],
        handlers.allSatisfy({ $0 is [String: Any] })
      else { throw InstallerFailure.invalidHooks }
    }
  }
}

func readHooksDataIfPresent(at url: URL = hooksURL) throws -> Data? {
  var pathInformation = stat()
  guard lstat(url.path, &pathInformation) == 0 else {
    if errno == ENOENT { return nil }
    throw InstallerFailure.unsafeHooksFile
  }
  guard pathInformation.st_mode & S_IFMT == S_IFREG,
    pathInformation.st_uid == getuid()
  else { throw InstallerFailure.unsafeHooksFile }

  let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
  guard descriptor >= 0 else { throw InstallerFailure.unsafeHooksFile }
  defer { Darwin.close(descriptor) }
  var descriptorInformation = stat()
  guard fstat(descriptor, &descriptorInformation) == 0,
    descriptorInformation.st_mode & S_IFMT == S_IFREG,
    descriptorInformation.st_uid == getuid(),
    descriptorInformation.st_dev == pathInformation.st_dev,
    descriptorInformation.st_ino == pathInformation.st_ino
  else { throw InstallerFailure.unsafeHooksFile }
  return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
}

func timeout(for event: String) -> Int {
  event == "PermissionRequest" ? 75 : 5
}

func isCanonical(_ handler: [String: Any], event: String) -> Bool {
  guard handler["type"] as? String == "command",
    handlerCommand(handler) == normalized(hookCommand),
    handler["timeout"] as? Int == timeout(for: event),
    handler["statusMessage"] as? String == "Cowlick",
    let marker = handler["cowlick"] as? [String: Any],
    marker["product"] as? String == "Cowlick",
    marker["protocol"] as? Int == bridgeProtocolVersion
  else { return false }
  return true
}

func handlerCount(
  _ root: [String: Any], event: String, where matches: ([String: Any]) -> Bool
) -> Int {
  guard let hooks = root["hooks"] as? [String: Any],
    let groups = hooks[event] as? [[String: Any]]
  else { return 0 }
  return groups.reduce(into: 0) { count, group in
    count += (group["hooks"] as? [[String: Any]])?.count(where: matches) ?? 0
  }
}

func containsCanonicalHandler(_ root: [String: Any], event: String) -> Bool {
  let canonicalCount = handlerCount(root, event: event) { isCanonical($0, event: event) }
  let ownedCount = handlerCount(root, event: event, where: isCurrentOwned)
  return canonicalCount == 1 && ownedCount == 1
}

func encoded(_ root: [String: Any]) throws -> Data {
  let data =
    try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    + Data([0x0A])
  _ = try JSONSerialization.jsonObject(with: data)
  return data
}

func containsOnlyEmptyHookConfiguration(_ data: Data) throws -> Bool {
  var value = try root(from: data)
  if let hooks = value["hooks"] as? [String: Any], hooks.isEmpty {
    value.removeValue(forKey: "hooks")
  }
  return value.isEmpty
}

func removingHandlers(
  from original: [String: Any],
  events selectedEvents: [String] = events,
  where shouldRemove: ([String: Any]) -> Bool
) -> [String: Any] {
  var value = original
  guard var hooks = value["hooks"] as? [String: Any] else { return value }
  for event in selectedEvents {
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
  for event in events {
    let canonicalCount = handlerCount(value, event: event) { isCanonical($0, event: event) }
    let ownedCount = handlerCount(value, event: event, where: isCurrentOwned)
    guard canonicalCount != 1 || ownedCount != 1 else { continue }

    value = removingHandlers(from: value, events: [event], where: isCurrentOwned)
    var hooks = value["hooks"] as? [String: Any] ?? [:]
    var groups = hooks[event] as? [[String: Any]] ?? []
    groups.append([
      "hooks": [
        [
          "type": "command",
          "command": hookCommand,
          "timeout": timeout(for: event),
          "statusMessage": "Cowlick",
          "cowlick": ["product": "Cowlick", "protocol": bridgeProtocolVersion],
        ]
      ]
    ])
    hooks[event] = groups
    value["hooks"] = hooks
  }
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

func privateMarkerExists(at url: URL) throws -> Bool {
  var information = stat()
  guard lstat(url.path, &information) == 0 else {
    if errno == ENOENT { return false }
    throw InstallerFailure.unsafeOwnershipMarker
  }
  guard information.st_mode & S_IFMT == S_IFREG,
    information.st_uid == getuid(),
    information.st_mode & 0o077 == 0,
    (try? Data(contentsOf: url)) == snapshotMarkerContents
  else { throw InstallerFailure.unsafeOwnershipMarker }
  return true
}

func removePrivateMarkerIfPresent(at url: URL) throws {
  guard try privateMarkerExists(at: url) else { return }
  guard unlink(url.path) == 0 else { throw InstallerFailure.fileOperation(errno) }
}

func removeHooksFile(expected: Data) throws {
  guard try readHooksDataIfPresent() == expected else {
    throw InstallerFailure.configurationChanged
  }
  guard unlink(hooksURL.path) == 0 else { throw InstallerFailure.fileOperation(errno) }
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
    guard try readHooksDataIfPresent() == original else {
      throw InstallerFailure.configurationChanged
    }
  } else if try readHooksDataIfPresent() != nil {
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
  if let hooksData = try readHooksDataIfPresent() {
    try writePrivateFile(hooksData, to: directory.appendingPathComponent("hooks.json"))
  } else {
    try writePrivateFile(
      snapshotMarkerContents, to: directory.appendingPathComponent(hooksAbsentSnapshotName))
  }
  if try privateMarkerExists(at: hooksOwnershipMarker) {
    try writePrivateFile(
      snapshotMarkerContents, to: directory.appendingPathComponent(hooksOwnershipMarkerName))
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
  let hooksAbsentSnapshot = directory.appendingPathComponent(hooksAbsentSnapshotName)
  let ownershipSnapshot = directory.appendingPathComponent(hooksOwnershipMarkerName)
  let helperSnapshot = directory.appendingPathComponent("cowlick-hook")
  let legacyHelperSnapshot = directory.appendingPathComponent("notchrelay-hook")
  let savedHooks = try readHooksDataIfPresent(at: hooksSnapshot)
  let hooksWereAbsent = try privateMarkerExists(at: hooksAbsentSnapshot)
  guard (savedHooks != nil) != hooksWereAbsent else { throw InstallerFailure.invalidSnapshot }
  let ownershipMarkerWasPresent = try privateMarkerExists(at: ownershipSnapshot)
  for source in [helperSnapshot, legacyHelperSnapshot]
  where fileManager.fileExists(atPath: source.path)
    && !fileManager.isExecutableFile(atPath: source.path)
  {
    throw InstallerFailure.helperMissing
  }

  let existingData = try readHooksDataIfPresent()
  let hooksExist = existingData != nil
  let existing = existingData ?? Data("{}".utf8)
  let restoredHooks = try restoringOwnedHandlers(in: existing, from: savedHooks)

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

  if hooksWereAbsent, hooksExist {
    if try containsOnlyEmptyHookConfiguration(restoredHooks) {
      try removeHooksFile(expected: existing)
    } else if restoredHooks != existing {
      try replaceHooks(with: restoredHooks, expected: existing)
    }
  } else if !hooksWereAbsent, restoredHooks != existing {
    try replaceHooks(with: restoredHooks, expected: hooksExist ? existing : nil)
  }

  try removePrivateMarkerIfPresent(at: hooksOwnershipMarker)
  if ownershipMarkerWasPresent {
    try fileManager.createDirectory(
      at: hooksOwnershipMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePrivateFile(snapshotMarkerContents, to: hooksOwnershipMarker)
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
      let existingData = try readHooksDataIfPresent()
      let existed = existingData != nil
      let existing = existingData ?? Data("{}".utf8)
      let updated = try merge(existing)
      if let snapshot { try snapshotIntegration(to: snapshot) }
      do {
        try installHelper(from: source)
        if updated != existing {
          try replaceHooks(with: updated, expected: existed ? existing : nil)
        }
        if !existed, !(try privateMarkerExists(at: hooksOwnershipMarker)) {
          try fileManager.createDirectory(
            at: hooksOwnershipMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
          try writePrivateFile(snapshotMarkerContents, to: hooksOwnershipMarker)
        }
        try removeOwnedHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
      } catch {
        if let snapshot { try restoreIntegration(from: snapshot) }
        throw error
      }
    }
    print("Installed Codex session, subagent, approval, and completion hooks.")
  case .remove:
    try withConfigurationLock {
      try validateHelperRemoval(shim: shim, installedHelper: installedHelper)
      try validateHelperRemoval(shim: legacyShim, installedHelper: legacyInstalledHelper)
      let ownsHooksFile = try privateMarkerExists(at: hooksOwnershipMarker)
      if let existing = try readHooksDataIfPresent() {
        let updated = try remove(existing)
        if ownsHooksFile, try containsOnlyEmptyHookConfiguration(updated) {
          try removeHooksFile(expected: existing)
        } else if updated != existing {
          try replaceHooks(with: updated, expected: existing)
        }
      } else {
        print("No hooks file to update.")
      }
      try removePrivateMarkerIfPresent(at: hooksOwnershipMarker)
      try removeOwnedHelper(shim: shim, installedHelper: installedHelper)
      try removeOwnedHelper(shim: legacyShim, installedHelper: legacyInstalledHelper)
    }
    print("Removed only Cowlick and legacy NotchRelay hook handlers.")
  case .status:
    let existing = try readHooksDataIfPresent() ?? Data("{}".utf8)
    let value = try root(from: existing)
    let installed = events.filter { containsCanonicalHandler(value, event: $0) }
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
