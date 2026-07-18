import Foundation
import XCTest

@testable import Cowlick

private final class FakeCapsLockController: CapsLockControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool
  private(set) var writes: [Bool] = []

  init(initialState: Bool) { value = initialState }

  func readState() -> Bool { lock.withLock { value } }

  func setState(_ state: Bool) {
    lock.withLock {
      value = state
      writes.append(state)
    }
  }

  var state: Bool { lock.withLock { value } }
  var recordedWrites: [Bool] { lock.withLock { writes } }
}

private final class FailingCapsLockController: CapsLockControlling, @unchecked Sendable {
  func readState() -> Bool { false }
  func setState(_: Bool) throws { throw CapsLockError.verificationFailed("write rejected") }
}

final class CapsLockSignalTests: XCTestCase {
  func testSelfTestReadsChangedStateAndRestoresBeforeEnabling() async {
    let controller = FakeCapsLockController(initialState: false)
    let service = NativeCapsLockSignalService(controller: controller)

    let result = await service.testSignal()

    XCTAssertEqual(result, .available)
    XCTAssertFalse(controller.state)
    XCTAssertEqual(controller.recordedWrites.first, true)
    XCTAssertEqual(controller.recordedWrites.last, false)
  }

  func testSelfTestReportsWriteFailureWithoutChangingOriginalState() async {
    let controller = FailingCapsLockController()
    let service = NativeCapsLockSignalService(controller: controller)

    let result = await service.testSignal()

    guard case .unavailable(let reason) = result else {
      return XCTFail("Expected unavailable support after a rejected write")
    }
    XCTAssertTrue(reason.contains("write rejected"))
    XCTAssertFalse(controller.readState())
    let reportedSupport = await service.supportStatus()
    XCTAssertEqual(reportedSupport, .unavailable(reason))
  }

  func testCompletionRestoresOriginalOffState() async {
    let controller = FakeCapsLockController(initialState: false)
    let service = NativeCapsLockSignalService(controller: controller)
    await service.start(.completion)
    try? await Task.sleep(for: .milliseconds(300))

    XCTAssertFalse(controller.state)
    XCTAssertEqual(controller.recordedWrites.prefix(2), [true, false])
  }

  func testCancellationRestoresOriginalOnState() async {
    let controller = FakeCapsLockController(initialState: true)
    let service = NativeCapsLockSignalService(controller: controller)
    await service.start(.approval)
    try? await Task.sleep(for: .milliseconds(40))
    await service.cancelAndRestore()

    XCTAssertTrue(controller.state)
    XCTAssertEqual(controller.recordedWrites.last, true)
  }

  func testFailureUsesTwoPulsesAndRestores() async {
    let controller = FakeCapsLockController(initialState: false)
    let service = NativeCapsLockSignalService(controller: controller)
    await service.start(.failure)
    try? await Task.sleep(for: .milliseconds(500))

    XCTAssertFalse(controller.state)
    XCTAssertGreaterThanOrEqual(controller.recordedWrites.filter { $0 }.count, 2)
  }
}
