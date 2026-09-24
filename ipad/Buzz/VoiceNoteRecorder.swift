import AVFoundation
import Foundation

@MainActor
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
  private(set) var recorder: AVAudioRecorder?
  private(set) var fileURL: URL?

  var isRecording: Bool { recorder?.isRecording == true }

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetooth])
    try session.setActive(true)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("voice-\(UUID().uuidString).m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let next = try AVAudioRecorder(url: url, settings: settings)
    next.delegate = self
    next.record(forDuration: 300)
    recorder = next
    fileURL = url
  }

  func stop() -> URL? {
    recorder?.stop()
    recorder = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    return fileURL
  }

  func cancel() {
    recorder?.stop()
    recorder = nil
    if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    self.fileURL = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
