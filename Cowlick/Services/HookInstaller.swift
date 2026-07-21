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
  case unsafeHooksFile
  case bundledHelperMissing
  case installedHelperUnavailable
  case automaticHelperRefreshUnavailable
  case integrationMutationUnavailableDuringUITesting
  case shimConflict
  case helperConflict
  case helperReplacementFailed(Int32)
  case validationFailed
  case atomicWriteFailed(Int32)
  case configurationChanged

  var errorDescription: String? {
    switch self {
    case .invalidRoot: "hooks.json must contain a JSON object at its root."
    case .invalidHooksObject:
      "A supported hook event uses an unsupported group or handler container shape."
    case .unsafeHooksFile:
      "hooks.json must be a regular file owned by the current user, not a symbolic link."
    case .bundledHelperMissing: "The bundled Cowlick hook helper is missing."
    case .installedHelperUnavailable:
      "The installed Cowlick helper is unavailable. Repair Codex integration first."
    case .automaticHelperRefreshUnavailable:
      "Run this self-test from Cowlick installed in /Applications or ~/Applications."
    case .integrationMutationUnavailableDuringUITesting:
      "Codex integration cannot be changed during Cowlick UI testing."
    case .shimConflict:
      "An integration helper shim already exists and is not Cowlick's owned symlink. Move it aside before changing the integration."
    case .helperConflict:
      "The installed helper path is not the bundled Cowlick helper. Move it aside before changing the integration."
    case .helperReplacementFailed(let code):
      "The installed helper could not be replaced atomically (errno \(code))."
    case .validationFailed: "The merged hook configuration did not pass JSON validation."
    case .atomicWriteFailed(let code):
      "The hook configuration could not be replaced atomically (errno \(code))."
    case .configurationChanged:
      "hooks.json changed during installation. No configuration was overwritten; try again."
    }
  }
}

struct HookInstaller {
  static let supportedEvents = [
    "SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop",
    "Stop",
  ]

  private let fileManager: FileManager
  private let homeDirectory: URL
  private let bundledHelperURL: URL
  private let allowsAutomaticHelperRefresh: Bool
  private let allowsIntegrationMutation: Bool
  let hooksURL: URL
  let shimURL: URL
  let installedHelperURL: URL
  let legacyShimURL: URL
  let legacyInstalledHelperURL: URL

  init(
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    applicationBundleURL: URL? = nil,
    bundledHelperURL: URL? = nil,
    arguments: [String]? = nil
  ) {
    let applicationBundleURL = applicationBundleURL ?? Bundle.main.bundleURL
    let arguments = arguments ?? CommandLine.arguments
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
    self.bundledHelperURL =
      bundledHelperURL
      ?? applicationBundleURL.appendingPathComponent("Contents/Helpers/cowlick-hook")
    allowsAutomaticHelperRefresh = Self.allowsAutomaticHelperRefresh(
      applicationBundleURL: applicationBundleURL,
      homeDirectory: homeDirectory,
      arguments: arguments)
    allowsIntegrationMutation = !arguments.contains("--ui-testing")
    hooksURL = homeDirectory.appendingPathComponent(".codex/hooks.json")
    shimURL = homeDirectory.appendingPathComponent(".local/bin/cowlick-hook")
    installedHelperURL = homeDirectory.appendingPathComponent(
      "Library/Application Support/Cowlick/bin/cowlick-hook")
    legacyShimURL = homeDirectory.appendingPathComponent(".local/bin/notchrelay-hook")
    legacyInstalledHelperURL = homeDirectory.appendingPathComponent(
      "Library/Application Support/NotchRelay/bin/notchrelay-hook")
  }

  func status() -> HookInstallationStatus {
    do {
      guard let data = try readHooksDataIfPresent() else {
        return HookInstallationStatus(
          installedEvents: [], helperInstalled: helperExists, configurationExists: false,
          error: nil)
      }
      let root = try Self.decodeRoot(data)
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
    guard allowsIntegrationMutation else {
      throw HookInstallerError.integrationMutationUnavailableDuringUITesting
    }
    try withIntegrationLock {
      try validateLegacyHelperRemoval()
      let existingData = try readHooksDataIfPresent()
      let existed = existingData != nil
      let originalData = existingData ?? Data("{}".utf8)
      let mergedData = try Self.merging(
        originalData,
        command: Self.hookCommand(for: shimURL),
        legacyCommands: [Self.hookCommand(for: legacyShimURL)])

      try installBundledHelper()
      if existed, mergedData != originalData { try writePrivateBackup(originalData) }
      if !existed || mergedData != originalData {
        try atomicWrite(mergedData, to: hooksURL, expectedOriginal: existed ? originalData : nil)
      }
      try removeLegacyInstalledHelper()
    }
  }

  func removeHooks() throws {
    guard allowsIntegrationMutation else {
      throw HookInstallerError.integrationMutationUnavailableDuringUITesting
    }
    try withIntegrationLock { try removeHooksLocked() }
  }

  func removeIntegration() throws {
    guard allowsIntegrationMutation else {
      throw HookInstallerError.integrationMutationUnavailableDuringUITesting
    }
    try withIntegrationLock {
      try validateIntegrationRemoval()
      try removeHooksLocked()
      try validateIntegrationRemoval()
      if hasOwnedShim { try fileManager.removeItem(at: shimURL) }
      if pathExistsWithoutFollowingSymlinks(installedHelperURL) {
        try fileManager.removeItem(at: installedHelperURL)
      }
      try removeLegacyInstalledHelper()
    }
  }

  func refreshInstalledHelperIfNeeded() throws {
    guard allowsAutomaticHelperRefresh, hasOwnedShim else { return }
    try withIntegrationLock {
      guard hasOwnedShim else { return }
      try installBundledHelper()
    }
  }

  @discardableResult
  func repairExistingIntegrationIfNeeded(intentionallyRemoved: Bool) throws -> Bool {
    guard allowsAutomaticHelperRefresh, !intentionallyRemoved else { return false }
    let current = status()
    guard !current.isHealthy,
      current.helperInstalled || !current.installedEvents.isEmpty
    else { return false }
    try installOrRepair()
    return true
  }

  func currentInstalledHelperURL() throws -> URL {
    guard allowsAutomaticHelperRefresh else {
      throw HookInstallerError.automaticHelperRefreshUnavailable
    }
    return try withIntegrationLock {
      guard hasOwnedShim else { throw HookInstallerError.installedHelperUnavailable }
      try installBundledHelper()
      guard helperExists else { throw HookInstallerError.installedHelperUnavailable }
      return installedHelperURL
    }
  }

  func installedHelperURLForExplicitSelfTest() throws -> URL {
    guard allowsIntegrationMutation else {
      throw HookInstallerError.integrationMutationUnavailableDuringUITesting
    }
    guard helperExists else { throw HookInstallerError.installedHelperUnavailable }
    return installedHelperURL
  }

  static func allowsAutomaticHelperRefresh(
    applicationBundleURL: URL,
    homeDirectory: URL,
    arguments: [String]
  ) -> Bool {
    guard !arguments.contains("--ui-testing") else { return false }
    let bundle = applicationBundleURL.standardizedFileURL
    let recognizedLocations = [
      URL(fileURLWithPath: "/Applications/Cowlick.app", isDirectory: true),
      homeDirectory.appendingPathComponent("Applications/Cowlick.app", isDirectory: true),
    ]
    return recognizedLocations.contains { location in
      let recognized = location.standardizedFileURL
      guard bundle.path == recognized.path,
        bundle.resolvingSymlinksInPath().path == recognized.path
      else { return false }
      var information = stat()
      if lstat(bundle.path, &information) == 0,
        information.st_mode & S_IFMT == S_IFLNK
      {
        return false
      }
      return true
    }
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
    if root["hooks"] != nil, !(root["hooks"] is [String: Any]) {
      throw HookInstallerError.invalidHooksObject
    }

    for event in supportedEvents {
      let canonicalCount = handlerCount(in: root, event: event) {
        isCanonicalHandler($0, event: event, expectedCommand: command)
      }
      let ownedCount = handlerCount(in: root, event: event) {
        isCurrentOwnedHandler($0, expectedCommand: command)
      }
      guard canonicalCount != 1 || ownedCount != 1 else { continue }

      root = removeHandlers(in: root, events: [event]) { handler in
        isCurrentOwnedHandler(handler, expectedCommand: command)
      }
      var hooks = root["hooks"] as? [String: Any] ?? [:]
      var groups = hooks[event] as? [[String: Any]] ?? []
      groups.append([
        "hooks": [canonicalHandler(event: event, command: command)]
      ])
      hooks[event] = groups
      root["hooks"] = hooks
    }
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
    guard installedHelperMatchesBundle,
      fileManager.isExecutableFile(atPath: installedHelperURL.path),
      hasOwnedShim
    else { return false }
    return true
  }

  private var installedHelperMatchesBundle: Bool {
    guard installedHelperIsRegularFile,
      fileManager.fileExists(atPath: bundledHelperURL.path)
    else { return false }
    return fileManager.contentsEqual(
      atPath: installedHelperURL.path, andPath: bundledHelperURL.path)
  }

  private var installedHelperIsRegularFile: Bool {
    var information = stat()
    return lstat(installedHelperURL.path, &information) == 0
      && information.st_mode & S_IFMT == S_IFREG
      && information.st_uid == getuid()
  }

  private var hasOwnedShim: Bool {
    hasOwnedShim(shim: shimURL, installedHelper: installedHelperURL)
  }

  private func validateIntegrationRemoval() throws {
    if pathExistsWithoutFollowingSymlinks(shimURL), !hasOwnedShim {
      throw HookInstallerError.shimConflict
    }
    if pathExistsWithoutFollowingSymlinks(installedHelperURL) {
      guard installedHelperMatchesBundle else {
        throw HookInstallerError.helperConflict
      }
    }
    try validateLegacyHelperRemoval()
  }

  private func validateLegacyHelperRemoval() throws {
    let ownsShim = hasOwnedShim(shim: legacyShimURL, installedHelper: legacyInstalledHelperURL)
    if pathExistsWithoutFollowingSymlinks(legacyShimURL), !ownsShim {
      throw HookInstallerError.shimConflict
    }
    if pathExistsWithoutFollowingSymlinks(legacyInstalledHelperURL), !ownsShim {
      throw HookInstallerError.helperConflict
    }
  }

  private func hasOwnedShim(shim: URL, installedHelper: URL) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: shim.path)) == installedHelper.path
  }

  private func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
    var information = stat()
    return lstat(url.path, &information) == 0
  }

  private func installBundledHelper() throws {
    guard fileManager.fileExists(atPath: bundledHelperURL.path) else {
      throw HookInstallerError.bundledHelperMissing
    }
    let shimDestination = try? fileManager.destinationOfSymbolicLink(atPath: shimURL.path)
    if fileManager.fileExists(atPath: shimURL.path) || shimDestination != nil,
      shimDestination != installedHelperURL.path
    {
      throw HookInstallerError.shimConflict
    }
    if pathExistsWithoutFollowingSymlinks(installedHelperURL), !hasOwnedShim,
      !installedHelperMatchesBundle
    {
      throw HookInstallerError.helperConflict
    }
    try fileManager.createDirectory(
      at: installedHelperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: installedHelperURL.deletingLastPathComponent().path)

    if !installedHelperIsRegularFile
      || !fileManager.isExecutableFile(atPath: installedHelperURL.path)
      || !fileManager.contentsEqual(
        atPath: installedHelperURL.path,
        andPath: bundledHelperURL.path)
    {
      let temporaryHelper = installedHelperURL.deletingLastPathComponent()
        .appendingPathComponent(".cowlick-hook-\(UUID().uuidString).tmp")
      defer { try? fileManager.removeItem(at: temporaryHelper) }
      try fileManager.copyItem(at: bundledHelperURL, to: temporaryHelper)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryHelper.path)
      guard rename(temporaryHelper.path, installedHelperURL.path) == 0 else {
        throw HookInstallerError.helperReplacementFailed(errno)
      }
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
      guard try readHooksDataIfPresent() == expectedOriginal else {
        unlink(temporary.path)
        throw HookInstallerError.configurationChanged
      }
    } else if try readHooksDataIfPresent() != nil {
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
    try validateSupportedHookShapes(in: root)
    return root
  }

  private static func validateSupportedHookShapes(in root: [String: Any]) throws {
    guard root["hooks"] == nil || root["hooks"] is [String: Any] else {
      throw HookInstallerError.invalidHooksObject
    }
    guard let hooks = root["hooks"] as? [String: Any] else { return }
    for event in supportedEvents where hooks[event] != nil {
      guard let groups = hooks[event] as? [Any] else {
        throw HookInstallerError.invalidHooksObject
      }
      for rawGroup in groups {
        guard let group = rawGroup as? [String: Any],
          let handlers = group["hooks"] as? [Any],
          handlers.allSatisfy({ $0 is [String: Any] })
        else { throw HookInstallerError.invalidHooksObject }
      }
    }
  }

  private static func encodeAndValidate(_ root: [String: Any]) throws -> Data {
    let data =
      try JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      + Data([0x0A])
    do { _ = try decodeRoot(data) } catch { throw HookInstallerError.validationFailed }
    return data
  }

  private static func containsEquivalentCommand(
    in root: [String: Any], event: String, command: String
  ) -> Bool {
    let canonicalCount = handlerCount(in: root, event: event) {
      isCanonicalHandler($0, event: event, expectedCommand: command)
    }
    let ownedCount = handlerCount(in: root, event: event) {
      isCurrentOwnedHandler($0, expectedCommand: command)
    }
    return canonicalCount == 1 && ownedCount == 1
  }

  private static func handlerCount(
    in root: [String: Any],
    event: String,
    where matches: ([String: Any]) -> Bool
  ) -> Int {
    guard let hooks = root["hooks"] as? [String: Any],
      let groups = hooks[event] as? [[String: Any]]
    else { return 0 }
    return groups.reduce(into: 0) { count, group in
      count += (group["hooks"] as? [[String: Any]])?.count(where: matches) ?? 0
    }
  }

  private static func removeHandlers(
    in root: [String: Any],
    events: [String] = supportedEvents,
    where shouldRemove: ([String: Any]) -> Bool
  ) -> [String: Any] {
    var updatedRoot = root
    guard var hooks = updatedRoot["hooks"] as? [String: Any] else { return root }

    for event in events {
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

  private static func isCanonicalHandler(
    _ handler: [String: Any], event: String, expectedCommand: String
  ) -> Bool {
    guard handler["type"] as? String == "command",
      command(in: handler) == normalized(expectedCommand),
      handler["timeout"] as? Int == timeout(for: event),
      handler["statusMessage"] as? String == "Cowlick",
      let marker = handler["cowlick"] as? [String: Any],
      marker["product"] as? String == "Cowlick",
      marker["protocol"] as? Int == ProductVersion.bridgeProtocol
    else { return false }
    return true
  }

  private static func isCurrentOwnedHandler(
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
    if expectedCommands.contains(where: {
      isCurrentOwnedHandler(handler, expectedCommand: $0)
    }) {
      return true
    }
    if isLegacyHandler(handler, expectedCommands: expectedCommands) { return true }
    guard let actual = command(in: handler) else { return false }
    return Set(expectedCommands.map(normalized)).contains(actual)
  }

  private static func canonicalHandler(event: String, command: String) -> [String: Any] {
    [
      "type": "command",
      "command": command,
      "timeout": timeout(for: event),
      "statusMessage": "Cowlick",
      "cowlick": ["product": "Cowlick", "protocol": ProductVersion.bridgeProtocol],
    ]
  }

  private static func timeout(for event: String) -> Int {
    event == "PermissionRequest" ? 75 : 5
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

  private func withIntegrationLock<Result>(_ body: () throws -> Result) throws -> Result {
    try fileManager.createDirectory(
      at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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

  private func removeHooksLocked() throws {
    guard let originalData = try readHooksDataIfPresent() else { return }
    let updatedData = try Self.removing(
      originalData,
      command: Self.hookCommand(for: shimURL),
      legacyCommands: [Self.hookCommand(for: legacyShimURL)])
    guard updatedData != originalData else { return }
    try writePrivateBackup(originalData)
    try atomicWrite(updatedData, to: hooksURL, expectedOriginal: originalData)
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

  private func readHooksDataIfPresent() throws -> Data? {
    var pathInformation = stat()
    guard lstat(hooksURL.path, &pathInformation) == 0 else {
      if errno == ENOENT { return nil }
      throw HookInstallerError.unsafeHooksFile
    }
    guard pathInformation.st_mode & S_IFMT == S_IFREG,
      pathInformation.st_uid == getuid()
    else { throw HookInstallerError.unsafeHooksFile }

    let descriptor = Darwin.open(hooksURL.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw HookInstallerError.unsafeHooksFile }
    defer { Darwin.close(descriptor) }
    var descriptorInformation = stat()
    guard fstat(descriptor, &descriptorInformation) == 0,
      descriptorInformation.st_mode & S_IFMT == S_IFREG,
      descriptorInformation.st_uid == getuid(),
      descriptorInformation.st_dev == pathInformation.st_dev,
      descriptorInformation.st_ino == pathInformation.st_ino
    else { throw HookInstallerError.unsafeHooksFile }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private func removeLegacyInstalledHelper() throws {
    guard hasOwnedShim(shim: legacyShimURL, installedHelper: legacyInstalledHelperURL) else {
      return
    }
    try fileManager.removeItem(at: legacyShimURL)
    if pathExistsWithoutFollowingSymlinks(legacyInstalledHelperURL) {
      try fileManager.removeItem(at: legacyInstalledHelperURL)
    }
  }
}
