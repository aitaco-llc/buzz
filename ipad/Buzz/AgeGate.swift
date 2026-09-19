import DeclaredAgeRange
import SwiftUI
import UIKit

enum AgeGateState: Equatable {
  case allowed
  case restricted
}

func ageGateRestricts(upperBound: Int?) -> Bool {
  guard let upperBound else { return false }
  return upperBound >= 0 && upperBound < 18
}

@MainActor @Observable
final class AgeGate {
  var state: AgeGateState = .allowed
  private var requested = false

  func request() async {
    guard !requested else { return }
    requested = true
    guard #available(iOS 26.0, *) else { return }
    var controller: UIViewController?
    for _ in 0..<3 {
      controller = rootViewController()
      if controller != nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let controller else { return }
    do {
      let response = try await AgeRangeService.shared.requestAgeRange(ageGates: 18, in: controller)
      if case .sharing(let range) = response, ageGateRestricts(upperBound: range.upperBound) {
        state = .restricted
      }
    } catch {
      // The age service is intentionally fail-open when unavailable or declined.
    }
  }

  private func rootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) {
        return window.rootViewController
      }
    }
    return nil
  }
}

struct AgeRestrictionView: View {
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "lock").font(.system(size: 48)).accessibilityHidden(true)
      Text("Buzz is for people 18 and older").font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      Text("You must be 18 or older to use Buzz under Buzz’s Terms.")
        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding(32)
    .frame(maxWidth: 520)
    .accessibilityElement(children: .combine)
  }
}
