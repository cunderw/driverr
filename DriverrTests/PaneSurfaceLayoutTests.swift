import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The pane surfaces must not be drawn across the chrome band above them.
///
/// A `.frame(minHeight:)` does not compress a child that will not fit. It reports the floor and
/// centres the child, so a block taller than the floor hangs off both ends. A 115 pt composer
/// against the 64 pt floor painted over the `Chat | Terminal` segment and the navigation bar.
///
/// `alignment: .top` moves the overflow downward and hangs the app on dismissal; see
/// `TerminalScreen.swift`. Instead, in the one state with no room, the composer collapses to
/// about 58 pt and the floor gives way with it.
///
/// `.serialized`: see `ChatGlassLayoutTests`.
@MainActor
@Suite("Pane surface layout", .serialized)
struct PaneSurfaceLayoutTests {
  /// `TerminalScreen`'s stack reduced to a fixed chrome band, a floored surface, and the
  /// surface's bottom `safeAreaInset`. The composer is a `Color` of a stated height, so the
  /// fixture cannot stop reproducing when the bar changes.
  private struct Stack: View {
    var alignment: Alignment
    /// `Stack.band` when drawn, 0 in the collapsed state, where the segment is not in the tree.
    var bandHeight: CGFloat
    /// `TerminalScreen.surfaceFloor`: 64 pt ordinarily, 0 in the collapsed state.
    var floor: CGFloat
    /// `PaneComposerBar`'s resolved height: 115 pt in its ordinary shape, 58 collapsed.
    var composer: CGFloat
    var onBand: @MainActor (CGRect) -> Void
    var onFrame: @MainActor (CGRect) -> Void
    var onContent: @MainActor (CGRect) -> Void
    var onComposer: @MainActor (CGRect) -> Void

    var body: some View {
      VStack(spacing: 0) {
        Color.gray
          .frame(height: bandHeight)
          .measuredFrame(into: onBand)
        Color.blue
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .measuredFrame(into: onContent)
          .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.green
              .frame(height: composer)
              .measuredFrame(into: onComposer)
          }
          .frame(minHeight: floor, alignment: alignment)
          .measuredFrame(into: onFrame)
      }
    }

    /// The segment band's measured height on the device: a 31 pt picker with 6 pt either side.
    static let band: CGFloat = 43
    static let floor = TerminalScreen.minimumSurfaceHeight
    /// `PaneComposerBar`'s measured height with an empty field. Over the floor, which is what
    /// makes the centring visible.
    static let composer: CGFloat = 115
    /// The same bar collapsed. One row: 3 pt of card padding either side of a 44 pt tap target,
    /// plus 4 pt under the card.
    static let collapsedComposer: CGFloat = 58
  }

  private typealias Measured = (band: CGRect, frame: CGRect, content: CGRect, composer: CGRect)

  private func measure(
    _ alignment: Alignment,
    band bandHeight: CGFloat = Stack.band,
    floor: CGFloat = Stack.floor,
    composer composerHeight: CGFloat = Stack.composer
  ) -> Measured {
    var band = CGRect.zero
    var frame = CGRect.zero
    var content = CGRect.zero
    var composer = CGRect.zero
    let window = HostedProbe.window(
      Stack(
        alignment: alignment,
        bandHeight: bandHeight,
        floor: floor,
        composer: composerHeight,
        onBand: { band = $0 },
        onFrame: { frame = $0 },
        onContent: { content = $0 },
        onComposer: { composer = $0 }
      ),
      // The region a landscape phone leaves once the navigation bar and keyboard take theirs.
      // The window has to be that small: at the phone's full 402 pt the `minHeight` never
      // binds and the negatives below stop reproducing. band(43) + floor(64) = 107 exceeds it.
      size: CGSize(width: 874, height: Self.region)
    )
    withExtendedLifetime(window) {}
    return (band, frame, content, composer)
  }

  /// The region the real stack gets on a landscape phone with the keyboard up.
  private static let region: CGFloat = 100

  /// The least conversation this posture may leave. Asserted directly by
  /// `theHiddenBandGivesTheConversationItsRoom` and used as the collapsed bar's budget below.
  private static let conversationFloor: CGFloat = 40

  /// The shipped shape. Collapsing the composer alone leaves the conversation a few points, and
  /// a `Color` compresses to that without complaint where a real chat with a header cannot. So
  /// the band hides too, and this asserts the conversation has room to be read.
  ///
  /// 40 pt is asserted rather than the measured 42, so a point of padding moving does not fail
  /// it; anything that halves it does.
  @Test("with the band hidden the conversation keeps the room the composer does not take")
  func theHiddenBandGivesTheConversationItsRoom() {
    let (_, frame, content, composer) = measure(
      .center,
      band: 0,
      floor: 0,
      composer: Stack.collapsedComposer
    )

    #expect(content.minY >= frame.minY, "The surfaces start above their own frame: \(content)")
    #expect(
      composer.maxY <= Self.region,
      "The composer runs past the \(Self.region) pt region, under the keyboard: \(composer)"
    )
    // Built as a `String` first: `#expect` takes a `Comment`, which a literal converts to and
    // a `+` concatenation does not.
    let starved = """
      The conversation is \(content.height) pt. Hiding the band was supposed to buy it about \
      42, and 3 pt of chat is what that decision exists to stop.
      """
    #expect(content.height >= Self.conversationFloor, "\(starved)")
  }

  /// The negative for the composer's half: the ordinary 115 pt composer centred in the 64 pt
  /// floor covers the band. Without it the collapse reads as a style choice.
  @Test("the full-height composer is what put the surfaces over the band")
  func theFullComposerOverlapsTheBand() {
    let (band, frame, content, _) = measure(.center)

    #expect(content.minY < frame.minY, "The 115 pt composer no longer overflows upward")
    #expect(content.minY < band.maxY, "The 115 pt composer no longer reaches the band")
  }

  /// Anchors `Stack.collapsedComposer` to the real bar. A hand-entered height goes on passing
  /// after the bar grows, so this lays out `PaneComposerBar` collapsed and checks it against the
  /// fixture's number and the room there is.
  ///
  /// The budget is the region less the conversation floor. A second 44 pt row on the collapsed
  /// card fails it.
  @Test("the real collapsed bar fits the room the band leaves, and matches the fixture")
  func theRealCollapsedBarFitsTheBudget() {
    var measured = CGRect.zero
    let window = HostedProbe.window(
      PaneComposerBar(
        model: PreviewSupport.composer(for: PreviewSupport.agentPane, in: PaneComposerState()),
        header: PaneComposerHeader(pane: PreviewSupport.agentPane),
        isCollapsed: true
      )
      .measuredFrame(into: { measured = $0 }),
      size: CGSize(width: 874, height: Self.region)
    )
    withExtendedLifetime(window) {}

    let budget = Self.region - Self.conversationFloor
    let tooTall = """
      The collapsed bar is \(measured.height) pt of the \(Self.region) pt region. Over \
      \(budget) and the conversation is left less than the \(Self.conversationFloor) pt \
      floor hiding the band was supposed to buy it.
      """
    let drifted = """
      The collapsed bar resolves to \(measured.height) pt, not the \
      \(Stack.collapsedComposer) the fixture above assumes. Update the constant, and check \
      the heights in the doc comments on `isComposerCollapsed` and `surfaceFloor` in \
      TerminalScreen.swift while you are there.
      """

    #expect(measured.height <= budget, "\(tooTall)")
    #expect(abs(measured.height - Stack.collapsedComposer) <= 2, "\(drifted)")
  }

  /// The negative for the floor's half. With the 64 pt floor in force, `band(43) + floor(64)`
  /// overflows the 100 pt region whatever the composer's height. Without this, collapsing
  /// `surfaceFloor` reads as belt-and-braces.
  @Test("the 64 pt floor is what still pushed the collapsed composer under the keyboard")
  func theFloorAloneStillOverflows() {
    let (_, _, _, composer) = measure(.center, floor: Stack.floor, composer: Stack.collapsedComposer)

    #expect(
      composer.maxY > Self.region,
      "The 64 pt floor no longer overflows the region: \(composer)"
    )
  }

  // MARK: - The slot, and the two things attached to it

  /// The composer as an `.overlay` on the surfaces, which carry a child that will not compress:
  /// the chat's header over a `ScrollView` with a minimum height.
  ///
  /// A `.frame(minHeight:)` reports `max(floor, min(content, proposal))`. It does not grow to
  /// hold content; it centres it and lets it hang off both ends. So what matters is which side
  /// of the frame the composer and the geometry probe are attached to.
  private struct Surfaces: View {
    /// `TerminalScreen.surfaceFloor`: 0 in the collapsed state this models.
    var floor: CGFloat
    /// What the surfaces' tallest child insists on.
    var contentMinHeight: CGFloat
    /// `PaneComposerBar`'s resolved height.
    var composer: CGFloat
    /// The wrong shape: the composer and the probe attached to the surfaces' content, above the
    /// floor's frame and its clip, so both follow an overflowing block.
    var attachesToContent: Bool
    var onFrame: @MainActor (CGRect) -> Void
    var onContent: @MainActor (CGRect) -> Void
    var onComposer: @MainActor (CGRect) -> Void

    var body: some View {
      VStack(spacing: 0) {
        if attachesToContent {
          content
            .overlay(alignment: .bottom) { composerBar }
            .measuredFrame(into: onFrame)
            .frame(minHeight: floor)
            .clipped()
        } else {
          content
            .frame(minHeight: floor)
            .clipped()
            .overlay(alignment: .bottom) { composerBar }
            .measuredFrame(into: onFrame)
        }
      }
    }

    private var content: some View {
      Color.blue
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: contentMinHeight)
        .measuredFrame(into: onContent)
    }

    private var composerBar: some View {
      Color.green
        .frame(height: composer)
        .measuredFrame(into: onComposer)
    }

    /// The chat's minimum on a landscape phone with the keyboard up, with the "Show the screen"
    /// row showing: 30 pt of provenance header, 29.7 pt of row, and a 76 pt scroll floor.
    static let chatMinimumBefore: CGFloat = 136
    /// The same chat with the row hidden and the obstruction gone: 30 + 58.
    static let chatMinimumAfter: CGFloat = 88
  }

  private func measureSurfaces(
    attachesToContent: Bool,
    floor: CGFloat = 0,
    contentMinHeight: CGFloat = Surfaces.chatMinimumBefore,
    composer: CGFloat = Stack.collapsedComposer
  ) -> (frame: CGRect, content: CGRect, composer: CGRect) {
    var frame = CGRect.zero
    var content = CGRect.zero
    var composerFrame = CGRect.zero
    let window = HostedProbe.window(
      Surfaces(
        floor: floor,
        contentMinHeight: contentMinHeight,
        composer: composer,
        attachesToContent: attachesToContent,
        onFrame: { frame = $0 },
        onContent: { content = $0 },
        onComposer: { composerFrame = $0 }
      ),
      size: CGSize(width: 874, height: Self.region)
    )
    withExtendedLifetime(window) {}
    return (frame, content, composerFrame)
  }

  /// The composer and the geometry probe are attached below the surfaces' frame, so both read
  /// the region rather than the block centred in it. With `attachesToContent: true` it fails
  /// on the composer at 118 against the 100 pt region.
  @Test("the composer and the probe read the slot, not the block centred in it")
  func theComposerAndTheProbeReadTheSlot() {
    let (frame, content, composer) = measureSurfaces(attachesToContent: false)

    let overflowed = """
      The surfaces' frame reports \(frame.height) pt in a \(Self.region) pt region: \(frame).
      """
    #expect(frame.height == Self.region, "\(overflowed)")
    #expect(frame.minY >= 0, "The measured frame starts above the region: \(frame)")
    #expect(frame.maxY <= Self.region, "The measured frame runs past the region: \(frame)")

    let followed = """
      The composer is bottom-aligned to what this probe measures, so it is under the keyboard \
      whenever that block is: \(composer) in a \(Self.region) pt region.
      """
    #expect(composer.maxY <= Self.region, "\(followed)")
    #expect(composer.maxY == frame.maxY, "The composer left the surfaces' bottom: \(composer)")

    // The content is deliberately taller than the slot. Making it fit is `PaneChatView`'s
    // job, and this has to hold either way.
    #expect(content.height > frame.height, "The fixture stopped reproducing: \(content)")
  }

  /// The negative. Attached to the surfaces' content, the composer and the probe hang off the
  /// region by half the overflow at each end. Without this, the modifier order in
  /// `TerminalScreen` reads as a style choice.
  @Test("attached to the content, the composer follows it under the keyboard")
  func theOverlayAttachedToTheContentHangsOffTheRegion() {
    let (frame, content, composer) = measureSurfaces(attachesToContent: true)

    #expect(frame.height > Self.region, "The content no longer overflows the region: \(frame)")
    #expect(content.minY < 0, "The content no longer hangs off the top: \(content)")
    let escaped = """
      The composer no longer follows the overflowing content under the keyboard: \(composer). \
      The negative no longer reproduces, so this test no longer shows why `TerminalScreen` \
      attaches the overlay to the region and not to the content.
      """
    #expect(composer.maxY > Self.region, "\(escaped)")
  }

  /// A `.frame(minHeight:)` is `max(floor, min(content, proposal))`, so it is already the slot,
  /// and the overflow is the content centred inside it.
  @Test("a floor reports the slot and centres what will not fit — the frame never grows")
  func theOverflowIsTheContentAndNotTheFrame() {
    let (frame, content, _) = measureSurfaces(attachesToContent: false)

    #expect(frame.height == Self.region, "The frame grew to hold its content: \(frame)")
    let hangs = """
      The content is \(content.height) pt in a \(frame.height) pt frame and should hang off \
      both ends of it: \(content).
      """
    #expect(content.minY < frame.minY, "\(hangs)")
    #expect(content.maxY > frame.maxY, "\(hangs)")
  }

  /// The surfaces are a `ZStack` of the terminals and the chat. The terminals take the height
  /// they are proposed, so the stack's height, and the grid SwiftTerm reports to the far side,
  /// is whatever the chat asks for. A chat that does not fit tells the far side about rows
  /// nobody can read.
  @Test("the terminal is sized by its tallest sibling, so a chat that fits is what fixes it")
  func theTerminalIsSizedByTheChatBesideIt() {
    func terminalHeight(chat: CGFloat) -> CGFloat {
      var terminal = CGRect.zero
      let window = HostedProbe.window(
        VStack(spacing: 0) {
          ZStack {
            // The terminals: flexible in both axes.
            Color.black
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .measuredFrame(into: { terminal = $0 })
            // The chat, with its own minimum.
            Color.blue
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .frame(minHeight: chat)
          }
          .frame(minHeight: 0)
          .clipped()
        },
        size: CGSize(width: 874, height: Self.region)
      )
      withExtendedLifetime(window) {}
      return terminal.height
    }

    let before = terminalHeight(chat: Surfaces.chatMinimumBefore)
    let after = terminalHeight(chat: Surfaces.chatMinimumAfter)

    let dragged = """
      A \(Surfaces.chatMinimumBefore) pt chat should drag the terminal beside it to the same \
      height in a \(Self.region) pt region, and it measured \(before). That is the grid \
      SwiftTerm sizes from — the rows past the region are the ones nobody can read.
      """
    #expect(before > Self.region, "\(dragged)")
    let fits = """
      With the chat down to \(Surfaces.chatMinimumAfter) pt the terminal should get exactly \
      the region, and it measured \(after).
      """
    #expect(after == Self.region, "\(fits)")
  }
}
