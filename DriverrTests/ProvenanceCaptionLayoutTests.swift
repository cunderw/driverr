import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The chat's provenance caption must not clip on the phone. It ends with the file's age, the
/// one fact on the row that says whether the session is still alive.
///
/// This tier cannot read the rendered string back, so it lays the same row out twice and
/// compares the caption's width. Given room, a `Text` takes its intrinsic width; clamped, it
/// elides. A caption as wide at 402 pt as at 2000 pt rendered whole.
/// `theProbeCanSeeATruncation` shows the comparison can also come out the other way.
///
/// The whole-caption tests are for a row without a context count. `theCountSurvives` covers a
/// row with one, where the caption gives way on the phone.
///
/// At 402 pt the row leaves its caption 341 pt, the number `ProvenanceRow` and
/// `TranscriptHeader.caption` are sized against. It measures the real `ProvenanceRow`, because
/// the subject is that row's `.lineLimit(1)` and truncation mode.
///
/// `.serialized`: see `ChatGlassLayoutTests`.
@MainActor
@Suite("Chat provenance caption", .serialized)
struct ProvenanceCaptionLayoutTests {
  /// The widest caption the app can produce for a six-character agent name: the matched
  /// variant, which carries the longest scope phrase, with the longest age phrase.
  private func widestHeader(contextUsage: ContextUsage? = nil) -> TranscriptHeader {
    TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: TranscriptFile(
          path: "/Users/x/.claude/projects/-x-driverr/3f8c1d20-0000-4000-8000-000000000002.jsonl",
          sizeInBytes: 541_536,
          age: 0
        ),
        provenance: .matchedByDirectory,
        directory: "/Users/x/Dev/projects/driverr"
      ),
      contextUsage: contextUsage
    )
  }

  /// A herdr-core Claude's caption, which carries the other scope phrase of that length.
  private func recordHeader() -> TranscriptHeader {
    TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: TranscriptFile(path: "/x/s.jsonl", sizeInBytes: 1, age: 0),
        provenance: .reportedByHerdr(sessionID: "s"),
        directory: "/x"
      ),
      session: AgentSession(
        agent: "claude", kind: "id", value: "s", source: AgentSession.claudeRecordSource)
    )
  }

  /// The caption's frame when the row is laid out at `width`.
  private func captionFrame(at width: CGFloat, header: TranscriptHeader? = nil) -> CGRect {
    var caption = CGRect.zero
    let window = HostedProbe.window(
      ProvenanceRow(header: header ?? widestHeader(), onCaptionFrame: { caption = $0 }),
      size: CGSize(width: width, height: HostedProbe.phone.height)
    )
    withExtendedLifetime(window) {}
    return caption
  }

  /// The caption's and the context count's frames when the row carries a count.
  private func frames(
    at width: CGFloat, usage: ContextUsage, typeSize: DynamicTypeSize = .large
  ) -> (caption: CGRect, count: CGRect) {
    var caption = CGRect.zero
    var count = CGRect.zero
    let window = HostedProbe.window(
      ProvenanceRow(
        header: widestHeader(contextUsage: usage),
        onCaptionFrame: { caption = $0 },
        onCountFrame: { count = $0 }
      )
      .environment(\.dynamicTypeSize, typeSize),
      size: CGSize(width: width, height: HostedProbe.phone.height)
    )
    withExtendedLifetime(window) {}
    return (caption, count)
  }

  /// The widest count the formatter writes below a million: three digits and a unit.
  private static let widestCount = ContextUsage(
    inputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 999_999
  )

  /// Wide enough that nothing clamps the caption, so it reports what it wants to be.
  private static let unclamped: CGFloat = 2000

  /// Without a context count. See `theCountSurvives` for the Claude case.
  @Test("the whole caption renders at 402 pt without a context count, age included")
  func theCaptionSurvivesOnThePhone() {
    expectTheCaptionIsWhole(at: HostedProbe.phone.width, on: "phone")
  }

  /// The caption wording is shared by every device, so the pad is pinned too.
  @Test("the whole caption renders at 1032 pt without a context count, age included")
  func theCaptionSurvivesOnThePad() {
    expectTheCaptionIsWhole(at: HostedProbe.pad.width, on: "pad")
  }

  @Test("Claude's record fits on the phone too")
  func theRecordCaptionSurvivesOnThePhone() {
    let clamped = captionFrame(at: HostedProbe.phone.width, header: recordHeader())
    let wanted = captionFrame(at: Self.unclamped, header: recordHeader())
    #expect(wanted.width > 0)
    #expect(clamped.width >= wanted.width - 0.5)
  }

  /// Lays out a row without a context count; `theCountSurvives` measures the row with one.
  private func expectTheCaptionIsWhole(at width: CGFloat, on device: String) {
    let clamped = captionFrame(at: width)
    let wanted = captionFrame(at: Self.unclamped)

    #expect(
      clamped.width >= wanted.width - 0.5,
      """
      The provenance caption resolves to \(clamped.width) pt on the \(device) at \(width) pt, \
      against the \(wanted.width) pt it takes when nothing clamps it, so \
      \(wanted.width - clamped.width) pt of it is elided. The caption ends with \
      the file's age, so what is thrown away is the only evidence on the row that the session \
      is still alive. Either the scope phrase in `TranscriptHeader.caption` grew again, or the \
      row stopped leaving the caption its 16 pt inset and \(ProvenanceRow.glyphGap) pt glyph gap.
      """
    )

    let inset = ProvenanceRow.horizontalPadding
    #expect(
      clamped.maxX <= width - inset + 0.5,
      """
      The caption runs to x \(clamped.maxX) on the \(device) at \(width) pt, past the \
      \(width - inset) pt the row's own \(inset) pt inset leaves it.
      """
    )
  }

  /// Without this, a probe that measured the wrong view would pass the two tests above.
  @Test("the probe can see a truncation when there is one")
  func theProbeCanSeeATruncation() {
    let squeezed = captionFrame(at: 300)
    let wanted = captionFrame(at: Self.unclamped)

    #expect(
      squeezed.width < wanted.width - 0.5,
      """
      The caption reports \(squeezed.width) pt in a 300 pt window and \(wanted.width) pt \
      unclamped, so it is not being clamped at all — this probe cannot tell a truncated \
      caption from a whole one, and every other assertion in this suite passes vacuously.
      """
    )
  }

  /// The count is `fixedSize`, so the caption gives way. What the caption keeps is printed,
  /// because that trade is a design judgement.
  @Test("the context count renders whole beside the caption on the phone and the pad")
  func theCountSurvives() {
    for (device, width) in [("phone", HostedProbe.phone.width), ("pad", HostedProbe.pad.width)] {
      let clamped = frames(at: width, usage: Self.widestCount)
      let wanted = frames(at: Self.unclamped, usage: Self.widestCount)
      let bare = captionFrame(at: Self.unclamped)
      print(
        """
        [provenance count] \(device) \(width) pt: count \(clamped.count.width) pt \
        at x \(clamped.count.minX), \
        caption \(clamped.caption.width) of \(bare.width) pt wanted
        """
      )

      #expect(clamped.count.width > 0, "The \(device) row drew no count at all.")
      #expect(
        clamped.count.width >= wanted.count.width - 0.5,
        """
        The count resolves to \(clamped.count.width) pt on the \(device), against the \
        \(wanted.count.width) pt it takes unclamped, so it is being truncated. It must not be.
        """
      )
      let inset = ProvenanceRow.horizontalPadding
      #expect(
        clamped.count.maxX <= width - inset + 0.5,
        "The count runs to x \(clamped.count.maxX), past the row's \(inset) pt inset."
      )
      #expect(
        clamped.caption.maxX <= clamped.count.minX - ProvenanceRow.glyphGap + 0.5,
        """
        The caption ends at x \(clamped.caption.maxX) and the count starts at \
        \(clamped.count.minX) on the \(device): they collide.
        """
      )
    }
  }

  /// The pad has the room, so a count there costs the caption nothing.
  @Test("the caption stays whole on the pad with a count beside it")
  func theCaptionStaysWholeOnThePadWithACount() {
    let clamped = frames(at: HostedProbe.pad.width, usage: Self.widestCount)
    let bare = captionFrame(at: Self.unclamped)
    #expect(
      clamped.caption.width >= bare.width - 0.5,
      "The pad elides \(bare.width - clamped.caption.width) pt of the caption beside a count."
    )
  }

  /// Above AX1 the row stops growing. Uncapped, the `fixedSize` count took 185 pt of the phone's
  /// row at AX3 and left the caption drawing "Clau…ago".
  @Test("the row lays out at AX3 and AX5 exactly as at AX1")
  func theRowIsCappedAtAX1() {
    let width = HostedProbe.phone.width
    let ax1 = frames(at: width, usage: Self.widestCount, typeSize: .accessibility1)
    for size in [DynamicTypeSize.accessibility3, .accessibility5] {
      let larger = frames(at: width, usage: Self.widestCount, typeSize: size)
      print(
        "[provenance count AX] \(size): count \(larger.count.width) pt, "
          + "caption \(larger.caption.width) pt")
      #expect(
        abs(larger.count.width - ax1.count.width) < 0.5
          && abs(larger.caption.width - ax1.caption.width) < 0.5,
        """
        At \(size) the count is \(larger.count.width) pt and the caption \(larger.caption.width) pt, \
        against \(ax1.count.width) and \(ax1.caption.width) at AX1: the row is not capped.
        """
      )
    }
  }
}
