import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The transcript has to reach behind the composer's card for the glass to have anything to
/// blur, and still rest above it. The composer is `.regularMaterial`, a backdrop filter, so a
/// bar that content stops above reads as a flat fill.
///
/// Two halves pull in opposite directions:
///
/// 1. The scroll view reaches past the card's top, so a turn scrolling by passes behind it.
/// 2. The newest row rests at or above the card's top, so nothing is parked under the bar.
///
/// Half 1 reads the `UIScrollView`'s own bounds through `ScrollViewProbe`, because
/// `measuredFrame` reports the safe region and cannot see the difference.
///
/// This is a fixture with stated heights. It pins the geometry `TerminalScreen` builds, not
/// how the card looks.
///
/// `.serialized` because each test makes a key window on the app's single scene. In parallel
/// the windows take key from each other while the run loop is pumped, and a suite reports
/// numbers from no state it asked for, with no failure.
@MainActor
@Suite("Chat composer glass", .serialized)
struct ChatGlassLayoutTests {
  /// A scroll view of stated rows, and the composer as the bar that insets it.
  ///
  /// No `.contentMargins`, as in `PaneChatView`: `safeAreaBar` owns the resting position.
  private struct Conversation: View {
    var composer: CGFloat
    var rows: Int
    var rowHeight: CGFloat
    var onFirstRow: @MainActor (CGRect) -> Void
    var onLastRow: @MainActor (CGRect) -> Void
    var onComposer: @MainActor (CGRect) -> Void

    var body: some View {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(0..<rows, id: \.self) { index in
            let row = Color.blue.frame(height: rowHeight)
            if index == 0 {
              row.measuredFrame(into: onFirstRow)
            } else if index == rows - 1 {
              row.measuredFrame(into: onLastRow)
            } else {
              row
            }
          }
        }
      }
      // The anchor rather than a `ScrollPosition`, so the resting position is a fact of layout
      // rather than of a scroll that has to be requested and waited for.
      .defaultScrollAnchor(.bottom)
      .safeAreaBar(edge: .bottom, spacing: 0) {
        Color.green
          .frame(height: composer)
          .measuredFrame(into: onComposer)
      }
    }
  }

  private typealias Measured = (
    first: CGRect, last: CGRect, scrollBounds: CGRect, composer: CGRect
  )

  private func measure(size: CGSize) -> Measured {
    var first = CGRect.zero
    var last = CGRect.zero
    var composer = CGRect.zero
    let window = HostedProbe.window(
      Conversation(
        composer: Self.composer,
        rows: Self.rows,
        rowHeight: Self.rowHeight,
        onFirstRow: { first = $0 },
        onLastRow: { last = $0 },
        onComposer: { composer = $0 }
      ),
      size: size
    )
    let scrollBounds = ScrollViewProbe.boundsInWindow(of: window) ?? .zero
    withExtendedLifetime(window) {}
    return (first, last, scrollBounds, composer)
  }

  /// `PaneComposerBar`'s measured height with an empty field, shared with
  /// `PaneSurfaceLayoutTests.Stack.composer` and `ChatConversationInsetLayoutTests`.
  private static let composer: CGFloat = 115
  private static let rowHeight: CGFloat = 120
  /// 2400 pt of content, taller than either window.
  private static let rows = 20

  @Test("the transcript reaches behind the composer and rests above it, on the phone")
  func theCompositionHoldsOnThePhone() {
    expectTheGlassHasABackdrop(measure(size: HostedProbe.phone), on: "phone")
  }

  @Test("the transcript reaches behind the composer and rests above it, on the pad")
  func theCompositionHoldsOnThePad() {
    expectTheGlassHasABackdrop(measure(size: HostedProbe.pad), on: "pad")
  }

  /// The first assertion keeps the other two honest. `measuredFrame` reports once, from
  /// `onAppear`. A frame captured before the bottom anchor applied would put the last row under
  /// the composer, which looks like the defect the third assertion rules out.
  private func expectTheGlassHasABackdrop(_ measured: Measured, on device: String) {
    // Built as `String`s first: `#expect` takes a `Comment`, which a string literal converts
    // to and a `+` concatenation does not.
    let notScrolled = """
      The conversation is not resting at its end on the \(device): the first of \(Self.rows) \
      rows is still at y \(measured.first.minY). The measurement was taken before \
      `defaultScrollAnchor(.bottom)` applied, so nothing below can be read as a layout result.
      """
    #expect(measured.first.minY < 0, "\(notScrolled)")

    let noBackdrop = """
      The real UIScrollView ends at y \(measured.scrollBounds.maxY) on the \(device) while the \
      composer's card starts at \(measured.composer.minY), so no part of the conversation is \
      ever drawn behind the card and its material has nothing but the page to blur. Read off \
      the view tree, not through `measuredFrame`, which reports the safe region and would say \
      these two are equal in every arrangement — see the suite doc.
      """
    #expect(measured.scrollBounds.maxY > measured.composer.minY + 0.5, "\(noBackdrop)")

    let parked = """
      The newest row runs to y \(measured.last.maxY) on the \(device) while the composer starts \
      at \(measured.composer.minY), so \(measured.last.maxY - measured.composer.minY) pt of it \
      rests under the bar. `safeAreaBar` is supposed to own the resting position through the \
      safe area, with no content margin put back by hand.
      """
    #expect(measured.last.maxY <= measured.composer.minY + 0.5, "\(parked)")
  }
}

/// Finds the `UIScrollView` a hosted SwiftUI `ScrollView` resolves to.
///
/// A `.background(GeometryReader)` on a `ScrollView` reports the safe region it was placed in.
/// Under a bottom safe-area inset that is the bar's top edge whether the frame was shrunk or the
/// safe area was inset. The `UIScrollView`'s own bounds separate the two: under a 115 pt
/// `safeAreaBar`, `measuredFrame` said 43..759 and the scroll view said 0..874 with an
/// `adjustedContentInset.bottom` of 115.
@MainActor
enum ScrollViewProbe {
  /// The first `UIScrollView` under `window`, in the window's own coordinates.
  static func boundsInWindow(of window: UIWindow) -> CGRect? {
    guard let scroll = first(in: window) else { return nil }
    return scroll.convert(scroll.bounds, to: window)
  }

  /// The first `UIScrollView` under `window`, for a test that needs its insets too.
  static func first(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    for child in view.subviews {
      if let found = first(in: child) { return found }
    }
    return nil
  }
}

/// Does `safeAreaBar` inset the scroll view's safe area or its frame, does the answer depend on
/// where the bar is attached, and does `safeAreaInset` differ?
///
/// Measured at `HostedProbe.phone` (402×874) with a 115 pt bar under a 43 pt band. Identical in
/// all four:
///
/// | | `measuredFrame`, SwiftUI | real `UIScrollView` | `adjustedContentInset.bottom` |
/// |---|---|---|---|
/// | `safeAreaBar` direct on the scroll view | 43..759 | **0..874** | **115** |
/// | `safeAreaBar` through a `ZStack` | 43..759 | **0..874** | **115** |
/// | `safeAreaBar` through a frame and a clip | 43..759 | **0..874** | **115** |
/// | `safeAreaInset` direct on the scroll view | 43..759 | **0..874** | **115** |
///
/// The `throughAFrameAndAClip` row reads the same with `.clipped()` on either side of the bar.
/// This tier is blind to a clip; see that case.
///
/// 1. `safeAreaBar` insets the safe area, not the frame. The scroll view keeps the whole window
///    and the bar's height arrives as a content inset.
/// 2. For the scroll view's own inset, the attachment point does not matter. For the bar's
///    siblings it does, because a `safeAreaBar` insets every child of what it is attached to.
///    `ChatComposerBarPlacementTests` covers that.
/// 3. `safeAreaInset` does the same. A SwiftUI frame probe reports otherwise, so it is the wrong
///    instrument for a scroll view under a safe-area inset.
@MainActor
@Suite("Chat composer safe-area bar", .serialized)
struct ChatComposerSafeAreaBarLayoutTests {
  /// How the bar is attached, which is the only thing that varies between the four cases.
  enum Shape: String, CaseIterable {
    /// Straight on the `ScrollView`, which is the shape Apple's own examples show.
    case direct
    /// On a `ZStack` holding the scroll view, one ordinary container in between, as in
    /// `paneSurfaces`.
    case throughAContainer
    /// Through a container, a `.frame(minHeight:)` and a `.clipped()`: the deepest nesting. The
    /// app does not build this; `ChatComposerBarPlacementTests` measures what it does build.
    ///
    /// This suite cannot see a `.clipped()` placed above the bar; see the chat slot's clip in
    /// `TerminalScreen`.
    case throughAFrameAndAClip
    /// `safeAreaInset` instead of `safeAreaBar`.
    case legacySafeAreaInset
  }

  /// A conversation under a fixed band, with the bar attached in one of the four shapes.
  private struct Stack: View {
    var shape: Shape
    var composer: CGFloat
    var rows: Int
    var rowHeight: CGFloat
    var onLastRow: @MainActor (CGRect) -> Void
    var onScroll: @MainActor (CGRect) -> Void
    var onComposer: @MainActor (CGRect) -> Void

    private var conversation: some View {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(0..<rows, id: \.self) { index in
            let row = Color.blue.frame(height: rowHeight)
            if index == rows - 1 { row.measuredFrame(into: onLastRow) } else { row }
          }
        }
      }
      .defaultScrollAnchor(.bottom)
      .measuredFrame(into: onScroll)
    }

    @ViewBuilder private var bar: some View {
      Color.green
        .frame(height: composer)
        .measuredFrame(into: onComposer)
    }

    var body: some View {
      VStack(spacing: 0) {
        // A fixed band, like the surface segment, so a top offset can be told apart from a
        // bottom one.
        Color.gray.frame(height: 43)
        switch shape {
        case .direct:
          conversation.safeAreaBar(edge: .bottom, spacing: 0) { bar }
        case .throughAContainer:
          ZStack { conversation }.safeAreaBar(edge: .bottom, spacing: 0) { bar }
        case .throughAFrameAndAClip:
          ZStack { conversation }
            .frame(minHeight: 64)
            .safeAreaBar(edge: .bottom, spacing: 0) { bar }
            .clipped()
        case .legacySafeAreaInset:
          conversation.safeAreaInset(edge: .bottom, spacing: 0) { bar }
        }
      }
    }
  }

  private typealias Measured = (
    last: CGRect, swiftUIFrame: CGRect, scrollBounds: CGRect, insetBottom: CGFloat,
    composer: CGRect
  )

  private func measure(_ shape: Shape, size: CGSize) -> Measured {
    var last = CGRect.zero
    var swiftUIFrame = CGRect.zero
    var composer = CGRect.zero
    let window = HostedProbe.window(
      Stack(
        shape: shape,
        composer: Self.composer,
        rows: Self.rows,
        rowHeight: Self.rowHeight,
        onLastRow: { last = $0 },
        onScroll: { swiftUIFrame = $0 },
        onComposer: { composer = $0 }
      ),
      size: size
    )
    let scroll = ScrollViewProbe.first(in: window)
    let bounds = scroll.map { $0.convert($0.bounds, to: window) } ?? .zero
    let inset = scroll?.adjustedContentInset.bottom ?? 0
    withExtendedLifetime(window) {}
    return (last, swiftUIFrame, bounds, inset, composer)
  }

  private static let composer: CGFloat = 115
  private static let rowHeight: CGFloat = 120
  private static let rows = 20

  @Test(
    "the bar insets the safe area rather than the frame, whatever it is attached to",
    arguments: Shape.allCases
  )
  func theBarOwnsTheInsetOnThePhone(shape: Shape) {
    expectTheBarOwnsTheInset(measure(shape, size: HostedProbe.phone), shape: shape, on: "phone")
  }

  @Test(
    "the same, on the pad, where every scroll number differs",
    arguments: Shape.allCases
  )
  func theBarOwnsTheInsetOnThePad(shape: Shape) {
    expectTheBarOwnsTheInset(measure(shape, size: HostedProbe.pad), shape: shape, on: "pad")
  }

  /// The frame probe's limitation, pinned as a passing test like
  /// `HostedAccessibilityLimitTests`. It fails the day `measuredFrame` reports the scroll view's
  /// own bounds.
  @Test("a SwiftUI frame probe reports the safe region, not the scroll view's bounds")
  func theFrameProbeCannotSeeTheScrollView() {
    let measured = measure(.throughAFrameAndAClip, size: HostedProbe.phone)
    let mismatch = """
      `measuredFrame` reported \(measured.swiftUIFrame) and the real UIScrollView is at \
      \(measured.scrollBounds). If those now agree, the platform changed and \
      `ChatGlassLayoutTests` can go back to the cheaper probe.
      """
    #expect(measured.swiftUIFrame.maxY < measured.scrollBounds.maxY - 0.5, "\(mismatch)")
  }

  private func expectTheBarOwnsTheInset(_ measured: Measured, shape: Shape, on device: String) {
    let noBackdrop = """
      Attached as `\(shape.rawValue)` on the \(device), the real UIScrollView ends at y \
      \(measured.scrollBounds.maxY) while the bar starts at \(measured.composer.minY), so the \
      frame was shrunk rather than the safe area inset and the conversation can never pass \
      behind the glass. A fallback would be an overlay with the content margin computed from \
      the bar's own layout.
      """
    #expect(measured.scrollBounds.maxY > measured.composer.minY + 0.5, "\(noBackdrop)")

    let noInset = """
      Attached as `\(shape.rawValue)` on the \(device), the scroll view's \
      `adjustedContentInset.bottom` is \(measured.insetBottom) rather than the bar's \
      \(Self.composer) pt. The bar's height is not reaching the scroll view as a content \
      inset, so nothing is holding the reader off the card.
      """
    #expect(abs(measured.insetBottom - Self.composer) < 0.5, "\(noInset)")

    let parked = """
      Attached as `\(shape.rawValue)` on the \(device), the newest row runs to y \
      \(measured.last.maxY) while the bar starts at \(measured.composer.minY), so \
      \(measured.last.maxY - measured.composer.minY) pt of it rests under the bar. The bar is \
      supposed to own the resting position, with no content margin put back by hand.
      """
    #expect(measured.last.maxY <= measured.composer.minY + 0.5, "\(parked)")
  }
}

/// The bar must inset the conversation and not the terminal, and it must stay in the slot.
///
/// A `safeAreaBar` on the whole `paneSurfaces` `ZStack` insets every child, the terminal too.
/// `DriverrTerminalView.sizeChanged` calls `TerminalSession.resize`, which tells the far side, so
/// a live pane would shrink by the composer's height while the reader is on Chat.
///
/// Three properties have to hold at once:
///
/// 1. the conversation gets the bar's height as a scroll content inset;
/// 2. the terminal sibling keeps the whole slot;
/// 3. the bar stays inside the slot even when the chat layer cannot fit it. Attaching the bar to
///    a child is the move that lets it hang off the region with that child.
///
/// - `Placement.onTheChatLayer` holds (2) and fails (3).
/// - Leaving the bar on the stack and giving the terminals `ignoresSafeArea` passes this tier
///   and is rejected in `TerminalScreen`. It is prose, not a case, because a passing test of
///   it would read as an endorsement.
/// - `Placement.onTheChatLayerPinnedToTheSlot` is what the app builds. An overflow goes upward,
///   where `.clipped()` hides it.
///
/// `PaneSwitchUITests.testLandscapeKeepsTheComposerAndTheSegmentReachable` checks this on a
/// device.
@MainActor
@Suite("Chat composer bar placement", .serialized)
struct ChatComposerBarPlacementTests {
  /// Where the bar is attached, and how the terminal is kept out of its inset.
  enum Placement {
    /// On the conversation alone, inside the `ZStack`. Keeps the terminal whole and lets the
    /// bar follow the conversation out of the slot.
    case onTheChatLayer
    /// On the conversation, drawn as the bottom-aligned `.overlay` of a flexible sibling. An
    /// overlay cannot change its parent's frame, so the composite's bottom edge is the slot's
    /// and an overflow goes upward, where `.clipped()` hides it.
    ///
    /// `.frame(maxHeight: .infinity, alignment: .bottom)` does not clamp: a `maxHeight` frame
    /// reports its content's height when the content does not fit, and the `ZStack` grows.
    case onTheChatLayerPinnedToTheSlot
  }

  /// `paneSurfaces`' shape: a flexible terminal, the conversation over it, and the bar.
  private struct Surfaces: View {
    var placement: Placement
    var slot: CGFloat
    var composer: CGFloat
    var rows: Int
    var rowHeight: CGFloat
    var onTerminal: @MainActor (CGRect) -> Void
    var onComposer: @MainActor (CGRect) -> Void
    var onLastRow: @MainActor (CGRect) -> Void
    var onSlot: @MainActor (CGRect) -> Void

    private var conversation: some View {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(0..<rows, id: \.self) { index in
            let row = Color.blue.frame(height: rowHeight)
            if index == rows - 1 { row.measuredFrame(into: onLastRow) } else { row }
          }
        }
      }
      .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder private var bar: some View {
      Color.green.frame(height: composer).measuredFrame(into: onComposer)
    }

    /// The terminals: flexible in both axes, takes whatever it is proposed.
    private var terminal: some View {
      Color.red.measuredFrame(into: onTerminal)
    }

    @ViewBuilder private var surfaces: some View {
      switch placement {
      case .onTheChatLayer:
        ZStack {
          terminal
          conversation.safeAreaBar(edge: .bottom, spacing: 0) { bar }
        }
        .frame(minHeight: 64)
        .clipped()
      case .onTheChatLayerPinnedToTheSlot:
        ZStack {
          terminal
          Color.clear.overlay(alignment: .bottom) {
            conversation.safeAreaBar(edge: .bottom, spacing: 0) { bar }
          }
        }
        .frame(minHeight: 64)
        .clipped()
      }
    }

    var body: some View {
      VStack(spacing: 0) {
        Color.gray.frame(height: 43)
        // Measured outside `.clipped()`, which masks at this frame, so this is the slot.
        // Anything below it is cut off on screen.
        surfaces.measuredFrame(into: onSlot)
        Spacer(minLength: 0)
      }
      .frame(height: slot + 43)
    }
  }

  private static let composer: CGFloat = 115
  private static let rowHeight: CGFloat = 120
  private static let rows = 20
  /// The band above the surfaces, so the slot does not start at the window's top edge.
  ///
  /// Where the slot ends is measured, never computed from this and never read off the terminal.
  /// `HostedProbe` centres the shorter stack, so `band + slot` is off by half the slack. The
  /// terminal grows with an overflowing `ZStack`, so it moves with the thing being measured.
  private static let band: CGFloat = 43

  private typealias Measured = (
    terminal: CGRect, composer: CGRect, last: CGRect, scrollBounds: CGRect,
    insetBottom: CGFloat, slot: CGRect
  )

  private func measure(_ placement: Placement, slot: CGFloat) -> Measured {
    var terminal = CGRect.zero
    var composer = CGRect.zero
    var last = CGRect.zero
    var slotFrame = CGRect.zero
    let window = HostedProbe.window(
      Surfaces(
        placement: placement,
        slot: slot,
        composer: Self.composer,
        rows: Self.rows,
        rowHeight: Self.rowHeight,
        onTerminal: { terminal = $0 },
        onComposer: { composer = $0 },
        onLastRow: { last = $0 },
        onSlot: { slotFrame = $0 }
      ),
      size: HostedProbe.phone
    )
    let scroll = ScrollViewProbe.first(in: window)
    let bounds = scroll.map { $0.convert($0.bounds, to: window) } ?? .zero
    let inset = scroll?.adjustedContentInset.bottom ?? 0
    withExtendedLifetime(window) {}
    return (terminal, composer, last, bounds, inset, slotFrame)
  }

  /// The placement the app builds has to hold all three properties.
  @Test("the terminal keeps the whole slot while the bar insets the conversation")
  func theTerminalIsNotInset() {
    let slot: CGFloat = 700
    let measured = measure(.onTheChatLayerPinnedToTheSlot, slot: slot)

    let shrunk = """
      The terminal sibling is \(measured.terminal.height) pt tall in a \(slot) pt slot, so the \
      composer's bar insets it too. `DriverrTerminalView.sizeChanged` tells the far side, which \
      means a live pane is resized by a bar it does not even show. That is the regression \
      this suite exists for.
      """
    #expect(abs(measured.terminal.height - slot) < 0.5, "\(shrunk)")

    let noInset = """
      The conversation's `adjustedContentInset.bottom` is \(measured.insetBottom) rather than \
      the bar's \(Self.composer) pt, so the bar is no longer holding the reader off the card.
      """
    #expect(abs(measured.insetBottom - Self.composer) < 0.5, "\(noInset)")

    let noBackdrop = """
      The real UIScrollView ends at y \(measured.scrollBounds.maxY) while the bar starts at \
      \(measured.composer.minY), so nothing passes behind the glass.
      """
    #expect(measured.scrollBounds.maxY > measured.composer.minY + 0.5, "\(noBackdrop)")

    let parked = """
      The newest row runs to y \(measured.last.maxY) while the bar starts at \
      \(measured.composer.minY), so it rests under the card.
      """
    #expect(measured.last.maxY <= measured.composer.minY + 0.5, "\(parked)")
  }

  /// 100 pt is the landscape-with-keyboard region `PaneSwitchUITests` measures.
  @Test("the bar stays inside the slot when the conversation cannot fit it")
  func theBarStaysInTheSlot() {
    let measured = measure(.onTheChatLayerPinnedToTheSlot, slot: 100)
    let slotBottom = measured.slot.maxY

    let hangs = """
      The bar runs to y \(measured.composer.maxY) against a slot ending at \(slotBottom) (the \
      clipped slot is \(measured.slot)), so it hangs \
      \(measured.composer.maxY - slotBottom) pt below the region — under the keys on a \
      landscape phone. The composer followed the content it is attached to out of the slot.
      """
    #expect(measured.composer.maxY <= slotBottom + 0.5, "\(hangs)")
  }

  /// Why the direct placement is not the one built, pinned like `HostedAccessibilityLimitTests`.
  ///
  /// With the bar on the conversation alone, the bar's proposal is the conversation's height,
  /// so in a squeezed slot the composite overflows and `.frame(minHeight:)` centres the overflow
  /// across both edges. A 115 pt bar in a 100 pt slot ran to y 530 against a slot ending at 143.
  @Test("attaching the bar to the conversation alone lets it hang out of a squeezed slot")
  func theChatLayerPlacementHangsOutOfTheSlot() {
    let measured = measure(.onTheChatLayer, slot: 100)
    let slotBottom = measured.slot.maxY

    let fixed = """
      The bare chat-layer placement now keeps the bar at \(measured.composer.maxY) inside a \
      slot ending at \(slotBottom). If SwiftUI changed, the simpler placement is available \
      again and `TerminalScreen` can drop the `Color.clear` and the overlay.
      """
    #expect(measured.composer.maxY > slotBottom + 0.5, "\(fixed)")
  }
}
