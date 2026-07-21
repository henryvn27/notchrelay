import Foundation

enum APICostWindow: String, CaseIterable, Identifiable, Sendable {
  case today
  case last30Days
  case monthToDate

  var id: String { rawValue }

  var label: String {
    switch self {
    case .today: "Today"
    case .last30Days: "Last 30 days"
    case .monthToDate: "Month to date"
    }
  }

  func interval(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
    let start: Date
    switch self {
    case .today:
      start = calendar.startOfDay(for: now)
    case .last30Days:
      let today = calendar.startOfDay(for: now)
      start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
    case .monthToDate:
      start = calendar.dateInterval(of: .month, for: now)?.start ?? now
    }
    return DateInterval(start: start, end: max(now, start.addingTimeInterval(0.001)))
  }
}
