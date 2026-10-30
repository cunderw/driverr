import Foundation
import Testing

@testable import DriverrHC

@Suite("Core frames")
struct CoreFrameTests {
  private let first = CoreFrame(channel: 0, kind: .data, payload: Data("{\"id\":2}".utf8))
  private let second = CoreFrame(channel: 7, kind: .close, payload: Data("{}".utf8))
  private let empty = CoreFrame(channel: 3, kind: .data, payload: Data())

  @Test("the header is channel, kind and length, little-endian")
  func wireShape() {
    let frame = CoreFrame(channel: 0x0102_0304, kind: .resize, payload: Data([0xAA]))
    #expect(
      Array(frame.encoded) == [0x04, 0x03, 0x02, 0x01, 3, 0x01, 0, 0, 0, 0xAA]
    )
  }

  @Test("a frame split at every byte comes back whole, once")
  func splitFrames() throws {
    let bytes = first.encoded + second.encoded + empty.encoded
    var decoder = CoreFrameDecoder()
    var frames: [CoreFrame] = []
    for byte in bytes {
      frames += try decoder.append(Data([byte]))
    }
    #expect(frames == [first, second, empty])
  }

  @Test("frames coalesced into one chunk all come back, in order")
  func coalescedFrames() throws {
    var decoder = CoreFrameDecoder()
    let frames = try decoder.append(first.encoded + second.encoded + empty.encoded)
    #expect(frames == [first, second, empty])
  }

  @Test("a chunk ending mid-frame keeps the tail for the next chunk")
  func tailCarriesOver() throws {
    let bytes = first.encoded + second.encoded
    let cut = first.encoded.count + 4
    var decoder = CoreFrameDecoder()
    #expect(try decoder.append(Data(bytes[..<cut])) == [first])
    #expect(try decoder.append(Data(bytes[cut...])) == [second])
  }

  @Test("a chunk that is a Data slice reads from its own start index")
  func sliceIndices() throws {
    let padded = Data([0xFF, 0xFF, 0xFF]) + first.encoded
    let slice = padded[3...]
    #expect(slice.startIndex == 3)
    var decoder = CoreFrameDecoder()
    #expect(try decoder.append(slice) == [first])
  }

  @Test("an unknown kind is skipped by its length and costs nothing else")
  func unknownKind() throws {
    var unknown = CoreFrame(channel: 0, kind: .data, payload: Data("new".utf8)).encoded
    unknown[4] = 200
    var decoder = CoreFrameDecoder()
    #expect(try decoder.append(unknown + first.encoded) == [first])
  }

  @Test("a payload of exactly the bound is a frame")
  func atTheBound() throws {
    let frame = CoreFrame(
      channel: 1, kind: .data, payload: Data(count: CoreFrame.maximumPayload))
    var decoder = CoreFrameDecoder()
    #expect(try decoder.append(frame.encoded).first?.payload.count == CoreFrame.maximumPayload)
  }

  @Test("one byte over the bound fails on the header, without waiting for the payload")
  func overTheBound() {
    var header = CoreFrame(channel: 0, kind: .data, payload: Data()).encoded
    let length = UInt32(CoreFrame.maximumPayload + 1)
    header.replaceSubrange(5..<9, with: withUnsafeBytes(of: length.littleEndian) { Data($0) })
    var decoder = CoreFrameDecoder()
    #expect(throws: CoreFrameDecoder.PayloadTooLarge(length: Int(length))) {
      try decoder.append(header)
    }
  }
}
