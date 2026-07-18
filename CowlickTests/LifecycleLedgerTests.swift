import Foundation
import XCTest

@testable import Cowlick

final class LifecycleLedgerTests: XCTestCase {
  func testMarkWorkingReloadsAndReplacesSameSession() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date()

    try LifecycleLedger.markWorking(
      sessionID: "session-1", turnID: "turn-1", workingDirectory: "/tmp/Scoutly",
      model: "gpt-5.6", updatedAt: now, homeDirectory: home)
    try LifecycleLedger.markWorking(
      sessionID: "session-1", turnID: "turn-2", workingDirectory: "/tmp/ActivityPilot",
      model: nil, updatedAt: now.addingTimeInterval(1), homeDirectory: home)

    let recovered = LifecycleLedger.load(homeDirectory: home, now: now.addingTimeInterval(2))
    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(recovered.first?.sessionID, "session-1")
    XCTAssertEqual(recovered.first?.turnID, "turn-2")
    XCTAssertEqual(recovered.first?.workingDirectory, "/tmp/ActivityPilot")
    XCTAssertNil(recovered.first?.model)
  }

  func testRemoveClearsOnlyMatchingSession() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date()

    for sessionID in ["one", "two"] {
      try LifecycleLedger.markWorking(
        sessionID: sessionID, turnID: nil, workingDirectory: "/tmp/\(sessionID)", model: nil,
        updatedAt: now, homeDirectory: home)
    }
    try LifecycleLedger.remove(sessionID: "one", now: now, homeDirectory: home)

    XCTAssertEqual(
      LifecycleLedger.load(homeDirectory: home, now: now).map(\.sessionID), ["two"])
  }

  func testStaleSessionsAreNotRecovered() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date()
    try LifecycleLedger.markWorking(
      sessionID: "stale", turnID: nil, workingDirectory: "/tmp/stale", model: nil,
      updatedAt: now.addingTimeInterval(-LifecycleLedger.staleInterval - 1), homeDirectory: home)

    XCTAssertTrue(LifecycleLedger.load(homeDirectory: home, now: now).isEmpty)
  }

  func testLedgerUsesOwnerOnlyPermissions() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try LifecycleLedger.markWorking(
      sessionID: "private", turnID: nil, workingDirectory: "/tmp/private", model: nil,
      updatedAt: Date(), homeDirectory: home)

    let support = home.appendingPathComponent(
      "Library/Application Support/Cowlick", isDirectory: true)
    let ledger = support.appendingPathComponent("active-sessions.json")
    let directoryMode = try permissionMode(at: support)
    let ledgerMode = try permissionMode(at: ledger)

    XCTAssertEqual(directoryMode & 0o777, 0o700)
    XCTAssertEqual(ledgerMode & 0o777, 0o600)
  }

  @MainActor
  func testSessionStoreRestoresWorkingSessionsWithoutPromptContent() async {
    let store = SessionStore(settings: makeTestSettings())
    let entry = Cowlick.PersistedLifecycleSession(
      sessionID: "recovered", turnID: "turn", workingDirectory: "/tmp/Scoutly",
      model: "gpt-5.6", updatedAt: Date())

    await store.restoreLifecycleSessions([entry])

    XCTAssertEqual(store.activeSessionCount, 1)
    XCTAssertEqual(store.sessions["recovered"]?.projectName, "Scoutly")
    guard case .working(let prompt)? = store.sessions["recovered"]?.status else {
      return XCTFail("Expected recovered working session")
    }
    XCTAssertNil(prompt)
  }

  private func makeTemporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CowlickLedgerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func permissionMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
