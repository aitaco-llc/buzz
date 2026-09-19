import BuzzCore
import SwiftUI

actor EmojiCatalogStore {
  static let shared = EmojiCatalogStore()
  private var catalog: EmojiCatalog?
  func load() throws -> EmojiCatalog {
    if let catalog { return catalog }
    guard let url = Bundle.main.url(forResource: "emoji-data", withExtension: "json") else {
      throw BuzzError.storage("The emoji catalog is unavailable.")
    }
    let loaded = try EmojiCatalog(data: Data(contentsOf: url))
    catalog = loaded
    return loaded
  }
}

struct ReactionPicker: View {
  @Bindable var workspace: Workspace
  let message: Event
  @Environment(\.dismiss) private var dismiss
  @State private var catalog: EmojiCatalog?
  @State private var results: [EmojiEntry] = []
  @State private var query = ""
  @State private var category = ""
  @State private var limit = 200
  @State private var loadID = UUID()
  @State private var error: String?
  @State private var selecting = false
  private let columns = [GridItem(.adaptive(minimum: 54), spacing: 10)]

  private var custom: [CustomEmoji] {
    if query.isEmpty { return workspace.customEmoji }
    return workspace.customEmoji.compactMap { item -> (CustomEmoji, Int, Int)? in
      EmojiCatalog.shortcodeScore(query, code: item.shortcode).map { (item, $0.0, $0.1) }
    }.sorted { ($0.1, $0.2, $0.0.shortcode) < ($1.1, $1.2, $1.0.shortcode) }.map(\.0)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let error { Text(error).foregroundStyle(.red) }
          if let error = workspace.emojiError {
            Text("Community emoji: \(error)").font(.callout).foregroundStyle(.secondary)
            Button("Retry community emoji") { Task { await workspace.refreshCustomEmoji() } }
          }
          if query.isEmpty {
            Text("Frequently used").font(.headline)
            LazyVGrid(columns: columns) {
              ForEach(quick, id: \.self) { value in
                tile(
                  value: value, name: value,
                  url: workspace.customEmoji.first { $0.value == value }?.url)
              }
            }
          }
          if !custom.isEmpty {
            Text("Community emoji").font(.headline)
            LazyVGrid(columns: columns) {
              ForEach(custom.prefix(limit)) { item in
                tile(value: item.value, name: item.shortcode, url: item.url)
              }
            }
          }
          if let catalog {
            Picker("Category", selection: $category) {
              Text("All emoji").tag("")
              ForEach(catalog.categories, id: \.self) { id in Text(categoryName(id)).tag(id) }
            }.pickerStyle(.menu)
            LazyVGrid(columns: columns) {
              ForEach(results.prefix(limit)) { item in
                tile(value: item.glyph, name: item.name, url: nil)
              }
            }
            if results.isEmpty && custom.isEmpty {
              Text("No matching emoji").foregroundStyle(.secondary)
            }
            if results.count > limit || custom.count > limit {
              Button("Show more emoji") { limit += 200 }
            }
          } else if error == nil {
            ProgressView("Loading emoji…")
          } else {
            Button("Retry emoji catalog") { loadID = UUID() }
          }
        }.padding()
      }
      .searchable(
        text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji"
      )
      .navigationTitle("Add reaction")
      .toolbar { Button("Cancel") { dismiss() } }
      .task(id: loadID) {
        async let community: Void = workspace.refreshCustomEmoji()
        do {
          let result = try await EmojiCatalogStore.shared.load()
          try Task.checkCancellation()
          catalog = result
          error = nil
        } catch is CancellationError { return } catch { self.error = error.localizedDescription }
        await community
      }
      .task(id: "\(query)/\(category)/\(catalog?.entries.count ?? 0)") {
        guard let catalog else { return }
        let query = query
        let category = category.isEmpty ? nil : category
        let matches = await Task.detached { catalog.search(query, category: category) }.value
        guard !Task.isCancelled else { return }
        results = matches
        limit = 200
      }
    }
  }

  private var quick: [String] {
    var seen = Set<String>()
    return Array(
      (workspace.intents.recentEmoji.map(\.value) + ["👍", "❤️", "😂", "🎉", "🔥"])
        .filter { seen.insert($0).inserted }.prefix(12))
  }

  private func tile(value: String, name: String, url: URL?) -> some View {
    Button {
      selecting = true
      Task {
        if await workspace.react(to: message, value: value, imageURL: url) {
          dismiss()
        } else {
          error = workspace.error ?? "The reaction could not be saved. Try again."
        }
        selecting = false
      }
    } label: {
      ReactionGlyph(value: value, url: url).frame(maxWidth: .infinity, minHeight: 48)
    }
    .buttonStyle(.bordered)
    .disabled(selecting)
    .accessibilityLabel("React with \(name) \(value)")
    .accessibilityIdentifier("emoji-choice-\(value)")
  }

  private func categoryName(_ id: String) -> String {
    [
      "people": "Smileys & People", "nature": "Animals & Nature", "foods": "Food & Drink",
      "activity": "Activity", "places": "Travel & Places", "objects": "Objects",
      "symbols": "Symbols", "flags": "Flags",
    ][id] ?? id
  }
}
