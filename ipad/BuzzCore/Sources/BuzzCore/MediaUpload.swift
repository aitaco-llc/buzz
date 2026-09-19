import CryptoKit
import Foundation

/// Blossom BUD-02 response from the relay's upload endpoint.
public struct BlobDescriptor: Codable, Equatable, Sendable {
  public let url: String
  public let sha256: String
  public let size: Int
  public let type: String
  public let uploaded: Int
  public let dim: String?
  public let blurhash: String?
  public let thumb: String?
  public let duration: Double?

  public init(
    url: String, sha256: String, size: Int, type: String, uploaded: Int,
    dim: String? = nil, blurhash: String? = nil, thumb: String? = nil,
    duration: Double? = nil
  ) {
    self.url = url
    self.sha256 = sha256
    self.size = size
    self.type = type
    self.uploaded = uploaded
    self.dim = dim
    self.blurhash = blurhash
    self.thumb = thumb
    self.duration = duration
  }

  public func imetaTag(filename: String? = nil) -> [String] {
    ["imeta", "url \(url)", "m \(type)", "x \(sha256)", "size \(size)"]
      + (dim.map { ["dim \($0)"] } ?? [])
      + (blurhash.map { ["blurhash \($0)"] } ?? [])
      + (thumb.map { ["thumb \($0)"] } ?? [])
      + (duration.map { ["duration \($0)"] } ?? [])
      + (filename.map { ["filename \($0)"] } ?? [])
  }
}

/// Authenticated Blossom upload client. Requests are bounded before any body
/// is sent and retrying the same bytes produces the same BUD-11 hash.
public actor BlossomClient {
  public static let maxUploadBytes = 100 * 1024 * 1024
  private let community: Community
  private let identity: Identity
  private let session: URLSession

  public init(
    community: Community, identity: Identity,
    configuration: URLSessionConfiguration = .ephemeral
  ) {
    self.community = community
    self.identity = identity
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    session = URLSession(configuration: configuration)
  }

  public func upload(_ bytes: Data, mimeType: String) async throws -> BlobDescriptor {
    guard !bytes.isEmpty, bytes.count <= Self.maxUploadBytes else { throw BuzzError.capacity }
    guard mimeType.utf8.count <= 128, !mimeType.contains(where: { $0.isWhitespace }) else {
      throw BuzzError.invalidResponse
    }
    let hash = Hex.encode(SHA256.hash(data: bytes))
    let paths = ["upload", "media/upload"]
    var lastStatus = 0
    for path in paths {
      let endpoint = community.origin.appendingPathComponent(path)
      var request = URLRequest(url: endpoint)
      request.httpMethod = "PUT"
      request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
      request.setValue(hash, forHTTPHeaderField: "X-SHA-256")
      request.setValue(try uploadAuthorization(hash: hash), forHTTPHeaderField: "Authorization")
      let (data, response) = try await session.upload(for: request, from: bytes)
      guard let http = response as? HTTPURLResponse else { throw BuzzError.invalidResponse }
      if http.statusCode == 404 || http.statusCode == 405 {
        lastStatus = http.statusCode
        continue
      }
      guard (200...299).contains(http.statusCode) else { throw BuzzError.http(http.statusCode) }
      let descriptor = try JSONDecoder().decode(BlobDescriptor.self, from: data)
      guard descriptor.sha256 == hash, descriptor.size >= 0, descriptor.size <= Self.maxUploadBytes
      else {
        throw BuzzError.invalidResponse
      }
      return descriptor
    }
    throw BuzzError.http(lastStatus == 0 ? 404 : lastStatus)
  }

  private func uploadAuthorization(hash: String) throws -> String {
    let expiration = Int(Date().timeIntervalSince1970) + 600
    let server = community.origin.host.map { host in
      community.origin.port.map { "\(host):\($0)" } ?? host
    }
    let event = try identity.sign(
      kind: 24242, content: "Upload buzz-media",
      tags: [["t", "upload"], ["x", hash], ["expiration", "\(expiration)"]]
        + (server.map { [["server", $0]] } ?? []).flatMap { $0 })
    let encoded = try JSONEncoder().encode(event).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "Nostr \(encoded)"
  }
}
