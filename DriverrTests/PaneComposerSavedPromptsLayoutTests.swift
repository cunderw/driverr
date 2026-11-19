import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The saved list is laid out as part of the bar, above the card, and stops growing at its
/// cap. Measured through `onLayoutProbe`, which reports the whole bar. A hosted window cannot
/// tap, so the list starts open through `isShowingSavedPrompts`.
///
/// Row heights are differences between two bars that differ by one row, because there is no
/// identifier lookup in-process.
@MainActor
@Suite("Composer saved prompts layout")
struct PaneComposerSavedPromptsLayoutTests {
  private func model(holding count: Int) async -> SavedPromptsModel {
    let prompts = (0..<count).map { index in
      SavedPrompt(name: "Prompt \(index)", text: "Do the thing number \(index) and report back.")
    }
    let model = SavedPromptsModel(store: InMemorySavedPromptStore(prompts))
    await model.load()
    return model
  }

  private func barHeight(
    prompts count: Int?,
    open: Bool = true,
    isCollapsed: Bool = false,
    size: DynamicTypeSize = .large
  ) async -> Double {
    var height: Double = 0
    var state = PaneComposerState()
    state.text = "x"
    let composer = PreviewSupport.composer(for: PreviewSupport.agentPane, in: state)
    let saved: SavedPromptsModel? =
      if let count { await model(holding: count) } else { nil }
    let bar = PaneComposerBar(
      model: composer,
      header: PaneComposerHeader(pane: PreviewSupport.agentPane),
      onLayoutProbe: { height = Double($0.height) },
      isCollapsed: isCollapsed,
      savedPrompts: saved,
      isShowingSavedPrompts: open
    )
    .environment(\.dynamicTypeSize, size)
    let window = HostedProbe.window(bar)
    withExtendedLifetime(window) {}
    return height
  }

  @Test("the open list is part of the bar: the bar grows by the list")
  func theListIsInTheBar() async {
    let closed = await barHeight(prompts: 1, open: false)
    let open = await barHeight(prompts: 1)
    #expect(closed > 0)
    #expect(open > closed + 44, "closed \(closed), open \(open)")
  }

  @Test("an empty list still opens, with its sentence")
  func anEmptyListOpens() async {
    let closed = await barHeight(prompts: 0, open: false)
    let open = await barHeight(prompts: 0)
    #expect(open > closed + 44, "closed \(closed), open \(open)")
  }

  @Test("without a saved-prompt model the bar is unchanged and nothing opens")
  func noModelNoList() async {
    let without = await barHeight(prompts: nil)
    let closed = await barHeight(prompts: 3, open: false)
    #expect(without > 0)
    #expect(without == closed)
  }

  @Test("collapsed, the list does not draw")
  func collapsedDrawsNoList() async {
    let open = await barHeight(prompts: 2, isCollapsed: true)
    let closed = await barHeight(prompts: 2, open: false, isCollapsed: true)
    #expect(closed > 0)
    #expect(open == closed)
  }

  @Test("each row is at least 44 pt tall, and the list stops growing past four rows")
  func rowsAndCap() async {
    let one = await barHeight(prompts: 1)
    let two = await barHeight(prompts: 2)
    let four = await barHeight(prompts: 4)
    let five = await barHeight(prompts: 5)
    let twelve = await barHeight(prompts: 12)
    let row = two - one

    #expect(row >= 44, "a row is \(row) pt")
    #expect(abs(four - (one + 3 * row)) < 1, "four rows are not four rows tall: \(four)")
    #expect(five == twelve, "the list kept growing past its cap: 5 → \(five), 12 → \(twelve)")
    #expect(twelve < four + row, "the capped list is taller than five rows: \(twelve)")
  }

  @Test("at an accessibility size rows stay 44 pt or taller and the cap is two rows")
  func accessibilitySizeCap() async {
    let one = await barHeight(prompts: 1, size: .accessibility3)
    let two = await barHeight(prompts: 2, size: .accessibility3)
    let three = await barHeight(prompts: 3, size: .accessibility3)
    let eight = await barHeight(prompts: 8, size: .accessibility3)
    let row = two - one

    #expect(row >= 44, "a row is \(row) pt")
    #expect(three == eight, "the list kept growing past its cap: 3 → \(three), 8 → \(eight)")
    #expect(eight < two + row, "the capped list is taller than three rows: \(eight)")
    // At this size the open bar must leave most of a phone for the conversation.
    #expect(eight < HostedProbe.phone.height / 2, "the open bar is \(eight) pt tall")
  }
}
