import BuzzCore
import Foundation

struct InviteLink: Identifiable, Equatable, Sendable {
  let relay: URL
  let code: String

  var id: String { "\(relay.absoluteString)|\(code)" }
  var host: String { relay.host ?? relay.absoluteString }

  var shareURL: URL {
    guard var components = URLComponents(url: relay, resolvingAgainstBaseURL: false) else {
      return relay
    }
    components.path = "/invite/\(code)"
    return components.url ?? relay
  }

  static func parse(_ url: URL) -> InviteLink? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let code = components.path.split(separator: "/").last.map(String.init),
      !code.isEmpty
    else { return parseCustom(url) }

    guard ["https", "http"].contains(components.scheme?.lowercased()),
      components.path.split(separator: "/").count == 2,
      components.path.split(separator: "/").first == "invite",
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      let origin = originURL(components)
    else { return nil }
    return InviteLink(relay: origin, code: code)
  }

  private static func parseCustom(_ url: URL) -> InviteLink? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      ["buzz", "co.aitaco.buzz"].contains(components.scheme?.lowercased()), components.host == "join",
      let relayValue = components.queryItems?.first(where: { $0.name == "relay" })?.value,
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
      let relay = URL(string: relayValue),
      ["ws", "wss"].contains(relay.scheme?.lowercased()), relay.host != nil,
      relay.user == nil, relay.password == nil, relay.path.isEmpty || relay.path == "/",
      relay.query == nil, relay.fragment == nil,
      components.queryItems?.allSatisfy({ ["relay", "code", "policy_receipt"].contains($0.name) })
        == true,
      let origin = originURL(relay)
    else { return nil }
    return InviteLink(relay: origin, code: code)
  }

  private static func originURL(_ components: URLComponents) -> URL? {
    var copy = components
    copy.path = ""
    copy.query = nil
    copy.fragment = nil
    if copy.scheme?.lowercased() == "ws" { copy.scheme = "http" }
    if copy.scheme?.lowercased() == "wss" { copy.scheme = "https" }
    return copy.url
  }

  private static func originURL(_ url: URL) -> URL? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    return originURL(components)
  }
}
