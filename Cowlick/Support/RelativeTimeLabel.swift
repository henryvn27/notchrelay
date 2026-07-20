import AppKit
import SwiftUI

@MainActor
enum RelativeTimeLabel {
  static func string(
    for date: Date,
    relativeTo referenceDate: Date,
    locale: Locale = .autoupdatingCurrent,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    if abs(date.timeIntervalSince(referenceDate)) < 5 {
      return "just now"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.dateTimeStyle = .numeric
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: referenceDate)
  }
}

struct MenuPresentationObserver: NSViewRepresentable {
  let presented: @MainActor () -> Void

  func makeNSView(context _: Context) -> ObserverView {
    ObserverView(presented: presented)
  }

  func updateNSView(_ view: ObserverView, context _: Context) {
    view.presented = presented
  }

  @MainActor
  final class ObserverView: NSView {
    var presented: @MainActor () -> Void
    private weak var observedWindow: NSWindow?
    private let refreshInterval: TimeInterval
    nonisolated(unsafe) private var refreshTimer: Timer?

    init(
      refreshInterval: TimeInterval = 60,
      presented: @escaping @MainActor () -> Void
    ) {
      self.refreshInterval = refreshInterval
      self.presented = presented
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observeWindow()
    }

    deinit {
      refreshTimer?.invalidate()
      NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowOcclusionChanged() {
      updatePresentationVisibility(observedWindow?.occlusionState.contains(.visible) == true)
    }

    private func observeWindow() {
      NotificationCenter.default.removeObserver(self)
      observedWindow = window
      guard let window else { return }
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowOcclusionChanged),
        name: NSWindow.didChangeOcclusionStateNotification,
        object: window
      )
      windowOcclusionChanged()
    }

    func updatePresentationVisibility(_ isVisible: Bool) {
      guard isVisible else {
        refreshTimer?.invalidate()
        refreshTimer = nil
        return
      }

      presented()
      guard refreshTimer == nil else { return }
      let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.presented()
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      refreshTimer = timer
    }

    var hasActiveRefreshTimer: Bool {
      refreshTimer?.isValid == true
    }
  }
}
