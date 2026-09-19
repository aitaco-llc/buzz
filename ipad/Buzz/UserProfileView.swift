import BuzzCore
import SwiftUI

struct UserProfileView: View {
  let workspace: Workspace
  let pubkey: String
  @Environment(\.dismiss) private var dismiss

  private var profile: Event? {
    workspace.events.filter { $0.kind == 0 && $0.pubkey == pubkey }
      .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }

  private var fields: [String: Any] {
    guard let data = profile?.content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }

  private var avatarURL: URL? { (fields["picture"] as? String).flatMap(URL.init(string:)) }
  private var about: String { fields["about"] as? String ?? "" }
  private var status: Event? {
    workspace.events.filter { $0.kind == 30315 && $0.pubkey == pubkey && $0.tag("d") == "general" }
      .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
              if case .success(let image) = phase {
                image.resizable().scaledToFill()
              } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().padding(18)
                  .foregroundStyle(.secondary)
              }
            }
            .frame(width: 96, height: 96).clipShape(Circle())
            .accessibilityLabel("Profile picture")
          } else {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 80)).foregroundStyle(
              .secondary
            )
            .accessibilityHidden(true)
          }
          Text(workspace.name(pubkey)).font(.title2.weight(.semibold))
          if let status, !status.content.isEmpty || status.tag("emoji") != nil {
            HStack(spacing: 6) {
              Text(status.tag("emoji") ?? "")
              Text(status.content)
            }
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
          }
          if !about.isEmpty { Text(about).frame(maxWidth: .infinity, alignment: .leading) }
          VStack(alignment: .leading, spacing: 6) {
            Text("Public key").font(.caption).foregroundStyle(.secondary)
            Text(pubkey).font(.caption.monospaced()).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding()
      }
      .navigationTitle("Profile")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
  }
}
