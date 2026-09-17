import Darwin
import Foundation

/// Restriction authority exists only while a confirming app process holds its
/// exclusive lock. File contents and files left behind by old processes carry
/// no age information and cannot restrict a later launch.
public final class BuzzAgeRestrictionSession {
  /// Shared app-group file used only for process-owned locking.
  public static let fileName = "age-restriction-session.lock"
  private var descriptor: Int32 = -1

  /// Creates an unrestricted session.
  public init() {}

  deinit { release() }

  /// Called on the native bridge's serial queue after a confirmed restriction.
  public func restrict(containerURL: URL) throws {
    if descriptor >= 0 { return }
    let path = containerURL.appendingPathComponent(Self.fileName).path
    let opened = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard opened >= 0 else { throw Self.posixError() }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
      let error = Self.posixError()
      close(opened)
      throw error
    }
    descriptor = opened
  }

  /// Releases authority without requiring a successful filesystem write.
  public func release() {
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }

  /// A missing file, inaccessible container, or unknown OS error means allowed.
  /// A shared nonblocking probe conflicts only with a live exclusive holder.
  public static func isRestricted(containerURL: URL?) -> Bool {
    guard let containerURL else { return false }
    let opened = open(containerURL.appendingPathComponent(fileName).path, O_RDONLY)
    guard opened >= 0 else { return false }
    defer { close(opened) }
    if flock(opened, LOCK_SH | LOCK_NB) == 0 {
      flock(opened, LOCK_UN)
      return false
    }
    return errno == EWOULDBLOCK || errno == EAGAIN
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
