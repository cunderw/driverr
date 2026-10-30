import Foundation

/// One frame of herdr-core's framed mode: `[channel u32 LE][kind u8][len u32 LE][payload]`.
///
/// Channel 0 carries JSON-RPC both ways. Other channels are attach and event streams.
struct CoreFrame: Equatable, Sendable {
  /// Every kind generation 1 defines. `CoreFrameDecoder` skips any other, because within a
  /// generation the API only grows.
  enum Kind: UInt8, Sendable {
    case data = 0
    case credit = 1
    case close = 2
    case resize = 3
    case focus = 4
    case facts = 5
  }

  static let headerSize = 9
  /// The protocol's bound, and this build's: a longer frame means the stream is not what it
  /// claims to be, so nothing waits for its payload.
  static let maximumPayload = 16 * 1024 * 1024

  let channel: UInt32
  let kind: Kind
  let payload: Data

  var encoded: Data {
    var bytes = Data(capacity: Self.headerSize + payload.count)
    withUnsafeBytes(of: channel.littleEndian) { bytes.append(contentsOf: $0) }
    bytes.append(kind.rawValue)
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) { bytes.append(contentsOf: $0) }
    bytes.append(payload)
    return bytes
  }
}

/// Turns the chunks an exec channel delivers into whole frames.
///
/// A chunk's edges say nothing about a frame's. One read can hold half a header or three
/// frames.
struct CoreFrameDecoder {
  struct PayloadTooLarge: Error, Equatable {
    let length: Int
  }

  private var buffer = Data()

  /// Takes the next chunk and returns every frame it completed, in order.
  ///
  /// Throws as soon as a header declares a payload over the bound, without waiting for it.
  /// The caller must end the connection then, because nothing past that header can be
  /// trusted to be a boundary.
  mutating func append(_ chunk: Data) throws -> [CoreFrame] {
    buffer.append(chunk)

    var frames: [CoreFrame] = []
    // `Data` is indexed from `startIndex`, which is not 0 on a slice.
    var offset = buffer.startIndex
    while buffer.endIndex - offset >= CoreFrame.headerSize {
      let length = Int(littleEndian32(at: offset + 5))
      guard length <= CoreFrame.maximumPayload else { throw PayloadTooLarge(length: length) }

      let payloadStart = offset + CoreFrame.headerSize
      let end = payloadStart + length
      guard end <= buffer.endIndex else { break }

      // An unknown kind is skipped by its length, so a newer core's frame costs only itself.
      if let kind = CoreFrame.Kind(rawValue: buffer[offset + 4]) {
        frames.append(
          CoreFrame(
            channel: littleEndian32(at: offset),
            kind: kind,
            payload: Data(buffer[payloadStart..<end])
          )
        )
      }
      offset = end
    }

    // A copy, not `buffer[offset...]`, which would keep every consumed byte alive.
    if offset > buffer.startIndex { buffer = Data(buffer[offset...]) }
    return frames
  }

  private func littleEndian32(at offset: Int) -> UInt32 {
    (0..<4).reduce(into: UInt32(0)) { value, byte in
      value |= UInt32(buffer[offset + byte]) << (8 * UInt32(byte))
    }
  }
}
