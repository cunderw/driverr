import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a picked photo as PNG with its long edge capped, before any of it reaches a
/// host.
///
/// PNG because a phone photo is HEIC, which an agent on a Linux host may not read. The cap
/// keeps a lossless PNG from costing tens of megabytes over a phone link. 1568 px is the long
/// edge Claude's vision input resizes to, so larger is uploaded only to be thrown away.
///
/// `ImageIO` and `CoreGraphics`, not `UIKit`, so this builds on macOS and `swift test`
/// covers it. The app's `TranscriptImageDecoder.downsampled` does similar work for incoming
/// images, but it is a `UIImage` display path, so the two are not shared.
public enum ImageDownscale {
  /// The long edge a prepared attachment is capped at.
  public static let maximumPixelSize = 1568

  /// `data` as PNG, no longer than `maximumPixelSize` on its long edge, or `nil` if the
  /// bytes are not an image this platform can read.
  ///
  /// Never upscaled. ImageIO does not document a larger max size as a no-op, so the
  /// source's pixel size is read first and the thumbnail requested at `min(cap, longEdge)`.
  ///
  /// - Parameter maxPixel: the cap, defaulting to ``maximumPixelSize``. A cap of zero or
  ///   less is refused with `nil` rather than answered with an empty image.
  public static func png(from data: Data, maxPixel: Int = ImageDownscale.maximumPixelSize)
    -> Data?
  {
    guard maxPixel > 0,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }

    let target = min(maxPixel, sourceLongEdge(source) ?? maxPixel)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Honours the EXIF orientation, or a landscape photo lands on the host on its side.
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: target,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    let out = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        out, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
  }

  /// The source's long edge in pixels, after its EXIF orientation. A portrait photo is
  /// stored as a landscape bitmap plus a tag, so the raw width is the short edge.
  private static func sourceLongEdge(_ source: CGImageSource) -> Int? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0
    else { return nil }
    // Orientations 5–8 put the bitmap on its side. The long edge is the same either way; the
    // swap is spelled out for a future per-axis use.
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let isSideways = (5...8).contains(orientation)
    return isSideways ? max(height, width) : max(width, height)
  }
}
