import DriverrCore
import Foundation
import Testing

/// `TranscriptImage`'s equality ignores the bytes. A synthesised `==` passes every
/// functional test and costs a `memcmp` of every image on each watch tick.
struct TranscriptImageTests {
  private func inline(_ id: String, _ bytes: [UInt8], mediaType: String = "image/png")
    -> TranscriptImage
  {
    let data = Data(bytes)
    return TranscriptImage(
      id: id, mediaType: mediaType, byteCount: data.count, source: .inline(data))
  }

  @Test("equality ignores the bytes")
  func equalityIgnoresTheBytes() {
    let one = inline("turn-1#image0", [1, 2, 3, 4])
    let other = inline("turn-1#image0", [9, 9, 9, 9])
    #expect(one == other)
    #expect(one.hashValue == other.hashValue)
  }

  @Test("two images of one turn are not equal")
  func differentImagesOfOneTurnDiffer() {
    #expect(inline("turn-1#image0", [1, 2]) != inline("turn-1#image1", [1, 2]))
  }

  @Test("a size that changed is a different image")
  func sizeCounts() {
    #expect(inline("turn-1#image0", [1, 2]) != inline("turn-1#image0", [1, 2, 3]))
  }

  @Test("a media type that changed is a different image")
  func mediaTypeCounts() {
    let png = inline("turn-1#image0", [1, 2])
    let jpeg = inline("turn-1#image0", [1, 2], mediaType: "image/jpeg")
    #expect(png != jpeg)
  }

  @Test("an inline image and a remote one at the same id compare on what is around them")
  func inlineAgainstRemote() {
    let remote = TranscriptImage(
      id: "turn-1#image0", mediaType: "image/png", byteCount: 2, source: .remote(path: "/tmp/a.png")
    )
    // One id cannot be two images in a file, and the parser reads one `source.type` per block.
    #expect(remote == inline("turn-1#image0", [1, 2]))
  }

  @Test("a turn carrying images is still Hashable and still compares")
  func turnsCompare() {
    let left = TranscriptTurn(
      id: "t", speech: .human("look"), attachedImages: 1,
      images: [inline("t#image0", [1, 2, 3])]
    )
    let right = TranscriptTurn(
      id: "t", speech: .human("look"), attachedImages: 1,
      images: [inline("t#image0", [7, 7, 7])]
    )
    // This is the comparison `drawsSame(_:as:)` ends in.
    #expect(left == right)
  }

  @Test("the source is readable both ways round")
  func accessors() {
    let bytes = inline("t#image0", [1, 2, 3])
    #expect(bytes.inlineData == Data([1, 2, 3]))
    #expect(bytes.remotePath == nil)
    let path = TranscriptImage(
      id: "t#image1", mediaType: "", byteCount: 0, source: .remote(path: "/tmp/b.png"))
    #expect(path.remotePath == "/tmp/b.png")
    #expect(path.inlineData == nil)
  }

  /// Halving the cap would silently turn images into labels. The largest real image block
  /// measured was 666 KB. Both numbers are encoded bytes, as the parser compares.
  @Test("the encoded cap is comfortably above the largest measured real payload")
  func capIsAboveTheMeasuredWorstCase() {
    #expect(TranscriptImage.maxEncodedBytes == 8 << 20)
    #expect(TranscriptImage.maxEncodedBytes > 666 * 1024)
  }

  @Test("a turn with no images reports none")
  func noImages() {
    #expect(TranscriptTurn(id: "t", speech: .human("hi")).images.isEmpty)
  }

  // MARK: - What is written under the thumbnails

  private func turn(attached: Int, images: [TranscriptImage]) -> TranscriptTurn {
    TranscriptTurn(id: "t", speech: .human("look"), attachedImages: attached, images: images)
  }

  @Test("a turn whose images all drew says nothing under them")
  func everythingDrewSaysNothing() {
    let one = turn(attached: 1, images: [inline("t#image0", [1, 2])])
    #expect(one.drawableImages == 1)
    // A label under a visible thumbnail names what the reader already sees.
    #expect(one.imagesNoticeLabel == nil)
  }

  @Test("a turn where some drew counts the missing ones and says they are missing")
  func partlyDrewCountsTheMissing() {
    let two = turn(attached: 2, images: [inline("t#image0", [1, 2])])
    #expect(two.drawableImages == 1)
    // Not `2 images`, which under one thumbnail reads as the total.
    #expect(two.imagesNoticeLabel == "1 image not shown")

    let four = turn(attached: 4, images: [inline("t#image0", [1, 2])])
    #expect(four.imagesNoticeLabel == "3 images not shown")
  }

  @Test("a turn where nothing drew says how many images it carried")
  func nothingDrewKeepsTheOldLabel() {
    let none = turn(attached: 1, images: [])
    #expect(none.drawableImages == 0)
    #expect(none.imagesNoticeLabel == "1 image")
    #expect(none.imagesNoticeLabel == none.attachedImagesLabel)

    let three = turn(attached: 3, images: [])
    #expect(three.imagesNoticeLabel == "3 images")
  }

  @Test("a remote image counts as not drawn until it is fetched")
  func remoteIsNotDrawn() {
    let remote = TranscriptImage(
      id: "t#image0", mediaType: "image/png", byteCount: 0, source: .remote(path: "/tmp/a.png"))
    let one = turn(attached: 1, images: [remote])
    #expect(one.drawableImages == 0)
    #expect(one.imagesNoticeLabel == "1 image")
  }

  @Test("a turn with no images at all says nothing")
  func noImagesSaysNothing() {
    #expect(turn(attached: 0, images: []).imagesNoticeLabel == nil)
  }
}
