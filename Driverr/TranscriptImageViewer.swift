import DriverrCore
import SwiftUI
import UIKit

/// One image at full size, drawn by `TerminalScreen` as an overlay.
///
/// **An overlay, not a sheet or `fullScreenCover`**, because on iPad the pane scene is in the
/// detail column, which must not present (CLAUDE.md). As an ordinary descendant it also
/// inherits `ContentView`'s environment, so the caller injects nothing.
struct TranscriptImageViewer: View {
  let image: TranscriptImage
  let onClose: () -> Void

  @Environment(\.displayScale) private var displayScale

  @State private var full: UIImage?
  @State private var zoom: CGFloat = 1
  @State private var settledZoom: CGFloat = 1
  @State private var dragged: CGSize = .zero

  /// The long edge the full-size decode is capped at. A phone photo is 4032 px and 48 MB
  /// decoded; this leaves real detail for a pinch. Smaller images keep their own size.
  private static let maximumPixel = 2400

  /// How far down the sheet has to be dragged before letting go dismisses it.
  private static let dismissDistance: CGFloat = 120

  var body: some View {
    ZStack {
      // Full-bleed within this screen: the window on a phone, the detail column on iPad,
      // where the sidebar stays usable. `ignoresSafeArea` is on the backdrop only, so Done
      // stays clear of the home indicator.
      Rectangle()
        .fill(.ultraThinMaterial)
        .ignoresSafeArea()
        // A tap on the backdrop closes, as in every photo viewer.
        .onTapGesture(perform: onClose)

      picture
        .scaleEffect(zoom)
        .offset(dragged)
        .gesture(
          MagnifyGesture()
            .onChanged {
              zoom = min(6, max(1, settledZoom * $0.magnification))
              dragged = .zero
            }
            .onEnded { _ in settledZoom = zoom }
        )
        // **Guarded inside the handlers, not by detaching the gesture.** A zoomed drag must
        // not dismiss, but swapping the gesture on a state change drops the touch.
        .gesture(
          DragGesture()
            .onChanged {
              guard zoom <= 1 else { return }
              dragged = CGSize(width: 0, height: max(0, $0.translation.height))
            }
            .onEnded {
              guard zoom <= 1 else { return }
              if $0.translation.height > Self.dismissDistance {
                onClose()
              } else {
                withAnimation(.snappy) { dragged = .zero }
              }
            }
        )
        .accessibilityIdentifier("chat.image.full")
        .accessibilityLabel("Image, full size")
    }
    // Bottom trailing: at top trailing it lined up under the navigation bar's capsule and
    // read as a bar button.
    //
    // `.borderedProminent` with `ProminentButtonLabel`, because a `.bordered` accent label on
    // its faint accent fill fails contrast. No `.tint`: the root tint is already the accent.
    .overlay(alignment: .bottomTrailing) {
      Button(action: onClose) {
        ProminentButtonLabel { Text("Done").fontWeight(.semibold) }
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .padding(16)
      .accessibilityIdentifier("chat.image.close")
    }
    .task(id: image.id) {
      full = await TranscriptThumbnails.shared.thumbnail(
        for: image, maxPixel: Self.maximumPixel
      )
    }
  }

  @ViewBuilder
  private var picture: some View {
    if let full {
      Image(uiImage: full)
        .resizable()
        .scaledToFit()
        // An edge, so a light image does not run into the backdrop. **Before the frame**:
        // `scaledToFit` sizes the view to the picture, while the frame below can be larger,
        // and an overlay after it would outline empty space.
        .overlay {
          Rectangle().strokeBorder(Color(.separator), lineWidth: 0.5)
        }
        // Caps upscaling of an image smaller than the screen. `ImageUpscaleCap` owns the
        // arithmetic; `nil` leaves an axis unconstrained rather than capping to zero.
        .frame(maxWidth: restingSize(of: full)?.width, maxHeight: restingSize(of: full)?.height)
        .padding(8)
    } else {
      // Static, for the reason on `TranscriptImageThumbnail`.
      Image(systemName: "photo")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
    }
  }

  /// The largest this image is drawn at rest, in points, or `nil` for "do not cap".
  ///
  /// `UIImage(data:)` reports scale 1, so `size` is in pixels, as `ImageUpscaleCap` expects.
  private func restingSize(of image: UIImage) -> (width: CGFloat, height: CGFloat)? {
    guard
      let capped = ImageUpscaleCap.restingSize(
        pixelWidth: image.size.width,
        pixelHeight: image.size.height,
        displayScale: displayScale
      )
    else { return nil }
    return (CGFloat(capped.width), CGFloat(capped.height))
  }
}
