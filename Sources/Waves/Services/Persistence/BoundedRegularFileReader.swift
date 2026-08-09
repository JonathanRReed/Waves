import Darwin
import Foundation

enum BoundedRegularFileReaderError: Error, Equatable {
  case missing
  case symbolicLink
  case notRegularFile
  case metadataFailed(Int32)
  case openFailed(Int32)
  case identityChanged
  case fileTooLarge(actual: Int, maximum: Int)
  case readFailed(Int32)
  case permissionsFailed(Int32)

  var shouldPreserveAtPath: Bool {
    switch self {
    case .fileTooLarge, .readFailed, .permissionsFailed:
      true
    case .missing, .symbolicLink, .notRegularFile, .metadataFailed, .openFailed, .identityChanged:
      false
    }
  }
}

extension BoundedRegularFileReaderError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .missing:
      "The file does not exist."
    case .symbolicLink:
      "Symbolic links are not accepted."
    case .notRegularFile:
      "The selected item is not a regular file."
    case .metadataFailed(let code):
      "File metadata could not be read (errno \(code))."
    case .openFailed(let code):
      "The file could not be opened safely (errno \(code))."
    case .identityChanged:
      "The file changed while it was being read."
    case .fileTooLarge(let actual, let maximum):
      "The file is \(actual) bytes, exceeding the \(maximum)-byte limit."
    case .readFailed(let code):
      "The file could not be read (errno \(code))."
    case .permissionsFailed(let code):
      "Private file permissions could not be applied (errno \(code))."
    }
  }
}

/// Reads one stable regular-file identity through a no-follow descriptor. The
/// descriptor is nonblocking before the file type is trusted, so a FIFO or
/// device can never stall the caller. At most `maximumBytes + 1` bytes are read.
enum BoundedRegularFileReader {
  private static let chunkSize = 64 * 1024

  static func read(
    from url: URL,
    maximumBytes: Int,
    requiredPermissions: mode_t? = nil
  ) throws -> Data {
    let maximumBytes = max(0, maximumBytes)
    var initial = stat()
    guard lstat(url.path, &initial) == 0 else {
      if errno == ENOENT { throw BoundedRegularFileReaderError.missing }
      throw BoundedRegularFileReaderError.metadataFailed(errno)
    }
    let initialType = initial.st_mode & S_IFMT
    guard initialType != S_IFLNK else { throw BoundedRegularFileReaderError.symbolicLink }
    guard initialType == S_IFREG else { throw BoundedRegularFileReaderError.notRegularFile }
    guard initial.st_size <= off_t(maximumBytes) else {
      throw BoundedRegularFileReaderError.fileTooLarge(
        actual: Int(clamping: initial.st_size),
        maximum: maximumBytes
      )
    }

    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw BoundedRegularFileReaderError.openFailed(errno) }
    defer { _ = Darwin.close(descriptor) }

    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else {
      throw BoundedRegularFileReaderError.metadataFailed(errno)
    }
    guard isSameRegularFile(initial, opened) else {
      throw BoundedRegularFileReaderError.identityChanged
    }
    if let requiredPermissions, fchmod(descriptor, requiredPermissions) != 0 {
      throw BoundedRegularFileReaderError.permissionsFailed(errno)
    }

    var data = Data()
    data.reserveCapacity(min(maximumBytes, max(0, Int(clamping: opened.st_size))))
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let remaining = maximumBytes - data.count + 1
      let requested = min(buffer.count, remaining)
      let count = Darwin.read(descriptor, &buffer, requested)
      if count > 0 {
        data.append(contentsOf: buffer[0..<count])
        guard data.count <= maximumBytes else {
          throw BoundedRegularFileReaderError.fileTooLarge(
            actual: data.count,
            maximum: maximumBytes
          )
        }
        continue
      }
      if count == 0 { break }
      if errno == EINTR { continue }
      throw BoundedRegularFileReaderError.readFailed(errno)
    }

    var completed = stat()
    guard fstat(descriptor, &completed) == 0 else {
      throw BoundedRegularFileReaderError.metadataFailed(errno)
    }
    var currentPath = stat()
    guard lstat(url.path, &currentPath) == 0,
      isSameRegularFile(initial, completed),
      isSameRegularFile(initial, currentPath)
    else { throw BoundedRegularFileReaderError.identityChanged }
    return data
  }

  private static func isSameRegularFile(_ lhs: stat, _ rhs: stat) -> Bool {
    rhs.st_mode & S_IFMT == S_IFREG
      && lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
  }
}
