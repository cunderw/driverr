import DriverrCore
import Foundation
import Testing

/// The resting-size cap.
struct ImageUpscaleCapTests {
  @Test("a small image is capped at three device pixels per source pixel")
  func smallImageIsCapped() throws {
    // 64 source pixels x 3 = 192 device pixels = 64 points on a 3x phone.
    let capped = try #require(
      ImageUpscaleCap.restingSize(pixelWidth: 64, pixelHeight: 64, displayScale: 3))
    #expect(capped.width == 64)
    #expect(capped.height == 64)
  }

  @Test("the same image caps larger on a 2x screen, because it has fewer pixels to cover")
  func scaleChangesTheAnswer() throws {
    let two = try #require(
      ImageUpscaleCap.restingSize(pixelWidth: 64, pixelHeight: 64, displayScale: 2))
    #expect(two.width == 96)
  }

  @Test("a non-square image keeps its shape")
  func aspectIsPreserved() throws {
    let capped = try #require(
      ImageUpscaleCap.restingSize(pixelWidth: 400, pixelHeight: 300, displayScale: 3))
    #expect(capped.width == 400)
    #expect(capped.height == 300)
    #expect(capped.width / capped.height == 4.0 / 3.0)
  }

  /// A phone screenshot's cap is wider than any screen, so the aspect fit decides its size.
  @Test("a real screenshot's cap is far beyond any screen, so the fit binds instead")
  func realImagesAreNotCapped() throws {
    let capped = try #require(
      ImageUpscaleCap.restingSize(pixelWidth: 4032, pixelHeight: 3024, displayScale: 3))
    #expect(capped.width == 4032)
    #expect(capped.width > 1400)  // wider than the longest edge of any device Driverr runs on
  }

  /// Getting this wrong draws nothing at all.
  @Test("a degenerate input declines to cap rather than capping to zero")
  func degenerateInputsDoNotCap() {
    #expect(ImageUpscaleCap.restingSize(pixelWidth: 0, pixelHeight: 64, displayScale: 3) == nil)
    #expect(ImageUpscaleCap.restingSize(pixelWidth: 64, pixelHeight: 0, displayScale: 3) == nil)
    #expect(ImageUpscaleCap.restingSize(pixelWidth: 64, pixelHeight: 64, displayScale: 0) == nil)
    #expect(ImageUpscaleCap.restingSize(pixelWidth: -8, pixelHeight: 64, displayScale: 3) == nil)
  }

  @Test("the maximum upscale is three")
  func theRatioIsThree() {
    #expect(ImageUpscaleCap.maximumUpscale == 3)
  }
}
