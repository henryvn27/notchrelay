import XCTest

@testable import Cowlick

final class PresentationRoutingTests: XCTestCase {
  func testAutomaticUsesNotchWhenSelectedDisplayHasNotch() {
    XCTAssertEqual(
      PresentationRouting.resolve(preference: .automatic, displayID: 42, hasNotch: true),
      .notch(displayID: 42)
    )
  }

  func testAutomaticUsesMenuBarWhenSelectedDisplayHasNoNotch() {
    XCTAssertEqual(
      PresentationRouting.resolve(preference: .automatic, displayID: 42, hasNotch: false),
      .menuBar
    )
  }

  func testMenuBarOverrideWinsOnNotchedDisplay() {
    XCTAssertEqual(
      PresentationRouting.resolve(preference: .menuBar, displayID: 42, hasNotch: true),
      .menuBar
    )
  }

  func testExactlyOnePresentationIsActiveForEveryInput() {
    for preference in PresentationPreference.allCases {
      for hasNotch in [false, true] {
        let resolved = PresentationRouting.resolve(
          preference: preference, displayID: 7, hasNotch: hasNotch)
        switch resolved {
        case .notch:
          XCTAssertFalse(resolved.usesMenuBar)
        case .menuBar:
          XCTAssertTrue(resolved.usesMenuBar)
        }
      }
    }
  }
}
