import Foundation

/// One image that travelled with a turn, and enough about it to draw it.
///
/// `attachedImages` counts image blocks; this list holds only those whose payload arrived
/// and decoded, so `images.count <= attachedImages`. The gap is the placeholder path: an
/// over-cap image, corrupt base64 or a host path leaves the `1 image` label standing alone.
public struct TranscriptImage: Hashable, Sendable, Identifiable {
  /// Where the pixels are.
  ///
  /// Not `Equatable` or `Hashable`, so nothing is tempted into the byte comparison that `==`
  /// below avoids. Tests and views read `inlineData` and `remotePath`.
  public enum Source: Sendable {
    /// The record's base64 payload, decoded. The form every real image block has taken.
    case inline(Data)
    /// A path on the host that would need fetching over SSH. Parsed and never drawn: the turn
    /// shows the count label, as for an over-cap image. No fetch exists, because no real
    /// session has produced this form. It stays parsed so adding a fetch needs no re-parse.
    case remote(path: String)
  }

  /// The turn's id (the record uuid) plus the image's position among the record's image
  /// blocks, as `TranscriptParser.mappedImages` counts. Stable across re-reads, which lets
  /// `==` compare ids instead of bytes. Counting image blocks, not all blocks, so a nearby
  /// text block changing cannot move the id.
  public let id: String
  /// The record's `media_type`, such as `image/png`. Empty when the record did not say.
  public let mediaType: String
  /// The decoded size in bytes for an `.inline` image, `0` for a `.remote` one.
  public let byteCount: Int
  public let source: Source

  /// The largest base64 payload that is decoded, measured as encoded text.
  ///
  /// The cap is applied before decoding, or it would allocate what it exists to refuse.
  /// 8 MiB of base64 is about 6 MiB of pixels, roughly twelve times the largest real image
  /// seen. It stops a pathological record from taking the phone's memory. Over the cap the
  /// image is absent and the `N images` label stands in.
  public static let maxEncodedBytes = 8 << 20

  public init(id: String, mediaType: String, byteCount: Int, source: Source) {
    self.id = id
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.source = source
  }

  /// The decoded bytes, or `nil` for an image that still lives on the host.
  public var inlineData: Data? {
    guard case .inline(let data) = source else { return nil }
    return data
  }

  /// The host path this image is at, or `nil` for one whose bytes already arrived.
  public var remotePath: String? {
    guard case .remote(let path) = source else { return nil }
    return path
  }

  /// Compares `id`, `mediaType` and `byteCount`, never the bytes.
  ///
  /// `PaneTranscriptModel` compares whole transcripts on every three-second watch tick
  /// (`drawsSame(_:as:)`, `TranscriptRender.rendering(_:reusing:)`). A synthesised `==` would
  /// `memcmp` every image in the page on each tick. It is sound because an id names one block
  /// of one record, so equal ids mean equal bytes, the same uuid assumption
  /// `TranscriptTurn.id` makes.
  public static func == (lhs: TranscriptImage, rhs: TranscriptImage) -> Bool {
    lhs.id == rhs.id && lhs.mediaType == rhs.mediaType && lhs.byteCount == rhs.byteCount
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(mediaType)
    hasher.combine(byteCount)
  }
}
