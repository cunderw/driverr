import Foundation

/// The name a picked file is given where it lands.
///
/// The original name comes from the reader's own Files, so it can hold spaces, Unicode, a path
/// separator or a leading dot. The host's inbox is shared and a machine's core keeps the name
/// it is given, so the name is reduced to a safe set and prefixed with a token, which keeps two
/// `notes.txt` from two phones apart. Photos keep their own `uuid.png`.
public enum AttachmentFileName {
  /// The longest the original's part of the name may be, in bytes. The sanitised name is
  /// ASCII, so bytes and characters agree.
  public static let maximumBytes = 120

  /// What is left when nothing of the original survives.
  public static let fallback = "file"

  /// `<8 hex>-<sanitised original>`.
  ///
  /// The original keeps only its last path component. Every run of characters outside
  /// `[A-Za-z0-9._-]` becomes one `-`, leading dots and dashes go, and the result is cut to
  /// ``maximumBytes`` with its extension kept.
  public static func remote(original: String, unique: UUID) -> String {
    let token = unique.uuidString.lowercased().filter { $0 != "-" }.prefix(8)
    return "\(token)-\(sanitised(original))"
  }

  /// The original's part of ``remote(original:unique:)``.
  public static func sanitised(_ original: String) -> String {
    // The last component of either separator, so `../x` and `a\b` cannot climb or nest.
    let component =
      original.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""

    var collapsed = ""
    var lastWasReplaced = false
    for scalar in component.unicodeScalars {
      if isAllowed(scalar) {
        collapsed.unicodeScalars.append(scalar)
        lastWasReplaced = false
      } else if !lastWasReplaced {
        collapsed.append("-")
        lastWasReplaced = true
      }
    }

    // The extension is the last dot and what follows, when there is something after it and
    // something before it. `.env` is all stem.
    var stem = Substring(collapsed)
    var ext = Substring("")
    if let dot = collapsed.lastIndex(of: "."), dot != collapsed.startIndex,
      collapsed.index(after: dot) != collapsed.endIndex
    {
      stem = collapsed[..<dot]
      ext = collapsed[dot...]
    }
    // A leading dot would hide the file; a leading dash reads as an option to a command that
    // is handed the name on its own. A stem with nothing left is the fallback, so `日本語.txt`
    // is still a `.txt`.
    let trimmed = stem.drop(while: { $0 == "." || $0 == "-" })
    return cap(stem: trimmed.isEmpty ? Substring(fallback) : trimmed, ext: ext)
  }

  private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": true
    default: false
    }
  }

  /// Cuts the stem, not the extension, so `.log` stays `.log`. An extension too long to be one
  /// is cut with the rest. Both are ASCII by now, so a character is a byte.
  private static func cap(stem: Substring, ext: Substring) -> String {
    let name = String(stem + ext)
    guard name.utf8.count > maximumBytes else { return name }
    guard ext.count <= 16 else { return String(name.prefix(maximumBytes)) }
    return String(stem.prefix(maximumBytes - ext.count)) + ext
  }
}

/// How large a picked file may be, by where it goes.
public enum AttachmentLimit {
  /// The SSH host's inbox. The bytes are read into memory before they are sent, so a limit
  /// keeps a picked video from taking the app down with it.
  public static let host = 50_000_000
  /// A machine a herdr-core added: the most raw bytes one `terminal.put` takes, as the core's
  /// own `put::MAX_BYTES` has it.
  public static let machine = 8 << 20

  /// The limit for a place.
  public static func limit(for place: PaneAttachmentPlace) -> Int {
    switch place {
    case .host: host
    case .machine: machine
    }
  }
}

/// What reading a picked file came to.
public enum PickedFileOutcome: Equatable, Sendable {
  case contents(Data)
  /// Not a file Driverr can send: a folder, or a read that failed.
  case unreadable
  /// Over `limit`, known before anything was read.
  case tooLarge(limit: Int)
}

/// Reads a file the document picker handed over.
///
/// The URL is security-scoped: access is started before anything touches it and stopped on
/// every way out, a throwing read included. Every step is a closure, so `swift test` can prove
/// that without a picker.
public enum PickedFileReader {
  /// What the size check reads.
  public struct Attributes: Sendable {
    public let byteCount: Int?
    public let isDirectory: Bool

    public init(byteCount: Int?, isDirectory: Bool) {
      self.byteCount = byteCount
      self.isDirectory = isDirectory
    }
  }

  /// Reads `url` whole, or says why not.
  ///
  /// - Parameters:
  ///   - start: starts security-scoped access, `true` when it was started and needs stopping.
  ///   - stop: stops it. Called once, and only after a `start` that returned `true`.
  ///   - read: the read itself, never called for a folder or for a file over `limit`.
  ///   - size: the file's size and kind, read before `read`.
  public static func read(
    url: URL,
    limit: Int,
    start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
    stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
    read: (URL) throws -> Data = readUnmapped,
    size: (URL) throws -> Attributes = attributes
  ) -> PickedFileOutcome {
    let started = start(url)
    defer { if started { stop(url) } }

    guard let attributes = try? size(url), !attributes.isDirectory else { return .unreadable }
    // Before the read, so a file over the limit is never loaded.
    if let byteCount = attributes.byteCount, byteCount > limit { return .tooLarge(limit: limit) }
    guard let data = try? read(url) else { return .unreadable }
    // The size can be missing, or the file can grow between the two reads.
    guard data.count <= limit else { return .tooLarge(limit: limit) }
    return .contents(data)
  }

  /// `Data(contentsOf:)` with no options, so it is never mapped: a mapped file is read lazily,
  /// after `stop` has ended access, and faults then.
  public static func readUnmapped(_ url: URL) throws -> Data {
    try Data(contentsOf: url, options: [])
  }

  public static func attributes(_ url: URL) throws -> Attributes {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
    return Attributes(byteCount: values.fileSize, isDirectory: values.isDirectory ?? false)
  }
}
