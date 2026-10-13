import Foundation
import Testing

@testable import DriverrCore

/// What an opened run of tool calls says, and which runs count as open.
@Suite("Opening a run of tool calls")
struct ToolRunOpeningTests {
  /// Long runs are common: one real session had 482 records for 14 turns.
  private func longRun() -> ToolRun {
    ToolRun(
      calls: (1...34).map { ToolCall(name: "Read", target: "old\($0).swift") }
        + [
          ToolCall(name: "Read", target: "pool.rs"),
          ToolCall(name: "Edit", target: "PTYBridge.swift"),
          ToolCall(name: "Bash", target: "cargo test"),
          ToolCall(name: "Grep", target: "open_session"),
          ToolCall(name: "Read", target: "session.rs"),
          ToolCall(name: "Edit", target: "pool.rs"),
        ]
    )
  }

  // MARK: - What a closed run names

  /// Chosen backwards and read forwards, as `openedCalls` does.
  @Test("a closed run names its three most recent calls, oldest of the three first")
  func aClosedRunNamesItsThreeMostRecentCalls() {
    let closed = longRun().closedCalls
    #expect(closed.count == 3)
    #expect(closed.map(\.name) == ["Grep", "Read", "Edit"])
    #expect(closed.map(\.target) == ["open_session", "session.rs", "pool.rs"])
  }

  /// Terser than the opened run's sentence; see `moreCalls`.
  @Test("a closed run counts the calls it did not name")
  func aClosedRunCountsTheRest() {
    #expect(longRun().moreCalls == "+37 more")
    #expect(ToolRun(calls: (1...40).map { ToolCall(name: "Read", target: "f\($0)") }).moreCalls
      == "+37 more")
  }

  @Test("three calls leave nothing over and four leave one")
  func theBoundaryEitherSideOfTheClosedLimit() {
    let three = ToolRun(calls: (1...3).map { ToolCall(name: "Read", target: "f\($0)") })
    #expect(three.closedCalls.count == 3)
    #expect(three.moreCalls == nil)

    let four = ToolRun(calls: (1...4).map { ToolCall(name: "Read", target: "f\($0)") })
    #expect(four.closedCalls.count == 3)
    #expect(four.moreCalls == "+1 more")
    #expect(four.closedCalls.map(\.target) == ["f2", "f3", "f4"])
  }

  /// The commonest run there is.
  @Test("a one-call run names its one call and says nothing after it")
  func aOneCallRunSaysNothingExtra() {
    let one = ToolRun(calls: [ToolCall(name: "Bash", target: "cargo test")])
    #expect(one.closedCalls.map(\.name) == ["Bash"])
    #expect(one.moreCalls == nil)
  }

  /// Closed names fewer than opened, which keeps the chevron worth a tap.
  @Test("the closed limit is half the open one")
  func closedIsHalfOfOpen() {
    #expect(ToolRun.closedLimit == 3)
    #expect(ToolRun.closedLimit * 2 == ToolRun.openLimit)
  }

  // MARK: - What an opened run lists

  @Test("an opened run names its six most recent calls, oldest of the six first")
  func anOpenedRunNamesItsSixMostRecentCalls() {
    let opened = longRun().openedCalls
    #expect(opened.count == 6)
    #expect(
      opened.map(\.name) == ["Read", "Edit", "Bash", "Grep", "Read", "Edit"]
    )
    #expect(opened.first?.target == "pool.rs")
    #expect(opened.last?.target == "pool.rs")
  }

  @Test("the calls an opened run did not name are counted")
  func theRestAreCounted() {
    #expect(longRun().earlierCalls == "…and 34 earlier calls, same kinds.")
  }

  /// Guards against a `suffix(6)` with a hard-coded sentence under it.
  @Test("a short run opens to its actual length with nothing left over")
  func aShortRunOpensToItsActualLength() {
    let run = ToolRun(
      calls: [
        ToolCall(name: "Read", target: "Cargo.toml"),
        ToolCall(name: "Bash", target: "cargo test"),
        ToolCall(name: "Edit", target: "pool.rs"),
      ]
    )
    #expect(run.openedCalls.count == 3)
    #expect(run.openedCalls.map(\.target) == ["Cargo.toml", "cargo test", "pool.rs"])
    #expect(run.earlierCalls == nil)
  }

  @Test("six calls leave nothing over and seven leave one")
  func theBoundaryEitherSideOfTheLimit() {
    let six = ToolRun(calls: (1...6).map { ToolCall(name: "Read", target: "\($0).swift") })
    #expect(six.openedCalls.count == 6)
    #expect(six.earlierCalls == nil)

    let seven = ToolRun(calls: (1...7).map { ToolCall(name: "Read", target: "\($0).swift") })
    #expect(seven.openedCalls.count == 6)
    #expect(seven.openedCalls.first?.target == "2.swift")
    #expect(seven.earlierCalls == "…and 1 earlier call, same kinds.")
  }

  /// The row's tally counts every call in the run, which is what makes "same kinds" true.
  @Test("the kinds tally covers the calls the opened run did not name")
  func theKindsTallyCoversTheWholeRun() {
    let run = ToolRun(
      calls: [ToolCall(name: "WebFetch", target: "docs")]
        + (1...6).map { ToolCall(name: "Read", target: "\($0).swift") }
    )
    #expect(run.openedCalls.allSatisfy { $0.name == "Read" })
    #expect(run.earlierCalls == "…and 1 earlier call, same kinds.")
    #expect(run.kindsSummary == "Read ×6 · WebFetch ×1")
  }

  // MARK: - One call, in words

  @Test("a call is spoken as its name and its target")
  func aCallIsSpokenWithItsTarget() {
    #expect(ToolCall(name: "Edit", target: "PTYBridge.swift").accessibilityLabel == "Edit, PTYBridge.swift")
  }

  @Test("a call with no target is spoken as its name alone")
  func aCallWithNoTargetIsSpokenAsItsNameAlone() {
    #expect(ToolCall(name: "Bash").accessibilityLabel == "Bash")
    #expect(ToolCall(name: "Bash", target: "").accessibilityLabel == "Bash")
  }

  // MARK: - A shorter name for an MCP tool

  @Test("an mcp tool's name is shortened to tool · server")
  func mcpDisplayName() {
    let call = ToolCall(name: "mcp__plugin_chrome-devtools-mcp_chrome-devtools__take_screenshot")
    #expect(call.displayName == "take_screenshot · plugin_chrome-devtools-mcp_chrome-devtools")
  }

  @Test("an ordinary tool's display name is its own name")
  func ordinaryDisplayName() {
    #expect(ToolCall(name: "Bash").displayName == "Bash")
  }

  @Test("kindsSummary still counts by the raw name, not the display name")
  func kindsSummaryUsesRawName() {
    let run = ToolRun(calls: [
      ToolCall(name: "mcp__server_a__take_screenshot"),
      ToolCall(name: "mcp__server_b__take_screenshot"),
    ])
    // Two tools that only display the same must not merge.
    #expect(run.kinds.count == 2)
  }

  // MARK: - Which runs are open

  private func turn(_ id: String, _ run: ToolRun) -> TranscriptTurn {
    TranscriptTurn(id: id, speech: .tools(run))
  }

  @Test("a run is closed until someone opens it")
  func aRunIsClosedUntilSomeoneOpensIt() {
    let runs = OpenToolRuns()
    #expect(!runs.isOpen(turn("1", longRun())))
  }

  @Test("opening a run opens it, and opening it again closes it")
  func openingAndClosing() {
    var runs = OpenToolRuns()
    let one = turn("1", longRun())
    runs.toggle(one)
    #expect(runs.isOpen(one))
    runs.toggle(one)
    #expect(!runs.isOpen(one))
  }

  @Test("opening one run leaves every other run closed")
  func runsAreIndependent() {
    var runs = OpenToolRuns()
    let one = turn("1", longRun())
    let two = turn("2", ToolRun(calls: [ToolCall(name: "Read", target: "a.swift")]))
    runs.toggle(one)
    #expect(runs.isOpen(one))
    #expect(!runs.isOpen(two))
  }

  /// A page fetched twice has the same record ids, so a re-read keeps what was opened.
  @Test("the same run fetched again is still open")
  func theSameRunFetchedAgainIsStillOpen() {
    var runs = OpenToolRuns()
    runs.toggle(turn("1", longRun()))
    #expect(runs.isOpen(turn("1", longRun())))
  }

  /// A run takes the id of its first record, so a run that has grown, or was cut differently
  /// by a page boundary, arrives with the opened run's id and different calls.
  @Test("a run that came back different is not the run that was opened")
  func aRunThatCameBackDifferentIsClosed() {
    var runs = OpenToolRuns()
    let opened = longRun()
    runs.toggle(turn("1", opened))

    let grown = ToolRun(calls: opened.calls + [ToolCall(name: "Bash", target: "cargo build")])
    #expect(!runs.isOpen(turn("1", grown)))
  }

  @Test("a turn that is not a run is never open")
  func aTurnThatIsNotARunIsNeverOpen() {
    var runs = OpenToolRuns()
    let said = TranscriptTurn(id: "1", speech: .assistant("The pool is async now."))
    runs.toggle(said)
    #expect(!runs.isOpen(said))
  }
}
