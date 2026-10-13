import DriverrCore
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The thumbnails under a human turn that carried images.
///
/// Only images whose bytes arrived are drawn. A `.remote` image (a host path nothing
/// fetches), an oversized one or an undecodable one is left out, and `TranscriptTurnView`'s
/// `N images` label still covers it.
struct TranscriptImageStrip: View {
  let images: [TranscriptImage]
  /// Opens one full size. `nil` where there is no viewer, and the thumbnails are then not
  /// tappable.
  var onOpen: ((TranscriptImage) -> Void)?

  /// How many 96 pt thumbnails fit in a bubble on the narrowest supported phone. A fourth
  /// would compress the others.
  private static let maximumShown = 3

  /// Drawable images, in the order the record wrote them.
  private var drawable: [TranscriptImage] {
    images.filter { $0.inlineData != nil }
  }

  private var shown: [TranscriptImage] { Array(drawable.prefix(Self.maximumShown)) }
  private var hidden: Int { max(0, drawable.count - Self.maximumShown) }

  /// A lone image gets the room a screenshot needs to be legible; several share the row.
  private var side: CGFloat { drawable.count == 1 ? 168 : 96 }

  var body: some View {
    if !drawable.isEmpty {
      HStack(spacing: 8) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, image in
          Button {
            onOpen?(image)
          } label: {
            TranscriptImageThumbnail(image: image, side: side)
              .overlay {
                if index == shown.count - 1, hidden > 0 {
                  more(hidden)
                }
              }
          }
          .buttonStyle(.plain)
          .disabled(onOpen == nil)
          // On the button, not the `HStack`, so a test can find one thumbnail. The image id
          // already includes the turn id and block index, so it is unique on the page.
          .accessibilityIdentifier("chat.image.\(image.id)")
          .accessibilityLabel(label(for: index))
          // The `+N` scrim is hidden; this value says it, without a second focus stop.
          .accessibilityValue(moreValue(for: index))
          .accessibilityAddTraits(.isImage)
        }
      }
    }
  }

  private func label(for index: Int) -> String {
    drawable.count == 1 ? "Image" : "Image \(index + 1) of \(drawable.count)"
  }

  private func moreValue(for index: Int) -> String {
    index == shown.count - 1 && hidden > 0 ? "+\(hidden) more" : ""
  }

  private func more(_ count: Int) -> some View {
    ZStack {
      Rectangle().fill(.black.opacity(0.55))
      Text("+\(count)")
        .font(.headline)
        .foregroundStyle(.white)
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityHidden(true)
  }
}

/// One thumbnail, in a box whose size is fixed before anything decodes.
///
/// The frame never grows. A row that changes height after its first layout moves
/// everything below it and upsets the chat's opening scroll.
///
/// **No `ProgressView` while it decodes.** An indeterminate one animates for ever, so the
/// app never reports idle, for the same reason as the steady caret (CLAUDE.md).
private struct TranscriptImageThumbnail: View {
  let image: TranscriptImage
  let side: CGFloat

  @Environment(\.displayScale) private var displayScale
  @State private var thumbnail: UIImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(.tertiarySystemFill))
      if let thumbnail {
        Image(uiImage: thumbnail)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(.separator), lineWidth: 0.5)
    }
    // The whole box is the tap target, including the placeholder's empty corners.
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    // Keyed on the image and the box size, so a different box gets its own thumbnail.
    .task(id: "\(image.id)@\(Int(side))") {
      thumbnail = await TranscriptThumbnails.shared.thumbnail(
        for: image, maxPixel: Int(side * displayScale)
      )
    }
  }
}

/// Decoded thumbnails, kept so a turn scrolled off and back is not decoded again on the
/// main actor.
///
/// Shared, not owned by `PaneTranscriptModel`, because only what is on screen is worth
/// decoding, and the model cannot know that.
@MainActor
final class TranscriptThumbnails {
  static let shared = TranscriptThumbnails()

  /// `NSCache`, so thumbnails are evicted under memory pressure.
  private let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 48
    return cache
  }()

  /// Decodes in flight, so two requests for one image at one size decode once.
  ///
  /// `Data`, not `UIImage`, because a `Task`'s result must be `Sendable`. The `UIImage` is
  /// made on this actor.
  private var inFlight: [String: Task<Data?, Never>] = [:]

  private init() {}

  func thumbnail(for image: TranscriptImage, maxPixel: Int) async -> UIImage? {
    let key = "\(image.id)@\(maxPixel)"
    if let hit = cache.object(forKey: key as NSString) { return hit }
    guard let data = image.inlineData else { return nil }

    let scaled: Data?
    if let running = inFlight[key] {
      scaled = await running.value
    } else {
      // Detached, because a plain `Task` inherits this actor and would decode on the main
      // thread.
      let task = Task.detached(priority: .userInitiated) {
        TranscriptImageDecoder.downsampled(data, maxPixel: maxPixel)
      }
      inFlight[key] = task
      scaled = await task.value
      inFlight[key] = nil
    }

    guard let scaled, let made = UIImage(data: scaled) else { return nil }
    cache.setObject(made, forKey: key as NSString)
    return made
  }
}

/// The downsample itself, off any actor so it can run on a detached task.
enum TranscriptImageDecoder {
  /// Scales `data` so its long edge is at most `maxPixel` and re-encodes it as PNG, or `nil`
  /// if the bytes are not an image this device can read.
  ///
  /// `CGImageSourceCreateThumbnailAtIndex`, not `UIImage(data:)` and a redraw, because it
  /// never builds the full-size bitmap (48 MB for a 4032×3024 photo).
  static func downsampled(_ data: Data, maxPixel: Int) -> Data? {
    guard maxPixel > 0,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Honours EXIF orientation, or a phone photo lands on its side.
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
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
}
