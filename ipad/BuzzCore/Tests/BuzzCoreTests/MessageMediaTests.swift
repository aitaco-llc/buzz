import Testing

@testable import BuzzCore

struct MessageMediaTests {
  @Test func parsesMetadataAndUsesMimeBeforeExtension() {
    let tags = [
      [
        "imeta", "url https://cdn.example/file.bin", "m image/webp", "dim 1200x600",
        "alt a picture", "duration nope", "size 42",
      ]
    ]
    let entries = MessageMedia.parseImetaTags(tags)
    let entry = entries["https://cdn.example/file.bin"]
    #expect(entry?.aspectRatio == 2)
    #expect(entry?.alt == "a picture")
    #expect(entry?.duration == nil)
    #expect(MessageMedia.classify(entry!.url, imeta: entry) == .image)
  }

  @Test func extractsBoundedDeduplicatedMediaURLs() {
    let text =
      "https://a.test/a.png, https://a.test/a.png https://b.test/v.mp4 https://c.test/s.m4a https://d.test/x.jpg https://e.test/too.png"
    #expect(
      MessageMedia.urls(in: text) == [
        "https://a.test/a.png", "https://b.test/v.mp4", "https://c.test/s.m4a",
        "https://d.test/x.jpg",
      ])
    #expect(MessageMedia.classify("https://x.test/file.mp4") == .video)
    #expect(MessageMedia.classify("https://x.test/file.m4a") == .audio)
  }
}
