import AppKit
import SwiftUI

enum NotchSwipeAction: Equatable {
  case expand
  case collapse
}

enum NotchSwipePhase: Equatable {
  case began
  case changed
  case ended
  case cancelled
  case none
}

struct NotchSwipeInterpreter {
  let threshold: CGFloat
  let intentThreshold: CGFloat
  let dominanceRatio: CGFloat

  private(set) var accumulatedVertical: CGFloat = 0
  private(set) var accumulatedHorizontal: CGFloat = 0
  private(set) var hasTriggered = false
  private var isTracking = false
  private var intent: Intent = .undecided

  init(
    threshold: CGFloat = 12,
    intentThreshold: CGFloat = 4,
    dominanceRatio: CGFloat = 1.25
  ) {
    self.threshold = threshold
    self.intentThreshold = intentThreshold
    self.dominanceRatio = dominanceRatio
  }

  mutating func interpret(
    phase: NotchSwipePhase,
    verticalDelta: CGFloat,
    horizontalDelta: CGFloat,
    isMomentum: Bool
  ) -> NotchSwipeAction? {
    if isMomentum {
      return nil
    }

    switch phase {
    case .began:
      reset()
      isTracking = true
    case .changed, .none:
      if !isTracking { isTracking = true }
    case .ended, .cancelled:
      reset()
      return nil
    }

    guard !hasTriggered, intent != .horizontal else { return nil }

    accumulatedVertical += verticalDelta
    accumulatedHorizontal += horizontalDelta

    if intent == .undecided {
      let verticalMagnitude = abs(accumulatedVertical)
      let horizontalMagnitude = abs(accumulatedHorizontal)
      guard max(verticalMagnitude, horizontalMagnitude) >= intentThreshold else { return nil }

      if verticalMagnitude >= horizontalMagnitude * dominanceRatio {
        intent = .vertical
      } else if horizontalMagnitude >= verticalMagnitude * dominanceRatio {
        intent = .horizontal
        return nil
      } else {
        return nil
      }
    }

    guard abs(accumulatedVertical) >= threshold else { return nil }

    hasTriggered = true
    return accumulatedVertical > 0 ? .expand : .collapse
  }

  mutating func reset() {
    accumulatedVertical = 0
    accumulatedHorizontal = 0
    hasTriggered = false
    isTracking = false
    intent = .undecided
  }

  private enum Intent: Equatable {
    case undecided
    case vertical
    case horizontal
  }
}

enum NotchSwipeEventNormalizer {
  static func phase(
    began: Bool,
    changed: Bool,
    ended: Bool,
    cancelled: Bool
  ) -> NotchSwipePhase {
    if began { return .began }
    if changed { return .changed }
    if ended { return .ended }
    if cancelled { return .cancelled }
    return .none
  }

  static func verticalDelta(
    reportedDelta: CGFloat,
    directionInvertedFromDevice: Bool
  ) -> CGFloat {
    let preferenceCompensation: CGFloat = directionInvertedFromDevice ? -1 : 1
    return -reportedDelta * preferenceCompensation
  }

  static func horizontalDelta(
    reportedDelta: CGFloat,
    directionInvertedFromDevice: Bool
  ) -> CGFloat {
    let preferenceCompensation: CGFloat = directionInvertedFromDevice ? -1 : 1
    return reportedDelta * preferenceCompensation
  }
}

@MainActor
final class NotchHostingView<Content: View>: NSHostingView<Content> {
  var canInterpretSwipe: () -> Bool = { false }
  var handleSwipeAction: (NotchSwipeAction) -> Bool = { _ in false }

  private var swipeInterpreter = NotchSwipeInterpreter()

  override func scrollWheel(with event: NSEvent) {
    guard event.hasPreciseScrollingDeltas, canInterpretSwipe() else {
      swipeInterpreter.reset()
      super.scrollWheel(with: event)
      return
    }

    let action = swipeInterpreter.interpret(
      phase: Self.phase(from: event.phase),
      verticalDelta: Self.deviceVerticalDelta(from: event),
      horizontalDelta: Self.deviceHorizontalDelta(from: event),
      isMomentum: !event.momentumPhase.isEmpty
    )

    if let action, handleSwipeAction(action) {
      return
    }
    super.scrollWheel(with: event)
  }

  private static func phase(from phase: NSEvent.Phase) -> NotchSwipePhase {
    NotchSwipeEventNormalizer.phase(
      began: phase.contains(.began),
      changed: phase.contains(.changed),
      ended: phase.contains(.ended),
      cancelled: phase.contains(.cancelled)
    )
  }

  // AppKit applies the user's scroll-direction preference to scrollingDelta.
  // Undo that preference, then invert Y so positive always means a physical
  // downward finger movement regardless of the Natural Scrolling setting.
  private static func deviceVerticalDelta(from event: NSEvent) -> CGFloat {
    NotchSwipeEventNormalizer.verticalDelta(
      reportedDelta: event.scrollingDeltaY,
      directionInvertedFromDevice: event.isDirectionInvertedFromDevice
    )
  }

  private static func deviceHorizontalDelta(from event: NSEvent) -> CGFloat {
    NotchSwipeEventNormalizer.horizontalDelta(
      reportedDelta: event.scrollingDeltaX,
      directionInvertedFromDevice: event.isDirectionInvertedFromDevice
    )
  }
}
