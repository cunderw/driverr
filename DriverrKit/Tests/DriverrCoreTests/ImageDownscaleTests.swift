import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DriverrCore

/// Fixtures are drawn in-process rather than committed, so the tests need no bundle
/// resource and state the input's pixel size beside the output's. `ImageDownscale` uses
/// `ImageIO` and `CoreGraphics`, never `UIKit`, so this runs on macOS.
@Suite struct ImageDownscaleTests {
  /// A solid bitmap of an exact pixel size, encoded as PNG. A flat colour keeps a 3000 px
  /// fixture cheap.
  private func bitmap(width: Int, height: Int) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())

    let out = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
  }

  /// Read back through ImageIO rather than through whatever produced the bytes.
  private func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
    let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
    return (width, height)
  }

  @Test func aLargePhotographIsCappedOnItsLongEdge() throws {
    let source = try bitmap(width: 3000, height: 1800)
    let scaled = try #require(ImageDownscale.png(from: source))

    let size = try pixelSize(scaled)
    #expect(max(size.width, size.height) <= ImageDownscale.maximumPixelSize)
    #expect(max(size.width, size.height) == ImageDownscale.maximumPixelSize)
    // 5:3 at 1568 wide is 940.8 tall. Which way ImageIO rounds is not this function's claim.
    #expect((940...941).contains(min(size.width, size.height)))
  }

  /// Checked by magic number, because asserting the `UTType` passed in proves only that it
  /// was passed. A phone's HEIC must never cross the wire.
  @Test func theOutputIsAPNG() throws {
    let scaled = try #require(ImageDownscale.png(from: try bitmap(width: 400, height: 400)))
    #expect(Array(scaled.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  }

  /// `kCGImageSourceCreateThumbnailFromImageAlways` above the source size is not documented
  /// as a no-op, so `ImageDownscale` asks for the smaller of the two sizes.
  @Test func aSmallImageKeepsItsOwnSize() throws {
    let source = try bitmap(width: 64, height: 48)
    let scaled = try #require(ImageDownscale.png(from: source))

    let size = try pixelSize(scaled)
    #expect(size.width == 64)
    #expect(size.height == 48)
  }

  @Test func anImageExactlyAtTheCapIsUnchangedInSize() throws {
    let source = try bitmap(
      width: ImageDownscale.maximumPixelSize, height: ImageDownscale.maximumPixelSize)
    let scaled = try #require(ImageDownscale.png(from: source))

    let size = try pixelSize(scaled)
    #expect(size.width == ImageDownscale.maximumPixelSize)
    #expect(size.height == ImageDownscale.maximumPixelSize)
  }

  /// `nil` lets the composer say so rather than upload something the host cannot open.
  @Test func bytesThatAreNotAnImageAreRefused() {
    #expect(ImageDownscale.png(from: Data("not a photograph".utf8)) == nil)
  }

  /// For `ImageUpscaleCap`'s reason: "draw nothing" is worse than no answer.
  @Test func aCapOfZeroIsRefused() throws {
    let source = try bitmap(width: 100, height: 100)
    #expect(ImageDownscale.png(from: source, maxPixel: 0) == nil)
  }
}
