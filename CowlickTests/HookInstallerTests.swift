import XCTest

@testable import Cowlick

final class HookInstallerTests: XCTestCase {
  private let command = "/Users/test/.local/bin/cowlick-hook hook"
  private let legacyCommand = "/Users/test/.local/bin/notchrelay-hook hook"

  func testMergeIsIdempotent() throws {
    let first = try HookInstaller.merging(Data("{}".utf8), command: command)
    let second = try HookInstaller.merging(first, command: command)
    XCTAssertEqual(first, second)
  }

  func testMergePreservesUnrelatedHooksAndUnknownFields() throws {
    let original = Data(
      #"{"future":{"enabled":true},"hooks":{"Stop":[{"matcher":"keep","hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#
        .utf8)
    let merged = try HookInstaller.merging(original, command: command)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
    let future = try XCTUnwrap(root["future"] as? [String: Any])
    let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
    let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])

    XCTAssertEqual(future["enabled"] as? Bool, true)
    XCTAssertEqual(stopGroups.first?["matcher"] as? String, "keep")
    XCTAssertEqual(stopGroups.count, 2)
  }

  func testRemovalPreservesUnrelatedHandlersAndFields() throws {
    let original = Data(
      #"{"unknown":42,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/test/.local/bin/cowlick-hook hook"},{"type":"command","command":"/usr/local/bin/other"}]}]}}"#
        .utf8)
    let removed = try HookInstaller.removing(original, command: command)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
    let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
    let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])

    XCTAssertEqual(root["unknown"] as? Int, 42)
    XCTAssertEqual(handlers.count, 1)
    XCTAssertEqual(handlers.first?["command"] as? String, "/usr/local/bin/other")
  }

  func testRemovalAfterMergeRestoresSemanticOriginal() throws {
    let original = Data(
      #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/usr/local/bin/existing"}]}]},"custom":"value"}"#
        .utf8)
    let merged = try HookInstaller.merging(original, command: command)
    let removed = try HookInstaller.removing(merged)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? NSDictionary)
    let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
    XCTAssertEqual(root, expected)
  }

  func testRejectsNonObjectRoot() {
    XCTAssertThrowsError(try HookInstaller.merging(Data("[]".utf8), command: command))
  }

  func testRemovalDoesNotClaimCompoundForeignCommand() throws {
    let original = Data(
      """
      {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"printf foreign && \(command)"}]}]}}
      """.utf8)

    let removed = try HookInstaller.removing(original, command: command)

    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: removed) as? NSDictionary,
      try JSONSerialization.jsonObject(with: original) as? NSDictionary)
  }

  func testMergeReplacesLegacyHandlersExactlyOnce() throws {
    let original = Data(
      """
      {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(legacyCommand)","notchRelay":{"product":"NotchRelay","protocol":1}}]}]}}
      """.utf8)

    let merged = try HookInstaller.merging(
      original, command: command, legacyCommands: [legacyCommand])
    let mergedAgain = try HookInstaller.merging(
      merged, command: command, legacyCommands: [legacyCommand])
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedAgain) as? [String: Any])
    let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])

    for event in HookInstaller.supportedEvents {
      let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
      let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
      XCTAssertEqual(handlers.count, 1)
      XCTAssertEqual(handlers.first?["command"] as? String, command)
      XCTAssertNil(handlers.first?["notchRelay"])
    }
  }

  func testRemovalRemovesBothCurrentAndLegacyHandlers() throws {
    let original = Data(
      """
      {"future":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(command)"},{"type":"command","command":"\(legacyCommand)"},{"type":"command","command":"/usr/local/bin/other"}]}]}}
      """.utf8)

    let removed = try HookInstaller.removing(
      original, command: command, legacyCommands: [legacyCommand])
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
    let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
    let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])

    XCTAssertEqual(root["future"] as? Bool, true)
    XCTAssertEqual(handlers.map { $0["command"] as? String }, ["/usr/local/bin/other"])
  }

  func testHelperRemovalPreservesConflictingShim() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("CowlickInstaller-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(homeDirectory: home)
    try FileManager.default.createDirectory(
      at: installer.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: installer.installedHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("user-owned".utf8).write(to: installer.shimURL)
    try Data("installed-helper".utf8).write(to: installer.installedHelperURL)

    try installer.removeInstalledHelper()

    XCTAssertEqual(try String(contentsOf: installer.shimURL), "user-owned")
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedHelperURL.path))
  }
}
