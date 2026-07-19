import Darwin
import Foundation

enum BoundedProcessRunnerError: Error, Equatable {
  case outputReadFailed
  case responseTooLarge
  case timedOut
  case incompleteOutput
  case processFailed(Int32)
  case processStatusFailed(Int32)
}

typealias WaitPIDFunction = (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t

func runBoundedProcessOperation<Result: Sendable>(
  _ operation: @escaping @Sendable () throws -> Result
) async throws -> Result {
  try await withThrowingTaskGroup(of: Result.self) { group in
    group.addTask(priority: .utility, operation: operation)
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw CancellationError() }
    return result
  }
}

final class BoundedProcessRunner {
  private static let pollingInterval: TimeInterval = 0.005
  private static let terminationGrace: TimeInterval = 0.05
  private static let killGrace: TimeInterval = 0.25

  private let processIdentifier: pid_t
  private var inputDescriptor: Int32?
  private var outputDescriptor: Int32?
  private let maximumOutputSize: Int
  private let deadline: DispatchTime
  private let waitPID: WaitPIDFunction
  private var reachedEndOfFile = false
  private var rawTerminationStatus: Int32?
  private var stopped = false

  private(set) var output = Data()

  init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    acceptsInput: Bool = false,
    timeout: TimeInterval,
    maximumOutputSize: Int,
    waitPID: @escaping WaitPIDFunction = { Darwin.waitpid($0, $1, $2) },
    beforeSpawn: (() -> Void)? = nil
  ) throws {
    self.maximumOutputSize = maximumOutputSize
    self.waitPID = waitPID

    let outputPipe = try Self.makePipe()
    let inputPipe: [Int32]
    do {
      inputPipe = acceptsInput ? try Self.makePipe() : [-1, -1]
    } catch {
      Self.closeDescriptors(outputPipe)
      throw error
    }

    var fileActions: posix_spawn_file_actions_t?
    let fileActionsError = posix_spawn_file_actions_init(&fileActions)
    guard fileActionsError == 0 else {
      Self.closeDescriptors(outputPipe + inputPipe)
      throw Self.posixError(fileActionsError)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    var attributes: posix_spawnattr_t?
    let attributesError = posix_spawnattr_init(&attributes)
    guard attributesError == 0 else {
      Self.closeDescriptors(outputPipe + inputPipe)
      throw Self.posixError(attributesError)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    let nullDescriptor: Int32
    do {
      nullDescriptor = try Self.openNullDescriptor()
    } catch {
      Self.closeDescriptors(outputPipe + inputPipe)
      throw error
    }
    defer { Darwin.close(nullDescriptor) }

    var actionError = posix_spawn_file_actions_adddup2(
      &fileActions, outputPipe[1], STDOUT_FILENO)
    if actionError == 0 {
      actionError = posix_spawn_file_actions_adddup2(
        &fileActions, nullDescriptor, STDERR_FILENO)
    }
    if acceptsInput, actionError == 0 {
      actionError = posix_spawn_file_actions_adddup2(
        &fileActions, inputPipe[0], STDIN_FILENO)
    }
    for descriptor in outputPipe + inputPipe
    where descriptor > STDERR_FILENO && actionError == 0 {
      actionError = posix_spawn_file_actions_addclose(&fileActions, descriptor)
    }
    if nullDescriptor > STDERR_FILENO, actionError == 0 {
      actionError = posix_spawn_file_actions_addclose(&fileActions, nullDescriptor)
    }
    let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    var attributeError = posix_spawnattr_setflags(&attributes, spawnFlags)
    if attributeError == 0 {
      attributeError = posix_spawnattr_setpgroup(&attributes, 0)
    }
    guard actionError == 0, attributeError == 0 else {
      Self.closeDescriptors(outputPipe + inputPipe)
      throw Self.posixError(actionError == 0 ? attributeError : actionError)
    }

    var argumentPointers = ([executableURL.path] + arguments).map { strdup($0) }
    argumentPointers.append(nil)
    defer {
      for pointer in argumentPointers.compactMap({ $0 }) { free(pointer) }
    }
    var environmentPointers =
      environment?.sorted { $0.key < $1.key }.map {
        strdup("\($0.key)=\($0.value)")
      } ?? []
    if environment != nil { environmentPointers.append(nil) }
    defer {
      for pointer in environmentPointers.compactMap({ $0 }) { free(pointer) }
    }

    var spawnedPID: pid_t = 0
    beforeSpawn?()
    let spawnError = argumentPointers.withUnsafeMutableBufferPointer { arguments in
      if environment != nil {
        return environmentPointers.withUnsafeMutableBufferPointer { environment in
          posix_spawn(
            &spawnedPID, executableURL.path, &fileActions, &attributes,
            arguments.baseAddress, environment.baseAddress)
        }
      }
      return posix_spawn(
        &spawnedPID, executableURL.path, &fileActions, &attributes,
        arguments.baseAddress, environ)
    }
    guard spawnError == 0 else {
      Self.closeDescriptors(outputPipe + inputPipe)
      throw Self.posixError(spawnError)
    }

    processIdentifier = spawnedPID
    deadline = .now() + timeout
    Darwin.close(outputPipe[1])
    outputDescriptor = outputPipe[0]
    if acceptsInput {
      Darwin.close(inputPipe[0])
      inputDescriptor = inputPipe[1]
      guard Darwin.fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
        let error = errno
        stop()
        throw Self.posixError(error)
      }
    }

    let flags = Darwin.fcntl(outputPipe[0], F_GETFL)
    guard flags >= 0, Darwin.fcntl(outputPipe[0], F_SETFL, flags | O_NONBLOCK) >= 0 else {
      stop()
      throw BoundedProcessRunnerError.outputReadFailed
    }
  }

  deinit {
    stop()
  }

  func write(_ data: Data) throws {
    do {
      try Task.checkCancellation()
      guard let inputDescriptor else { throw CocoaError(.fileWriteUnknown) }
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let byteCount = Darwin.write(
            inputDescriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
          if byteCount > 0 {
            offset += byteCount
          } else if byteCount < 0, errno == EINTR {
            continue
          } else {
            throw Self.posixError(errno)
          }
        }
      }
    } catch {
      stop()
      throw error
    }
  }

  func read(until isComplete: (Data) -> Bool) throws {
    do {
      while true {
        try Task.checkCancellation()
        if isComplete(output) { return }
        try drainAvailableOutput()
        if isComplete(output) { return }
        switch waitForLeader(options: WNOHANG) {
        case .running:
          break
        case .reaped(let status) where reachedEndOfFile:
          guard status == 0 else { throw BoundedProcessRunnerError.processFailed(status) }
          throw BoundedProcessRunnerError.incompleteOutput
        case .reaped:
          break
        case .noChild:
          throw BoundedProcessRunnerError.processStatusFailed(ECHILD)
        case .failed(let error):
          throw BoundedProcessRunnerError.processStatusFailed(error)
        }
        guard DispatchTime.now() < deadline else {
          throw BoundedProcessRunnerError.timedOut
        }
        Thread.sleep(forTimeInterval: Self.pollingInterval)
      }
    } catch {
      stop()
      throw error
    }
  }

  func readToExit() throws {
    do {
      while true {
        try Task.checkCancellation()
        try drainAvailableOutput()
        switch waitForLeader(options: WNOHANG) {
        case .running:
          break
        case .reaped(let status) where reachedEndOfFile:
          guard status == 0 else { throw BoundedProcessRunnerError.processFailed(status) }
          return
        case .reaped:
          break
        case .noChild:
          throw BoundedProcessRunnerError.processStatusFailed(ECHILD)
        case .failed(let error):
          throw BoundedProcessRunnerError.processStatusFailed(error)
        }
        guard DispatchTime.now() < deadline else {
          throw BoundedProcessRunnerError.timedOut
        }
        Thread.sleep(forTimeInterval: Self.pollingInterval)
      }
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true

    if processGroupIsRunning() {
      Darwin.kill(-processIdentifier, SIGTERM)
      waitForGroupExit(until: .now() + Self.terminationGrace)
      if processGroupIsRunning() {
        Darwin.kill(-processIdentifier, SIGKILL)
        waitForGroupExit(until: .now() + Self.killGrace)
      }
    }
    reapLeaderAfterStop()
    closeDescriptors()
  }

  private func terminationStatus(from rawTerminationStatus: Int32) -> Int32 {
    let signal = rawTerminationStatus & 0x7F
    return signal == 0 ? (rawTerminationStatus >> 8) & 0xFF : signal
  }

  private enum WaitResult {
    case running
    case reaped(Int32)
    case noChild
    case failed(Int32)
  }

  private func waitForLeader(options: Int32) -> WaitResult {
    if let rawTerminationStatus {
      return .reaped(terminationStatus(from: rawTerminationStatus))
    }
    while true {
      var status: Int32 = 0
      errno = 0
      let result = waitPID(processIdentifier, &status, options)
      if result == processIdentifier {
        rawTerminationStatus = status
        return .reaped(terminationStatus(from: status))
      }
      if result == 0 { return .running }
      let error = errno
      if result == -1, error == EINTR { continue }
      if result == -1, error == ECHILD { return .noChild }
      return .failed(error == 0 ? EIO : error)
    }
  }

  private func processGroupIsRunning() -> Bool {
    errno = 0
    return Darwin.kill(-processIdentifier, 0) == 0 || errno == EPERM
  }

  private func drainAvailableOutput() throws {
    guard !reachedEndOfFile, let outputDescriptor else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let byteCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(outputDescriptor, bytes.baseAddress, bytes.count)
      }
      if byteCount > 0 {
        guard byteCount <= maximumOutputSize - output.count else {
          throw BoundedProcessRunnerError.responseTooLarge
        }
        output.append(contentsOf: buffer.prefix(byteCount))
      } else if byteCount == 0 {
        reachedEndOfFile = true
        return
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      } else {
        throw BoundedProcessRunnerError.outputReadFailed
      }
    }
  }

  private func waitForGroupExit(until deadline: DispatchTime) {
    while processGroupIsRunning(), DispatchTime.now() < deadline {
      _ = waitForLeader(options: WNOHANG)
      Thread.sleep(forTimeInterval: Self.pollingInterval)
    }
    _ = waitForLeader(options: WNOHANG)
  }

  private func reapLeaderAfterStop() {
    guard rawTerminationStatus == nil else { return }
    while true {
      switch waitForLeader(options: 0) {
      case .running:
        continue
      case .reaped, .noChild, .failed:
        return
      }
    }
  }

  private func closeDescriptors() {
    if let inputDescriptor { Darwin.close(inputDescriptor) }
    if let outputDescriptor { Darwin.close(outputDescriptor) }
    inputDescriptor = nil
    outputDescriptor = nil
  }

  private static func closeDescriptors(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 {
      Darwin.close(descriptor)
    }
  }

  private static func makePipe() throws -> [Int32] {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&descriptors) == 0 else { throw posixError(errno) }
    do {
      for descriptor in descriptors { try setCloseOnExec(descriptor) }
    } catch {
      closeDescriptors(descriptors)
      throw error
    }
    for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
      let duplicate = Darwin.fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
      guard duplicate >= 0 else {
        let error = errno
        closeDescriptors(descriptors)
        throw posixError(error)
      }
      Darwin.close(descriptors[index])
      descriptors[index] = duplicate
      do {
        try setCloseOnExec(duplicate)
      } catch {
        closeDescriptors(descriptors)
        throw error
      }
    }
    return descriptors
  }

  private static func openNullDescriptor() throws -> Int32 {
    var descriptor = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError(errno) }
    do {
      try setCloseOnExec(descriptor)
      if descriptor <= STDERR_FILENO {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard duplicate >= 0 else { throw posixError(errno) }
        Darwin.close(descriptor)
        descriptor = duplicate
        try setCloseOnExec(descriptor)
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func setCloseOnExec(_ descriptor: Int32) throws {
    let flags = Darwin.fcntl(descriptor, F_GETFD)
    guard flags >= 0 else { throw posixError(errno) }
    guard Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
      throw posixError(errno)
    }
  }

  private static func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }
}
