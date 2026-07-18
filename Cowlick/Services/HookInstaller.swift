import Darwin
import Foundation

struct HookInstallationStatus: Equatable, Sendable {
  let installedEvents: Set<String>
  let helperInstalled: Bool
  let configurationExists: Bool
  let error: String?

  var isHealthy: Bool {
    installedEvents == Set(HookInstaller.supportedEvents) && helperInstalled && error == nil
  }

  var summary: String {
    if let error { return error }
    if isHealthy { return "Installed" }
    if installedEvents.isEmpty { return "Codex hooks are not installed" }
    return "Codex integration needs repair"
  }
}

enum HookInstallerError: LocalizedError {
  case invalidRoot
  case invalidHooksObject
  case bundledHelperMissing
  case shimConflict
  case validationFailed
  case atomicWriteFailed(Int32)
  case configurationChanged

  var errorDescription: String? {
    switch self {
    case .invalidRoot: "hooks.json must contain a JSON object at its root."
    case .invalidHooksObject: "The existing hooks field is not a JSON object."
    case .bundledHelperMissing: "The bundled Cowlick hook helper is missing."
    case .shimConflict:
      "~/.local/bin/cowlick-hook already exists and is not the Cowlick symlink. Move it aside before installing."
    case .validationFailed: "The merged hook configuration did not pass JSON validation."
    case .atomicWriteFailed(let code):
      "The hook configuration could not be replaced atomically (errno \(code))."
    case .configurationChanged:
      "hooks.json changed during installation. No configuration was overwritten; try again."
    }
  }
}

struct HookInstaller {
  static let supportedEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"]

  private let fileManager: FileManager
  private let homeDirectory: URL
  let hooksURL: URL
  let shimURL: URL
  let installedHelperURL: URL
  let legacyShimURL: URL
  let legacyInstalledHelperURL: URL

  init(
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
    hooksURL = homeDirectory.appendingPathComponent(".codex/hooks.json")
    shimURL = homeDirectory.appendingPathComponent(".local/bin/cowlick-hook")
    installedHelperURL = homeDirectory.appendingPathComponent(
      "Library/Application Support/Cowlick/bin/cowlick-hook")
    legacyShimURL = homeDirectory.appendingPathComponent(".local/bin/notchrelay-hook")
    legacyInstalledHelperURL = homeDirectory.appendingPathComponent(
      "Library/Application Support/NotchRelay/bin/notchrelay-hook")
  }

  func status() -> HookInstallationStatus {
    guard fileManager.fileExists(atPath: hooksURL.path) else {
      return HookInstallationStatus(
        installedEvents: [], helperInstalled: helperExists, configurationExists: false, error: nil)
    }
    do {
      let root = try Self.decodeRoot(Data(contentsOf: hooksURL))
      let events = Set(
        Self.supportedEvents.filter {
          Self.containsEquivalentCommand(
            in: root, event: $0, command: Self.hookCommand(for: shimURL))
        })
      return HookInstallationStatus(
        installedEvents: events, helperInstalled: helperExists, configurationExists: true,
        error: nil)
    } catch {
      return HookInstallationStatus(
        installedEvents: [], helperInstalled: helperExists, configurationExists: true,
        error: error.localizedDescription)
    }
  }

  func installOrRepair() throws {
    try installBundledHelper()
    try fileManager.createDirectory(
      at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try withConfigurationLock {
      let existed = fileManager.fileExists(atPath: hooksURL.path)
      let originalData = existed ? try Data(contentsOf: hooksURL) : Data("{}".utf8)
      let mergedData = try Self.merging(
        originalData,
        command: Self.hookCommand(for: shimURL),
        legacyCommands: [Self.hookCommand(for: legacyShimURL)])

      if existed, mergedData != originalData { try writePrivateBackup(originalData) }
      if !existed || mergedData != originalData {
        try atomicWrite(mergedData, to: hooksURL, expectedOriginal: existed ? originalData : nil)
      }
    }
    try removeLegacyInstalledHelper()
  }

  func removeHooks() throws {
    try fileManager.createDirectory(
      at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try withConfigurationLock {
      guard fileManager.fileExists(atPath: hooksURL.path) else { return }
      let originalData = try Data(contentsOf: hooksURL)
      let updatedData = try Self.removing(
        originalData,
        command: Self.hookCommand(for: shimURL),
        legacyCommands: [Self.hookCommand(for: legacyShimURL)])
      guard updatedData != originalData else { return }
      try writePrivateBackup(originalData)
      try atomicWrite(updatedData, to: hooksURL, expectedOriginal: originalData)
    }
  }

  func removeInstalledHelper() throws {
    try removeHelper(shim: shimURL, installedHelper: installedHelperURL)
    try removeLegacyInstalledHelper()
  }

  static func merging(
    _ data: Data,
    command: String,
    legacyCommands: Set<String> = []
  ) throws -> Data {
    var root = try decodeRoot(data)
    root = removeHandlers(in: root) { handler in
      isLegacyHandler(handler, expectedCommands: legacyCommands)
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    if root["hooks"] != nil, !(root["hooks"] is [String: Any]) {
      throw HookInstallerError.invalidHooksObject
    }

    for event in supportedEvents
    where !containsEquivalentCommand(in: root, event: event, command: command) {
      var groups = hooks[event] as? [[String: Any]] ?? []
      let timeout = event == "PermissionRequest" ? 75 : 5
      groups.append([
        "hooks": [
          [
            "type": "command",
            "command": command,
            "timeout": timeout,
            "statusMessage": "Cowlick",
            "cowlick": ["product": "Cowlick", "protocol": 1],
          ]
        ]
      ])
      hooks[event] = groups
    }
    root["hooks"] = hooks
    return try encodeAndValidate(root)
  }

  static func removing(
    _ data: Data,
    command: String? = nil,
    legacyCommands: Set<String> = []
  ) throws -> Data {
    var root = try decodeRoot(data)
    var expectedCommands = legacyCommands
    if let command { expectedCommands.insert(command) }
    root = removeHandlers(in: root) { handler in
      isOwnedHandler(handler, expectedCommands: expectedCommands)
    }
    return try encodeAndValidate(root)
  }

  private var helperExists: Bool {
    guard fileManager.isExecutableFile(atPath: installedHelperURL.path),
      fileManager.fileExists(atPath: shimURL.path)
    else { return false }
    return (try? fileManager.destinationOfSymbolicLink(atPath: shimURL.path))
      == installedHelperURL.path
  }

  private func installBundledHelper() throws {
    let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cowlick-hook")
    guard fileManager.fileExists(atPath: bundled.path) else {
      throw HookInstallerError.bundledHelperMissing
    }
    if fileManager.fileExists(atPath: shimURL.path),
      (try? fileManager.destinationOfSymbolicLink(atPath: shimURL.path))
        != installedHelperURL.path
    {
      throw HookInstallerError.shimConflict
    }
    try fileManager.createDirectory(
      at: installedHelperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: installedHelperURL.deletingLastPathComponent().path)

    let temporaryHelper = installedHelperURL.deletingLastPathComponent()
      .appendingPathComponent(".cowlick-hook-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporaryHelper) }
    try fileManager.copyItem(at: bundled, to: temporaryHelper)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryHelper.path)
    guard rename(temporaryHelper.path, installedHelperURL.path) == 0 else {
      throw HookInstallerError.atomicWriteFailed(errno)
    }

    if fileManager.fileExists(atPath: shimURL.path) {
      return
    }
    try fileManager.createSymbolicLink(at: shimURL, withDestinationURL: installedHelperURL)
  }

  private func atomicWrite(_ data: Data, to destination: URL, expectedOriginal: Data?) throws {
    _ = try Self.decodeRoot(data)
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".hooks.json.cowlick-\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw HookInstallerError.atomicWriteFailed(errno) }
    let writeSucceeded = data.withUnsafeBytes { bytes -> Bool in
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
    guard writeSucceeded else {
      unlink(temporary.path)
      throw HookInstallerError.atomicWriteFailed(errno)
    }
    if let expectedOriginal {
      guard (try? Data(contentsOf: destination)) == expectedOriginal else {
        unlink(temporary.path)
        throw HookInstallerError.configurationChanged
      }
    } else if fileManager.fileExists(atPath: destination.path) {
      unlink(temporary.path)
      throw HookInstallerError.configurationChanged
    }
    guard rename(temporary.path, destination.path) == 0 else {
      let code = errno
      unlink(temporary.path)
      throw HookInstallerError.atomicWriteFailed(code)
    }
  }

  private static func decodeRoot(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HookInstallerError.invalidRoot
    }
    return root
  }

  private static func encodeAndValidate(_ root: [String: Any]) throws -> Data {
    let data =
      try JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      + Data([0x0A])
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      throw HookInstallerError.validationFailed
    }
    return data
  }

  private static func containsEquivalentCommand(
    in root: [String: Any], event: String, command: String
  ) -> Bool {
    guard let hooks = root["hooks"] as? [String: Any],
      let groups = hooks[event] as? [[String: Any]]
    else { return false }
    return groups.contains { group in
      (group["hooks"] as? [[String: Any]])?.contains { handler in
        isCurrentHandler(handler, expectedCommand: command)
      } == true
    }
  }

  private static func removeHandlers(
    in root: [String: Any],
    where shouldRemove: ([String: Any]) -> Bool
  ) -> [String: Any] {
    var updatedRoot = root
    guard var hooks = updatedRoot["hooks"] as? [String: Any] else { return root }

    for event in supportedEvents {
      guard let groups = hooks[event] as? [[String: Any]] else { continue }
      let filteredGroups: [[String: Any]] = groups.compactMap { group in
        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
        let remaining = handlers.filter { !shouldRemove($0) }
        guard !remaining.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = remaining
        return updated
      }
      if filteredGroups.isEmpty {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = filteredGroups
      }
    }
    updatedRoot["hooks"] = hooks
    return updatedRoot
  }

  private static func isCurrentHandler(
    _ handler: [String: Any], expectedCommand: String
  ) -> Bool {
    if let marker = handler["cowlick"] as? [String: Any],
      marker["product"] as? String == "Cowlick"
    {
      return true
    }
    return command(in: handler) == normalized(expectedCommand)
  }

  private static func isLegacyHandler(
    _ handler: [String: Any], expectedCommands: Set<String>
  ) -> Bool {
    if let marker = handler["notchRelay"] as? [String: Any],
      marker["product"] as? String == "NotchRelay"
    {
      return true
    }
    guard let actual = command(in: handler) else { return false }
    return Set(expectedCommands.map(normalized)).contains(actual)
  }

  private static func isOwnedHandler(
    _ handler: [String: Any], expectedCommands: Set<String>
  ) -> Bool {
    if let marker = handler["cowlick"] as? [String: Any],
      marker["product"] as? String == "Cowlick"
    {
      return true
    }
    if isLegacyHandler(handler, expectedCommands: expectedCommands) { return true }
    guard let actual = command(in: handler) else { return false }
    return Set(expectedCommands.map(normalized)).contains(actual)
  }

  private static func command(in handler: [String: Any]) -> String? {
    (handler["command"] as? String).map(normalized)
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func hookCommand(for shimURL: URL) -> String {
    "\(shellQuote(shimURL.path)) hook"
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func withConfigurationLock<Result>(_ body: () throws -> Result) throws -> Result {
    let lockURL = hooksURL.deletingLastPathComponent()
      .appendingPathComponent(".hooks.json.cowlick.lock")
    let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, 0o600)
    guard descriptor >= 0 else { throw HookInstallerError.atomicWriteFailed(errno) }
    guard flock(descriptor, LOCK_EX) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw HookInstallerError.atomicWriteFailed(code)
    }
    defer {
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
    return try body()
  }

  private func writePrivateBackup(_ data: Data) throws {
    let backupURL = hooksURL.deletingLastPathComponent()
      .appendingPathComponent(
        "hooks.json.backup-\(Self.timestamp())-\(UUID().uuidString.prefix(8))")
    let descriptor = Darwin.open(backupURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw HookInstallerError.atomicWriteFailed(errno) }
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
      unlink(backupURL.path)
      throw HookInstallerError.atomicWriteFailed(errno)
    }
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private func removeLegacyInstalledHelper() throws {
    try removeHelper(shim: legacyShimURL, installedHelper: legacyInstalledHelperURL)
  }

  private func removeHelper(shim: URL, installedHelper: URL) throws {
    if (try? fileManager.destinationOfSymbolicLink(atPath: shim.path)) == installedHelper.path {
      try fileManager.removeItem(at: shim)
    }
    if fileManager.fileExists(atPath: installedHelper.path) {
      try fileManager.removeItem(at: installedHelper)
    }
  }
}
