import Foundation

/// What POSIX `cksum` prints for a file: its CRC and its length in bytes.
///
/// Computed here too, so the phone can check the bytes it received are the ones the host
/// checksummed. A non-UTF-8 file, or one that changed between `cksum` and `cat`, arrives as
/// different bytes, and writing an edit of those back would change the file where Driverr
/// never meant to.
public struct POSIXChecksum: Hashable, Sendable {
  public let crc: UInt32
  public let byteCount: Int

  public init(crc: UInt32, byteCount: Int) {
    self.crc = crc
    self.byteCount = byteCount
  }

  /// The CRC POSIX specifies for `cksum`: polynomial 0x04C11DB7, most significant bit
  /// first, over the data and then the length's bytes, least significant first, with no
  /// zero bytes past the highest non-zero one, and the result inverted.
  public init(of bytes: some Sequence<UInt8>) {
    var crc: UInt32 = 0
    var count = 0
    for byte in bytes {
      crc = (crc << 8) ^ Self.table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
      count += 1
    }
    var length = count
    while length > 0 {
      crc = (crc << 8) ^ Self.table[Int(((crc >> 24) ^ UInt32(length & 0xFF)) & 0xFF)]
      length >>= 8
    }
    self.init(crc: ~crc, byteCount: count)
  }

  /// `cksum`'s own output without a file name: `"<crc> <bytes>"`.
  public var text: String { "\(crc) \(byteCount)" }

  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index) << 24
    for _ in 0..<8 {
      value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
    }
    return value
  }
}
