import BuzzCore
import SwiftUI

/// This build is aitaco's client for one community, on buzz.aitaco.co. It
/// mirrors the iPhone app (`mobile/lib/shared/community/aitaco_community.dart`).
///
/// Pairing, invites and manual connections for any other relay are refused,
/// and there is no community switcher. Accounts are still stored as a list,
/// so the storage model is unchanged.
enum Aitaco {
  static let relayHost = "buzz.aitaco.co"
  static let relayURL = "https://\(relayHost)"
  static let communityName = "aitaco"
  static let foreignCommunityMessage =
    "This app only connects to the aitaco community on \(relayHost)."

  /// Whether `community` is aitaco's. Debug builds also accept a local relay.
  static func allows(_ community: Community) -> Bool {
    let origin = community.origin
    if origin.scheme == "https", origin.port == nil, origin.host == relayHost { return true }
    #if DEBUG
      return origin.scheme == "http"
    #else
      return false
    #endif
  }

  /// aitaco's community, or a refusal naming the relay this app serves.
  static func require(_ community: Community) throws -> Community {
    guard allows(community) else { throw ForeignCommunityError() }
    guard community.origin.host == relayHost else { return community }
    return try Community(url: relayURL, name: communityName)
  }

  // aitaco.co's teal (the mark's disc), fading to a pale teal shell. Same
  // stops as the iPhone onboarding and first-party theme.
  static let teal = Color(red: 0x71 / 255, green: 0xBE / 255, blue: 0xC4 / 255)
  static let shell = Color(red: 0xE6 / 255, green: 0xF4 / 255, blue: 0xF5 / 255)
  static let ink = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)
  static let lightTop = Color(red: 0xBF / 255, green: 0xE3 / 255, blue: 0xE6 / 255)
  static let lightBottom = Color(red: 0xDD / 255, green: 0xE9 / 255, blue: 0xEE / 255)
  static let darkTop = Color(red: 0x17 / 255, green: 0x47 / 255, blue: 0x4A / 255)
  static let darkBottom = Color(red: 0x0A / 255, green: 0x14 / 255, blue: 0x23 / 255)
  /// Deep teal behind white text, such as unread badges (about 5.2:1).
  static let deepTeal = Color(red: 0x26 / 255, green: 0x78 / 255, blue: 0x7E / 255)
  /// Tint for controls and links. The mark's teal is too light for text on
  /// white (about 2.2:1), so light mode uses a deeper teal (about 5.2:1).
  static let accent = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0x71 / 255, green: 0xBE / 255, blue: 0xC4 / 255, alpha: 1)
        : UIColor(red: 0x26 / 255, green: 0x78 / 255, blue: 0x7E / 255, alpha: 1)
    })

  /// Resources shipped with this UI: the package bundle in the universal
  /// app, the app bundle in the standalone iPad project.
  static var resources: Bundle {
    #if SWIFT_PACKAGE
      Bundle.module
    #else
      Bundle.main
    #endif
  }
}

/// A pairing code, invite or connection named a relay other than aitaco's.
struct ForeignCommunityError: LocalizedError {
  var errorDescription: String? { Aitaco.foreignCommunityMessage }
}

/// The aitaco robot-taco mark: white on a teal disc, as on aitaco.co.
struct AitacoMark: View {
  var size: CGFloat

  var body: some View {
    Group {
      if let image = UIImage(named: "aitaco-mark", in: Aitaco.resources, with: nil) {
        Image(uiImage: image).resizable().interpolation(.medium)
      } else {
        Circle().fill(Aitaco.teal)
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("aitaco")
  }
}

/// The top-section gradient of the aitaco theme, for light and dark.
struct AitacoGradient: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LinearGradient(
      colors: colorScheme == .dark
        ? [Aitaco.darkTop, Aitaco.darkBottom] : [Aitaco.lightTop, Aitaco.lightBottom],
      startPoint: .top, endPoint: .bottom)
  }
}
