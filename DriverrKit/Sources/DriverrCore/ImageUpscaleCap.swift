import Foundation

/// How far a small image may be blown up before it is drawn.
///
/// An aspect fit draws a small image as large as a big one: a 64 px image came out at
/// 386 pt on an iPhone 17, which reads as a blurry app rather than a small picture. This
/// caps the resting size only; pinch zoom still goes past it.
public enum ImageUpscaleCap {
  /// The most device pixels one of the image's own pixels may be drawn across.
  ///
  /// Three is where the softness still reads as a small image. Real photos never reach it;
  /// it is for tiny attachments.
  public static let maximumUpscale: Double = 3

  /// The largest an image of `pixelWidth` × `pixelHeight` may be drawn at rest, in points, or
  /// `nil` for "do not cap it".
  ///
  /// `nil`, not zero, for an unknown pixel size or a zero display scale, so the image draws
  /// at the fit rather than as nothing.
  ///
  /// The scale makes this a pixel ratio. `UIImage(data:)` reports scale 1, so its `size` is
  /// the pixel count. A 64 px image caps at 64 pt on a 3× phone and 96 pt on a 2× one, the
  /// same device pixels on both.
  public static func restingSize(
    pixelWidth: Double,
    pixelHeight: Double,
    displayScale: Double
  ) -> (width: Double, height: Double)? {
    guard pixelWidth > 0, pixelHeight > 0, displayScale > 0 else { return nil }
    return (
      width: pixelWidth * maximumUpscale / displayScale,
      height: pixelHeight * maximumUpscale / displayScale
    )
  }
}
