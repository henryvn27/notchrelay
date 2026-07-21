import CoreGraphics

enum NotchPullGesturePolicy {
  static let directTravel: CGFloat = 24
  static let distanceThreshold: CGFloat = 28
  static let predictedDistanceThreshold: CGFloat = 48

  static func shouldExpand(distance: CGFloat, predictedDistance: CGFloat) -> Bool {
    distance >= distanceThreshold || predictedDistance >= predictedDistanceThreshold
  }

  static func resistedDistance(for distance: CGFloat) -> CGFloat {
    guard distance > 0 else { return 0 }
    guard distance > directTravel else { return distance }
    return directTravel + (distance - directTravel) * 0.24
  }

  static func progress(for distance: CGFloat) -> CGFloat {
    min(1, max(0, resistedDistance(for: distance) / directTravel))
  }
}
