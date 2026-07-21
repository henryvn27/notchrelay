import Darwin
import XCTest

@testable import Cowlick

final class HookInstallerTests: XCTestCase {
  private let command = "/Users/test/.local/bin/cowlick-hook hook"
  private let legacyCommand = "/Users/test/.local/bin/notchrelay-hook hook"

  func testSupportedEventsIncludeCurrentSessionAndSubagentLifecycle() {
    XCTAssertEqual(
      Set(HookInstaller.supportedEvents),
      [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop",
        "Stop",
      ])
  }

  func testMergeIsIdempotent() throws {
    let first = try HookInstaller.merging(Data("{}".utf8), command: command)
    let second = try HookInstaller.merging(first, command: command)
    XCTAssertEqual(first, second)
  }

  func testMergeRepairsNonCanonicalOwnedHandlersAndPreservesUnrelatedConfiguration() throws {
    let invalidHandlers: [[String: Any]] = [
      canonicalHandler(event: "Stop", replacing: ["command": "/tmp/wrong-hook hook"]),
      canonicalHandler(event: "Stop", replacing: ["type": "prompt"]),
      canonicalHandler(
        event: "Stop",
        replacing: [
          "cowlick": ["product": "Cowlick", "protocol": ProductVersion.bridgeProtocol - 1]
        ]),
      canonicalHandler(event: "Stop", replacing: ["timeout": 75]),
      canonicalHandler(event: "Stop", replacing: ["statusMessage": "Working"]),
    ]
    let foreignHandler: [String: Any] = [
      "type": "command", "command": "/usr/local/bin/unrelated", "foreign": true,
    ]
    let original = try JSONSerialization.data(withJSONObject: [
      "future": ["preserve": true],
      "hooks": [
        "Stop": [
          [
            "matcher": "keep",
            "unknownGroupField": 42,
            "hooks": invalidHandlers + [foreignHandler],
          ]
        ]
      ],
    ])

    let repaired = try HookInstaller.merging(original, command: command)
    XCTAssertEqual(repaired, try HookInstaller.merging(repaired, command: command))

    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: repaired) as? [String: Any])
    XCTAssertEqual((root["future"] as? [String: Any])?["preserve"] as? Bool, true)
    let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
    let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
    let preservedGroup = try XCTUnwrap(groups.first)
    XCTAssertEqual(preservedGroup["matcher"] as? String, "keep")
    XCTAssertEqual(preservedGroup["unknownGroupField"] as? Int, 42)
    let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    XCTAssertEqual(
      handlers.filter { $0["command"] as? String == "/usr/local/bin/unrelated" }.count, 1)
    let owned = handlers.filter {
      ($0["cowlick"] as? [String: Any])?["product"] as? String == "Cowlick"
    }
    XCTAssertEqual(owned.count, 1)
    XCTAssertEqual(owned.first?["type"] as? String, "command")
    XCTAssertEqual(owned.first?["command"] as? String, command)
    XCTAssertEqual(owned.first?["timeout"] as? Int, 5)
    XCTAssertEqual(owned.first?["statusMessage"] as? String, "Cowlick")
    XCTAssertEqual(
      (owned.first?["cowlick"] as? [String: Any])?["protocol"] as? Int,
      ProductVersion.bridgeProtocol)
  }

  func testRepairMigratesFourEventInstallToSixAndRemovalPreservesForeignConfiguration() throws {
    let formerEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"]
    let ownedHandler: [String: Any] = [
      "type": "command",
      "command": command,
      "cowlick": ["product": "Cowlick", "protocol": 1],
    ]
    var hooks: [String: Any] = [:]
    for event in formerEvents {
      hooks[event] = [["hooks": [ownedHandler]]]
    }
    hooks["Stop"] = [
      [
        "matcher": "preserve",
        "hooks": [
          ownedHandler,
          ["type": "command", "command": "/usr/local/bin/unrelated"],
        ],
      ]
    ]
    hooks["FutureEvent"] = [
      [
        "futureGroup": true,
        "hooks": [["type": "command", "command": "/usr/local/bin/future"]],
      ]
    ]
    let original = try JSONSerialization.data(withJSONObject: [
      "future": ["enabled": true],
      "hooks": hooks,
    ])

    let repaired = try HookInstaller.merging(original, command: command)
    let repairedAgain = try HookInstaller.merging(repaired, command: command)
    XCTAssertEqual(repaired, repairedAgain)

    let repairedRoot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: repaired) as? [String: Any])
    let repairedHooks = try XCTUnwrap(repairedRoot["hooks"] as? [String: Any])
    XCTAssertEqual((repairedRoot["future"] as? [String: Any])?["enabled"] as? Bool, true)
    let repairedFutureGroups = try XCTUnwrap(
      repairedHooks["FutureEvent"] as? [[String: Any]])
    XCTAssertEqual(repairedFutureGroups.first?["futureGroup"] as? Bool, true)
    let repairedFutureHandlers = try XCTUnwrap(
      repairedFutureGroups.first?["hooks"] as? [[String: Any]])
    XCTAssertEqual(repairedFutureHandlers.first?["command"] as? String, "/usr/local/bin/future")
    for event in HookInstaller.supportedEvents {
      let groups = try XCTUnwrap(repairedHooks[event] as? [[String: Any]])
      let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
      let owned = handlers.filter {
        ($0["cowlick"] as? [String: Any])?["product"] as? String == "Cowlick"
      }
      XCTAssertEqual(owned.count, 1, "Expected one Cowlick handler for \(event)")
    }

    let removed = try HookInstaller.removing(repaired, command: command)
    let removedRoot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let removedHooks = try XCTUnwrap(removedRoot["hooks"] as? [String: Any])
    XCTAssertEqual((removedRoot["future"] as? [String: Any])?["enabled"] as? Bool, true)
    let removedFutureGroups = try XCTUnwrap(
      removedHooks["FutureEvent"] as? [[String: Any]])
    XCTAssertEqual(removedFutureGroups.first?["futureGroup"] as? Bool, true)
    let removedFutureHandlers = try XCTUnwrap(
      removedFutureGroups.first?["hooks"] as? [[String: Any]])
    XCTAssertEqual(removedFutureHandlers.first?["command"] as? String, "/usr/local/bin/future")
    for event in HookInstaller.supportedEvents where event != "Stop" {
      XCTAssertNil(removedHooks[event], "Expected Cowlick-only event \(event) to be removed")
    }
    let stopGroups = try XCTUnwrap(removedHooks["Stop"] as? [[String: Any]])
    XCTAssertEqual(stopGroups.first?["matcher"] as? String, "preserve")
    let stopHandlers = try XCTUnwrap(stopGroups.first?["hooks"] as? [[String: Any]])
    XCTAssertEqual(stopHandlers.map { $0["command"] as? String }, ["/usr/local/bin/unrelated"])
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

  func testMergeAndRemovalRejectUnsupportedSupportedEventShapes() throws {
    let invalidValues: [Any] = [
      ["future": true],
      [42],
      [["matcher": "missing-handlers"]],
      [["hooks": ["future": true]]],
      [["hooks": [["type": "command"], 42]]],
    ]

    for invalidValue in invalidValues {
      let original = try JSONSerialization.data(withJSONObject: [
        "preserve": true,
        "hooks": ["Stop": invalidValue],
      ])
      XCTAssertThrowsError(try HookInstaller.merging(original, command: command)) { error in
        guard case HookInstallerError.invalidHooksObject = error else {
          return XCTFail("Expected unsupported shape rejection, got \(error)")
        }
      }
      XCTAssertThrowsError(try HookInstaller.removing(original, command: command)) { error in
        guard case HookInstallerError.invalidHooksObject = error else {
          return XCTFail("Expected unsupported shape rejection, got \(error)")
        }
      }
    }
  }

  func testUnknownEventShapeIsPreservedAcrossIdempotentMergeAndRemoval() throws {
    let original = try JSONSerialization.data(withJSONObject: [
      "future": ["preserve": true],
      "hooks": ["FutureEvent": ["schema": 2]],
    ])

    let merged = try HookInstaller.merging(original, command: command)
    XCTAssertEqual(merged, try HookInstaller.merging(merged, command: command))
    let removed = try HookInstaller.removing(merged, command: command)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])

    XCTAssertEqual((root["future"] as? [String: Any])?["preserve"] as? Bool, true)
    XCTAssertEqual((hooks["FutureEvent"] as? [String: Any])?["schema"] as? Int, 2)
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

  func testStatusRejectsOwnedButOutdatedHelper() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "pre-ack-helper")

    XCTAssertFalse(fixture.installer.status().helperInstalled)
  }

  func testStatusRejectsEveryNonCanonicalFieldAndOwnedDuplicates() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "current-helper")
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let installedCommand = "'\(fixture.installer.shimURL.path)' hook"
    let invalidStopHandlers: [[[String: Any]]] = [
      [
        canonicalHandler(
          event: "Stop",
          replacing: [
            "command": installedCommand, "type": "prompt",
          ])
      ],
      [
        canonicalHandler(
          event: "Stop",
          replacing: [
            "command": "/tmp/wrong-hook hook"
          ])
      ],
      [
        canonicalHandler(
          event: "Stop",
          replacing: [
            "command": installedCommand,
            "cowlick": ["product": "Cowlick", "protocol": ProductVersion.bridgeProtocol - 1],
          ])
      ],
      [
        canonicalHandler(
          event: "Stop",
          replacing: [
            "command": installedCommand, "timeout": 75,
          ])
      ],
      [
        canonicalHandler(
          event: "Stop",
          replacing: [
            "command": installedCommand, "statusMessage": "Working",
          ])
      ],
      [
        canonicalHandler(event: "Stop", replacing: ["command": installedCommand]),
        canonicalHandler(event: "Stop", replacing: ["command": installedCommand]),
      ],
    ]

    for invalidStop in invalidStopHandlers {
      let hooks = Dictionary(
        uniqueKeysWithValues: HookInstaller.supportedEvents.map { event in
          let handlers =
            event == "Stop"
            ? invalidStop
            : [canonicalHandler(event: event, replacing: ["command": installedCommand])]
          return (event, [["hooks": handlers]])
        })
      try JSONSerialization.data(withJSONObject: ["hooks": hooks])
        .write(to: fixture.installer.hooksURL)

      let status = fixture.installer.status()
      XCTAssertFalse(status.isHealthy)
      XCTAssertFalse(status.installedEvents.contains("Stop"))
      XCTAssertEqual(
        status.installedEvents,
        Set(HookInstaller.supportedEvents).subtracting(["Stop"]))
    }
  }

  func testRefreshAtomicallyUpgradesHelperWithoutChangingHooksOrSettings() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "pre-ack-helper")
    let oldHandle = try FileHandle(forReadingFrom: fixture.installer.installedHelperURL)
    defer { try? oldHandle.close() }

    let hooks = Data(#"{"future":{"enabled":true},"hooks":{"Stop":[]}}"#.utf8)
    let settings = Data("model = \"gpt-5.6\"\n".utf8)
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try hooks.write(to: fixture.installer.hooksURL)
    let settingsURL = fixture.installer.hooksURL.deletingLastPathComponent()
      .appendingPathComponent("settings.toml")
    try settings.write(to: settingsURL)

    try fixture.installer.refreshInstalledHelperIfNeeded()

    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("current-helper".utf8))
    XCTAssertEqual(try oldHandle.readToEnd(), Data("pre-ack-helper".utf8))
    XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
    XCTAssertEqual(try Data(contentsOf: settingsURL), settings)
    XCTAssertTrue(fixture.installer.status().helperInstalled)
  }

  func testFailedAtomicRefreshPreservesPreviousInstallHooksAndSettings() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try FileManager.default.createDirectory(
      at: fixture.installer.installedHelperURL, withIntermediateDirectories: true)
    let marker = fixture.installer.installedHelperURL.appendingPathComponent("old-helper-marker")
    try Data("pre-ack-helper".utf8).write(to: marker)
    try FileManager.default.createDirectory(
      at: fixture.installer.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.shimURL, withDestinationURL: fixture.installer.installedHelperURL)

    let hooks = Data(#"{"custom":"preserve","hooks":{}}"#.utf8)
    let settings = Data("approval_timeout = 60\n".utf8)
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try hooks.write(to: fixture.installer.hooksURL)
    let settingsURL = fixture.installer.hooksURL.deletingLastPathComponent()
      .appendingPathComponent("settings.toml")
    try settings.write(to: settingsURL)

    XCTAssertThrowsError(try fixture.installer.refreshInstalledHelperIfNeeded()) { error in
      guard case HookInstallerError.helperReplacementFailed = error else {
        return XCTFail("Expected atomic replacement failure, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: marker), Data("pre-ack-helper".utf8))
    XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
    XCTAssertEqual(try Data(contentsOf: settingsURL), settings)
  }

  func testDeveloperBuildRequiresExplicitRepairBeforeReplacingPersistentHelper() throws {
    let fixture = try makeInstaller(
      bundledContents: "developer-helper", installedApplication: false)
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "installed-helper")

    try fixture.installer.refreshInstalledHelperIfNeeded()
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("installed-helper".utf8))
    XCTAssertThrowsError(try fixture.installer.currentInstalledHelperURL()) { error in
      guard case HookInstallerError.automaticHelperRefreshUnavailable = error else {
        return XCTFail("Expected developer-location rejection, got \(error)")
      }
    }

    try fixture.installer.installOrRepair()
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("developer-helper".utf8))
    XCTAssertEqual(
      try fixture.installer.installedHelperURLForExplicitSelfTest(),
      fixture.installer.installedHelperURL)
  }

  func testUITestBuildNeverRefreshesPersistentHelper() throws {
    let fixture = try makeInstaller(bundledContents: "ui-test-helper", arguments: ["--ui-testing"])
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "installed-helper")
    let hooks = Data(#"{"custom":"preserve","hooks":{}}"#.utf8)
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try hooks.write(to: fixture.installer.hooksURL)

    try fixture.installer.refreshInstalledHelperIfNeeded()

    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("installed-helper".utf8))
    XCTAssertThrowsError(try fixture.installer.currentInstalledHelperURL())
    XCTAssertThrowsError(try fixture.installer.installedHelperURLForExplicitSelfTest())
    XCTAssertThrowsError(try fixture.installer.installOrRepair())
    XCTAssertThrowsError(try fixture.installer.removeHooks())
    XCTAssertThrowsError(try fixture.installer.removeIntegration())
    XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("installed-helper".utf8))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.shimURL.path),
      fixture.installer.installedHelperURL.path)
  }

  func testAutomaticRefreshPolicyAcceptsOnlyCanonicalNonSymlinkedInstallLocations() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("CowlickInstaller-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let userInstall = home.appendingPathComponent("Applications/Cowlick.app", isDirectory: true)
    let developerBuild = home.appendingPathComponent(
      "DerivedData/Build/Products/Debug/Cowlick.app", isDirectory: true)

    XCTAssertTrue(
      HookInstaller.allowsAutomaticHelperRefresh(
        applicationBundleURL: userInstall, homeDirectory: home, arguments: []))
    XCTAssertTrue(
      HookInstaller.allowsAutomaticHelperRefresh(
        applicationBundleURL: URL(fileURLWithPath: "/Applications/Cowlick.app"),
        homeDirectory: home,
        arguments: []))
    XCTAssertFalse(
      HookInstaller.allowsAutomaticHelperRefresh(
        applicationBundleURL: developerBuild, homeDirectory: home, arguments: []))
    XCTAssertFalse(
      HookInstaller.allowsAutomaticHelperRefresh(
        applicationBundleURL: userInstall, homeDirectory: home, arguments: ["--ui-testing"]))

    try FileManager.default.createDirectory(
      at: developerBuild, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: userInstall.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: userInstall, withDestinationURL: developerBuild)
    XCTAssertFalse(
      HookInstaller.allowsAutomaticHelperRefresh(
        applicationBundleURL: userInstall, homeDirectory: home, arguments: []))

    let parentSymlinkHome = home.appendingPathComponent("ParentSymlinkHome", isDirectory: true)
    let derivedApplications = parentSymlinkHome.appendingPathComponent(
      "DerivedData/Build/Products/Debug", isDirectory: true)
    try FileManager.default.createDirectory(
      at: derivedApplications.appendingPathComponent("Cowlick.app", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: parentSymlinkHome.appendingPathComponent("Applications", isDirectory: true),
      withDestinationURL: derivedApplications)
    XCTAssertFalse(
      HookInstaller.allowsAutomaticHelperRefresh(
        applicationBundleURL: parentSymlinkHome.appendingPathComponent(
          "Applications/Cowlick.app", isDirectory: true),
        homeDirectory: parentSymlinkHome,
        arguments: []))
  }

  func testInstallRefusesForeignHelperWithoutOwnedShim() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try FileManager.default.createDirectory(
      at: fixture.installer.installedHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let foreignHelper = Data("foreign-helper".utf8)
    try foreignHelper.write(to: fixture.installer.installedHelperURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.installer.installedHelperURL.path)

    XCTAssertThrowsError(try fixture.installer.installOrRepair()) { error in
      guard case HookInstallerError.helperConflict = error else {
        return XCTFail("Expected foreign helper rejection, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: fixture.installer.installedHelperURL), foreignHelper)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installer.shimURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installer.hooksURL.path))
  }

  func testInstallRefusesForeignLegacyHelperBeforeChangingCurrentIntegration() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try FileManager.default.createDirectory(
      at: fixture.installer.legacyInstalledHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let foreignHelper = Data("foreign-legacy-helper".utf8)
    try foreignHelper.write(to: fixture.installer.legacyInstalledHelperURL)

    XCTAssertThrowsError(try fixture.installer.installOrRepair()) { error in
      guard case HookInstallerError.helperConflict = error else {
        return XCTFail("Expected foreign legacy helper rejection, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: fixture.installer.legacyInstalledHelperURL), foreignHelper)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.installer.installedHelperURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installer.hooksURL.path))
  }

  func testInstallRejectsMalformedAndNonObjectHooksBeforeCreatingHelper() throws {
    for hooks in [Data("{".utf8), Data("[]".utf8)] {
      let fixture = try makeInstaller(bundledContents: "new-helper")
      defer { try? FileManager.default.removeItem(at: fixture.home) }
      try FileManager.default.createDirectory(
        at: fixture.installer.hooksURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try hooks.write(to: fixture.installer.hooksURL)

      XCTAssertThrowsError(try fixture.installer.installOrRepair())

      XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.installer.installedHelperURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installer.shimURL.path))
    }
  }

  func testInstallRejectsMalformedAndNonObjectHooksBeforeReplacingOwnedHelper() throws {
    for hooks in [Data("{".utf8), Data("[]".utf8)] {
      let fixture = try makeInstaller(bundledContents: "new-helper")
      defer { try? FileManager.default.removeItem(at: fixture.home) }
      try installOwnedHelper(fixture.installer, contents: "old-helper")
      let originalShimDestination = try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.installer.shimURL.path)
      try FileManager.default.createDirectory(
        at: fixture.installer.hooksURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try hooks.write(to: fixture.installer.hooksURL)

      XCTAssertThrowsError(try fixture.installer.installOrRepair())

      XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
      XCTAssertEqual(
        try Data(contentsOf: fixture.installer.installedHelperURL), Data("old-helper".utf8))
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.shimURL.path),
        originalShimDestination)
    }
  }

  func testStatusInstallRepairAndRemovalRejectSymlinkedHooksWithoutChangingTarget() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "current-helper")
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let target = fixture.home.appendingPathComponent("foreign-hooks.json")
    let targetData = Data(#"{"foreign":{"preserve":true},"hooks":{}}"#.utf8)
    try targetData.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.hooksURL, withDestinationURL: target)

    let status = fixture.installer.status()
    XCTAssertFalse(status.isHealthy)
    XCTAssertNotNil(status.error)
    XCTAssertThrowsError(try fixture.installer.installOrRepair()) { error in
      guard case HookInstallerError.unsafeHooksFile = error else {
        return XCTFail("Expected symlink rejection, got \(error)")
      }
    }
    XCTAssertThrowsError(try fixture.installer.removeHooks()) { error in
      guard case HookInstallerError.unsafeHooksFile = error else {
        return XCTFail("Expected symlink rejection, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try fixture.installer.repairExistingIntegrationIfNeeded(intentionallyRemoved: false))

    XCTAssertEqual(try Data(contentsOf: target), targetData)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.hooksURL.path),
      target.path)
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("current-helper".utf8))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.shimURL.path),
      fixture.installer.installedHelperURL.path)
  }

  func testStatusInstallAndRemovalRejectNonRegularHooks() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL, withIntermediateDirectories: true)

    XCTAssertNotNil(fixture.installer.status().error)
    XCTAssertThrowsError(try fixture.installer.installOrRepair()) { error in
      guard case HookInstallerError.unsafeHooksFile = error else {
        return XCTFail("Expected non-regular file rejection, got \(error)")
      }
    }
    XCTAssertThrowsError(try fixture.installer.removeHooks()) { error in
      guard case HookInstallerError.unsafeHooksFile = error else {
        return XCTFail("Expected non-regular file rejection, got \(error)")
      }
    }
    var information = stat()
    XCTAssertEqual(lstat(fixture.installer.hooksURL.path, &information), 0)
    XCTAssertEqual(information.st_mode & S_IFMT, S_IFDIR)
  }

  func testRefreshReplacesSymlinkedHelperWithoutChangingItsTarget() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let externalHelper = fixture.home.appendingPathComponent("external-helper")
    try Data("current-helper".utf8).write(to: externalHelper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: externalHelper.path)
    try FileManager.default.createDirectory(
      at: fixture.installer.installedHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.installedHelperURL, withDestinationURL: externalHelper)
    try FileManager.default.createDirectory(
      at: fixture.installer.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.shimURL, withDestinationURL: fixture.installer.installedHelperURL)

    XCTAssertFalse(fixture.installer.status().helperInstalled)
    try fixture.installer.refreshInstalledHelperIfNeeded()

    XCTAssertThrowsError(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.installer.installedHelperURL.path))
    XCTAssertEqual(try Data(contentsOf: externalHelper), Data("current-helper".utf8))
    XCTAssertTrue(fixture.installer.status().helperInstalled)
  }

  func testRemoveIntegrationPreservesUnrelatedHooksAndSettings() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let originalHooks = Data(
      #"{"future":{"enabled":true},"hooks":{"Stop":[{"matcher":"keep","hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#
        .utf8)
    let settings = Data("model = \"gpt-5.6\"\n".utf8)
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try originalHooks.write(to: fixture.installer.hooksURL)
    let settingsURL = fixture.installer.hooksURL.deletingLastPathComponent()
      .appendingPathComponent("settings.toml")
    try settings.write(to: settingsURL)
    try fixture.installer.installOrRepair()

    try fixture.installer.removeIntegration()

    XCTAssertThrowsError(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.shimURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.installer.installedHelperURL.path))
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.installer.hooksURL))
        as? NSDictionary,
      try JSONSerialization.jsonObject(with: originalHooks) as? NSDictionary)
    XCTAssertEqual(try Data(contentsOf: settingsURL), settings)
  }

  func testInstalledFourEventIntegrationRepairsAutomatically() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "current-helper")
    let installedCommand = "'\(fixture.installer.shimURL.path)' hook"
    let ownedHandler: [String: Any] = [
      "type": "command",
      "command": installedCommand,
      "cowlick": ["product": "Cowlick", "protocol": 1],
    ]
    let oldEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"]
    let hooks = Dictionary(
      uniqueKeysWithValues: oldEvents.map { ($0, [["hooks": [ownedHandler]]]) })
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["hooks": hooks])
      .write(to: fixture.installer.hooksURL)

    XCTAssertTrue(
      try fixture.installer.repairExistingIntegrationIfNeeded(intentionallyRemoved: false))
    XCTAssertTrue(fixture.installer.status().isHealthy)
    XCTAssertFalse(
      try fixture.installer.repairExistingIntegrationIfNeeded(intentionallyRemoved: false))
  }

  func testAutomaticRepairRespectsExplicitIntegrationRemoval() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "current-helper")

    XCTAssertFalse(
      try fixture.installer.repairExistingIntegrationIfNeeded(intentionallyRemoved: true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installer.hooksURL.path))
  }

  func testRemoveIntegrationRefusesForeignShimWithoutChangingAnything() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try installOwnedHelper(fixture.installer, contents: "current-helper")
    try FileManager.default.removeItem(at: fixture.installer.shimURL)
    try Data("foreign-shim".utf8).write(to: fixture.installer.shimURL)
    let hooks = try HookInstaller.merging(Data("{}".utf8), command: command)
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try hooks.write(to: fixture.installer.hooksURL)

    XCTAssertThrowsError(try fixture.installer.removeIntegration()) { error in
      guard case HookInstallerError.shimConflict = error else {
        return XCTFail("Expected foreign shim rejection, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: fixture.installer.shimURL), Data("foreign-shim".utf8))
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("current-helper".utf8))
    XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
  }

  func testRemoveIntegrationRefusesForeignHelperWithoutChangingHooks() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try FileManager.default.createDirectory(
      at: fixture.installer.installedHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("foreign-helper".utf8).write(to: fixture.installer.installedHelperURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.installer.installedHelperURL.path)
    let hooks = try HookInstaller.merging(Data("{}".utf8), command: command)
    try FileManager.default.createDirectory(
      at: fixture.installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try hooks.write(to: fixture.installer.hooksURL)

    XCTAssertThrowsError(try fixture.installer.removeIntegration()) { error in
      guard case HookInstallerError.helperConflict = error else {
        return XCTFail("Expected foreign helper rejection, got \(error)")
      }
    }
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("foreign-helper".utf8))
    XCTAssertEqual(try Data(contentsOf: fixture.installer.hooksURL), hooks)
  }

  func testRemoveIntegrationRemovesOwnedLegacyHelper() throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try fixture.installer.installOrRepair()
    try FileManager.default.createDirectory(
      at: fixture.installer.legacyInstalledHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("legacy-helper".utf8).write(to: fixture.installer.legacyInstalledHelperURL)
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.legacyShimURL,
      withDestinationURL: fixture.installer.legacyInstalledHelperURL)

    try fixture.installer.removeIntegration()

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installer.legacyShimURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.installer.legacyInstalledHelperURL.path))
  }

  func testConcurrentRemoveThenInstallFinishesWhollyInstalled() async throws {
    let fixture = try makeInstaller(bundledContents: "current-helper")
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try fixture.installer.installOrRepair()

    let removalStarted = DispatchSemaphore(value: 0)
    let continueRemoval = DispatchSemaphore(value: 0)
    let blockingFileManager = BlockingRemovalFileManager(
      blockedPath: fixture.installer.shimURL.path,
      removalStarted: removalStarted,
      continueRemoval: continueRemoval)
    let removingInstaller = HookInstaller(
      fileManager: blockingFileManager,
      homeDirectory: fixture.home,
      applicationBundleURL: fixture.applicationBundle,
      bundledHelperURL: fixture.bundledHelper)
    let removeTask = Task.detached { try removingInstaller.removeIntegration() }
    XCTAssertEqual(removalStarted.wait(timeout: .now() + 2), .success)

    let lockURL = fixture.installer.hooksURL.deletingLastPathComponent()
      .appendingPathComponent(".hooks.json.cowlick.lock")
    let descriptor = Darwin.open(lockURL.path, O_RDWR)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    if descriptor >= 0 {
      let result = flock(descriptor, LOCK_EX | LOCK_NB)
      if result == 0 { flock(descriptor, LOCK_UN) }
      Darwin.close(descriptor)
      XCTAssertNotEqual(result, 0, "Removal must retain the integration lock through file deletion")
    }

    let installStarted = DispatchSemaphore(value: 0)
    let installingInstaller = HookInstaller(
      homeDirectory: fixture.home,
      applicationBundleURL: fixture.applicationBundle,
      bundledHelperURL: fixture.bundledHelper)
    let installTask = Task.detached {
      installStarted.signal()
      try installingInstaller.installOrRepair()
    }
    XCTAssertEqual(installStarted.wait(timeout: .now() + 2), .success)
    continueRemoval.signal()
    try await removeTask.value
    try await installTask.value

    XCTAssertTrue(fixture.installer.status().isHealthy)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.shimURL.path),
      fixture.installer.installedHelperURL.path)
    XCTAssertEqual(
      try Data(contentsOf: fixture.installer.installedHelperURL), Data("current-helper".utf8))
  }

  private func makeInstaller(
    bundledContents: String,
    installedApplication: Bool = true,
    arguments: [String] = []
  ) throws -> (
    home: URL, installer: HookInstaller, applicationBundle: URL, bundledHelper: URL
  ) {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("CowlickInstaller-\(UUID().uuidString)", isDirectory: true)
    let applicationBundle = home.appendingPathComponent(
      installedApplication
        ? "Applications/Cowlick.app"
        : "DerivedData/Build/Products/Debug/Cowlick.app")
    let bundledHelper = applicationBundle.appendingPathComponent("Contents/Helpers/cowlick-hook")
    try FileManager.default.createDirectory(
      at: bundledHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bundledContents.utf8).write(to: bundledHelper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: bundledHelper.path)
    return (
      home,
      HookInstaller(
        homeDirectory: home,
        applicationBundleURL: applicationBundle,
        bundledHelperURL: bundledHelper,
        arguments: arguments),
      applicationBundle,
      bundledHelper
    )
  }

  private func installOwnedHelper(_ installer: HookInstaller, contents: String) throws {
    try FileManager.default.createDirectory(
      at: installer.installedHelperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: installer.installedHelperURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: installer.installedHelperURL.path)
    try FileManager.default.createDirectory(
      at: installer.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: installer.shimURL, withDestinationURL: installer.installedHelperURL)
  }

  private func canonicalHandler(
    event: String,
    replacing replacements: [String: Any] = [:]
  ) -> [String: Any] {
    var handler: [String: Any] = [
      "type": "command",
      "command": command,
      "timeout": event == "PermissionRequest" ? 75 : 5,
      "statusMessage": "Cowlick",
      "cowlick": ["product": "Cowlick", "protocol": ProductVersion.bridgeProtocol],
    ]
    for (key, value) in replacements { handler[key] = value }
    return handler
  }
}

private final class BlockingRemovalFileManager: FileManager {
  private let blockedPath: String
  private let removalStarted: DispatchSemaphore
  private let continueRemoval: DispatchSemaphore

  init(
    blockedPath: String,
    removalStarted: DispatchSemaphore,
    continueRemoval: DispatchSemaphore
  ) {
    self.blockedPath = blockedPath
    self.removalStarted = removalStarted
    self.continueRemoval = continueRemoval
    super.init()
  }

  override func removeItem(at URL: URL) throws {
    if URL.path == blockedPath {
      removalStarted.signal()
      guard continueRemoval.wait(timeout: .now() + 5) == .success else {
        throw BlockingRemovalError.timedOut
      }
    }
    try super.removeItem(at: URL)
  }
}

private enum BlockingRemovalError: Error {
  case timedOut
}
