import BuzzCore
import SwiftUI

/// A participant's avatar, with the letter tile as its fallback.
///
/// Shape carries meaning here and matches Flutter's `avatar_image.dart`: an
/// agent is a rounded rectangle, a person is a circle. That is the only way to
/// tell the two apart at a glance in a channel full of both, so the shape comes
/// from the *verified* NIP-OA owner rather than from a name or a guess.
struct Avatar: View {
  let profile: UserProfile
  let loader: MediaLoader
  var size: CGFloat = 36

  private var isAgent: Bool { profile.isAgent }
  private var cornerRadius: CGFloat { size * 0.3 }

  var body: some View {
    MediaImage(url: profile.pictureURL, loader: loader, maxPixel: size * 3) {
      tile
    } failure: {
      tile
    }
    .scaledToFill()
    .frame(width: size, height: size)
    .clipShape(shape)
    .accessibilityHidden(true)
  }

  private var shape: AnyShape {
    isAgent ? AnyShape(RoundedRectangle(cornerRadius: cornerRadius)) : AnyShape(Circle())
  }

  /// The initial, shown while the avatar loads and when there is none.
  private var tile: some View {
    Text(profile.initial)
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(Aitaco.accent)
      .frame(width: size, height: size)
      .background(Aitaco.accent.opacity(0.12), in: shape)
  }
}

extension Avatar {
  /// Resolves the profile from the workspace before drawing.
  init(workspace: Workspace, pubkey: String, size: CGFloat = 36) {
    self.init(
      profile: workspace.profiles.profile(pubkey: pubkey, events: workspace.events),
      loader: workspace.media, size: size)
  }
}
