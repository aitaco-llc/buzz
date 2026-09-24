import Observation
import SwiftUI

/// Device-local appearance choices. These never enter relay events or account
/// data, and the snapshot is written as one atomic UserDefaults value.
@MainActor @Observable
final class NativePreferences {
  enum Scheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
      switch self {
      case .system: return "System"
      case .light: return "Light"
      case .dark: return "Dark"
      }
    }
  }

  enum Accent: String, CaseIterable, Identifiable {
    case aitaco, indigo, blue, purple, pink, orange, green, red
    var id: String { rawValue }
    var label: String { self == .aitaco ? "aitaco" : rawValue.capitalized }
    var color: Color {
      switch self {
      case .aitaco: Aitaco.accent
      case .indigo: .indigo
      case .blue: .blue
      case .purple: .purple
      case .pink: .pink
      case .orange: .orange
      case .green: .green
      case .red: .red
      }
    }
  }

  private struct Snapshot: Codable {
    let scheme: String
    let accent: String
    let mutedChannels: Set<String>
    let starredChannels: Set<String>

    init(scheme: String, accent: String, mutedChannels: Set<String>, starredChannels: Set<String>) {
      self.scheme = scheme
      self.accent = accent
      self.mutedChannels = mutedChannels
      self.starredChannels = starredChannels
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      scheme = try container.decode(String.self, forKey: .scheme)
      accent = try container.decode(String.self, forKey: .accent)
      mutedChannels = try container.decodeIfPresent(Set<String>.self, forKey: .mutedChannels) ?? []
      starredChannels =
        try container.decodeIfPresent(Set<String>.self, forKey: .starredChannels) ?? []
    }
  }

  private static let storageKey = "buzz.native.appearance.v1"
  private let defaults: UserDefaults
  private(set) var scheme: Scheme
  private(set) var accent: Accent
  private(set) var mutedChannels: Set<String>
  private(set) var starredChannels: Set<String>

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.storageKey),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    {
      scheme = Scheme(rawValue: snapshot.scheme) ?? .system
      accent = Accent(rawValue: snapshot.accent) ?? .aitaco
      mutedChannels = snapshot.mutedChannels
      starredChannels = snapshot.starredChannels
    } else {
      scheme = .system
      accent = .aitaco
      mutedChannels = []
      starredChannels = []
    }
  }

  var colorScheme: ColorScheme? {
    switch scheme {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }

  func setScheme(_ value: Scheme) {
    scheme = value
    persist()
  }

  func setAccent(_ value: Accent) {
    accent = value
    persist()
  }

  func setMuted(_ muted: Bool, channelID: String) {
    if muted { mutedChannels.insert(channelID) } else { mutedChannels.remove(channelID) }
    persist()
  }

  func setStarred(_ starred: Bool, channelID: String) {
    if starred { starredChannels.insert(channelID) } else { starredChannels.remove(channelID) }
    persist()
  }

  private func persist() {
    guard
      let data = try? JSONEncoder().encode(
        Snapshot(
          scheme: scheme.rawValue, accent: accent.rawValue,
          mutedChannels: mutedChannels, starredChannels: starredChannels
        )
      )
    else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}
