import Darwin.Mach
import Foundation
import IOKit
import IOKit.hidsystem

enum CapsLockPattern: Sendable, Equatable {
  case completion
  case approval
  case failure
}

enum CapsLockSupport: Equatable, Sendable {
  case available
  case unavailable(String)

  var summary: String {
    switch self {
    case .available: "Native HID control available; run the signal test before enabling"
    case .unavailable(let reason): reason
    }
  }
}

protocol CapsLockSignalService: Sendable {
  func supportStatus() async -> CapsLockSupport
  func testSignal() async -> CapsLockSupport
  func start(_ pattern: CapsLockPattern) async
  func setPersistentAttention(_ pattern: CapsLockPattern?) async
  func cancelAndRestore() async
}

extension CapsLockSignalService {
  func setPersistentAttention(_ pattern: CapsLockPattern?) async {
    if let pattern {
      await start(pattern)
    } else {
      await cancelAndRestore()
    }
  }
}

protocol CapsLockControlling: AnyObject, Sendable {
  func readState() throws -> Bool
  func setState(_ state: Bool) throws
}

enum CapsLockError: LocalizedError {
  case serviceUnavailable
  case openFailed(kern_return_t)
  case readFailed(kern_return_t)
  case writeFailed(kern_return_t)
  case verificationFailed(String)

  var errorDescription: String? {
    switch self {
    case .serviceUnavailable: "macOS HID system service was not found."
    case .openFailed(let code):
      "HID system connection failed (\(code)). Input Monitoring or Accessibility permission may be required."
    case .readFailed(let code): "Caps Lock state could not be read (\(code))."
    case .writeFailed(let code): "Caps Lock state could not be changed (\(code))."
    case .verificationFailed(let reason): "Caps Lock signal verification failed: \(reason)"
    }
  }
}

final class NativeCapsLockController: CapsLockControlling, @unchecked Sendable {
  private var connection: io_connect_t = 0

  init() throws {
    guard let matching = IOServiceMatching(kIOHIDSystemClass) else {
      throw CapsLockError.serviceUnavailable
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { throw CapsLockError.serviceUnavailable }
    defer { IOObjectRelease(service) }

    let result = IOServiceOpen(
      service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
    guard result == KERN_SUCCESS else { throw CapsLockError.openFailed(result) }
  }

  deinit {
    if connection != IO_OBJECT_NULL { IOServiceClose(connection) }
  }

  func readState() throws -> Bool {
    var state = false
    let result = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state)
    guard result == KERN_SUCCESS else { throw CapsLockError.readFailed(result) }
    return state
  }

  func setState(_ state: Bool) throws {
    let result = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), state)
    guard result == KERN_SUCCESS else { throw CapsLockError.writeFailed(result) }
  }
}

actor NativeCapsLockSignalService: CapsLockSignalService {
  private let controller: (any CapsLockControlling)?
  private let unavailableReason: String?
  private var patternTask: Task<Void, Never>?
  private var originalState: Bool?
  private var verificationFailure: String?
  private var persistentPattern: CapsLockPattern?
  private var signalGeneration: UInt64 = 0

  init(controller: (any CapsLockControlling)? = nil) {
    if let controller {
      self.controller = controller
      unavailableReason = nil
    } else {
      do {
        self.controller = try NativeCapsLockController()
        unavailableReason = nil
      } catch {
        self.controller = nil
        unavailableReason = error.localizedDescription
      }
    }
  }

  func supportStatus() -> CapsLockSupport {
    if let verificationFailure { return .unavailable(verificationFailure) }
    guard let controller else {
      return .unavailable(unavailableReason ?? "Native Caps Lock control is unavailable.")
    }
    do {
      _ = try controller.readState()
      return .available
    } catch {
      return .unavailable(error.localizedDescription)
    }
  }

  func testSignal() async -> CapsLockSupport {
    let attentionToRestore = persistentPattern
    signalGeneration &+= 1
    patternTask?.cancel()
    patternTask = nil
    persistentPattern = nil
    restoreOriginalState()

    guard let controller else {
      return .unavailable(unavailableReason ?? "Native Caps Lock control is unavailable.")
    }
    do {
      let initialState = try controller.readState()
      var shouldRestoreAttention = false
      defer {
        try? controller.setState(initialState)
        if shouldRestoreAttention { setPersistentAttention(attentionToRestore) }
      }

      try controller.setState(!initialState)
      try await Task.sleep(for: .milliseconds(80))
      guard try controller.readState() == !initialState else {
        throw CapsLockError.verificationFailed("the changed state could not be read back")
      }

      try controller.setState(initialState)
      try await Task.sleep(for: .milliseconds(50))
      guard try controller.readState() == initialState else {
        throw CapsLockError.verificationFailed("the original state was not restored")
      }
      verificationFailure = nil
      shouldRestoreAttention = attentionToRestore != nil
      return .available
    } catch {
      let reason = error.localizedDescription
      verificationFailure = reason
      return .unavailable(reason)
    }
  }

  func start(_ pattern: CapsLockPattern) {
    if pattern == .approval || pattern == .completion {
      setPersistentAttention(pattern)
      return
    }
    guard persistentPattern == nil else { return }

    signalGeneration &+= 1
    let generation = signalGeneration
    patternTask?.cancel()
    restoreOriginalState()

    guard let controller, let original = try? controller.readState() else { return }
    originalState = original
    patternTask = Task { [weak self] in
      await self?.execute(pattern, generation: generation)
    }
  }

  func setPersistentAttention(_ pattern: CapsLockPattern?) {
    guard persistentPattern != pattern else { return }

    signalGeneration &+= 1
    patternTask?.cancel()
    patternTask = nil
    persistentPattern = nil
    restoreOriginalState()

    guard let pattern, let controller, let original = try? controller.readState() else { return }
    originalState = original
    do {
      try controller.setState(!original)
      persistentPattern = pattern
    } catch {
      restoreOriginalState()
    }
  }

  func cancelAndRestore() {
    signalGeneration &+= 1
    patternTask?.cancel()
    patternTask = nil
    persistentPattern = nil
    restoreOriginalState()
  }

  private func execute(_ pattern: CapsLockPattern, generation: UInt64) async {
    defer {
      if generation == signalGeneration, persistentPattern == nil {
        restoreOriginalState()
        patternTask = nil
      }
    }
    guard originalState != nil else { return }

    switch pattern {
    case .failure:
      await pulse(on: .milliseconds(105), off: .milliseconds(115))
      guard !Task.isCancelled else { return }
      await pulse(on: .milliseconds(105), off: .zero)
    case .approval, .completion:
      break
    }
  }

  private func pulse(on: Duration, off: Duration) async {
    guard let controller, let originalState else { return }
    do {
      try controller.setState(!originalState)
      try? await Task.sleep(for: on)
      try controller.setState(originalState)
      if off > .zero { try? await Task.sleep(for: off) }
    } catch {
      patternTask?.cancel()
    }
  }

  private func restoreOriginalState() {
    guard let controller, let originalState else { return }
    try? controller.setState(originalState)
    self.originalState = nil
  }
}
