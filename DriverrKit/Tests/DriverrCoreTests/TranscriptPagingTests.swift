import Testing

@testable import DriverrCore

/// What the pager says, so a reader can see what a tap costs before taking it.
@Suite("Transcript paging")
struct TranscriptPagingTests {
  /// Six turns held, more behind them.
  private func midFile(
    turnsHeld: Int = 6,
    bytesFetched: Int = 62_914,
    bytesRead: Int = 245_760,
    fileSizeInBytes: Int = 2_411_724,
    increment: Int = TranscriptPaging.defaultIncrement
  ) -> TranscriptPaging {
    TranscriptPaging(
      turnsHeld: turnsHeld,
      window: TranscriptWindow(
        bytesFetched: bytesFetched,
        bytesRead: bytesRead,
        fileSizeInBytes: fileSizeInBytes,
        records: 60
      ),
      increment: increment
    )
  }

  private func wholeFile(turnsHeld: Int = 23, bytesFetched: Int = 7_065) -> TranscriptPaging {
    TranscriptPaging(
      turnsHeld: turnsHeld,
      window: TranscriptWindow(
        bytesFetched: bytesFetched,
        bytesRead: bytesFetched,
        fileSizeInBytes: bytesFetched,
        records: 40,
        reachesStartOfFile: true
      )
    )
  }

  // MARK: - What you have

  @Test("the header states the turns held and the bytes measured, with no tilde")
  func heldStatesMeasuredBytes() {
    let paging = midFile()
    #expect(paging.held == "Last 6 turns · 61.4 KB fetched")
    #expect(!paging.held.contains("~"), "the fetched figure is measured, never an estimate")
  }

  @Test("reaching the start of the file says all rather than last")
  func heldSaysAllAtTheTop() {
    #expect(wholeFile().held == "All 23 turns · 6.9 KB fetched")
  }

  @Test("one turn is not one turns")
  func heldIsSingularForOne() {
    #expect(wholeFile(turnsHeld: 1, bytesFetched: 512).held == "All 1 turn · 512 B fetched")
  }

  // MARK: - What the next page costs

  @Test("the load control names the increment as an upper bound and marks its cost as an estimate")
  func loadMoreIsMarkedAsAnEstimate() throws {
    let paging = midFile()
    let title = try #require(paging.loadMore)
    #expect(title.hasPrefix("Load up to 14 more · ~"))
    #expect(title.contains("~"), "a projection must never render without its tilde")
  }

  /// Priced as the delta: `estimatedNextFetchBytes` (209,713) minus what `held` says was
  /// fetched (62,914).
  @Test("the load control prices the delta, not the whole re-fetched tail")
  func loadMorePricesTheDelta() {
    let paging = midFile()
    #expect(paging.loadMore == "Load up to 14 more · ~143.4 KB")
  }

  /// A tap re-reads a larger tail. 20/6 of 62,914 is 209,713, clamped to the file.
  @Test("the estimate scales this page's real bytes to the turns being asked for")
  func estimateScalesFromMeasuredBytes() {
    let paging = midFile()
    #expect(paging.estimatedNextFetchBytes == 209_713)
  }

  @Test("the estimate never exceeds what is left in the file")
  func estimateIsClampedToTheFile() {
    // 20/6 of 62,914 would be 209,713, but the file is only 80,000.
    let paging = midFile(fileSizeInBytes: 80_000)
    #expect(paging.estimatedNextFetchBytes == 80_000)
  }

  @Test("a page holding nothing cannot project a next page from it")
  func noEstimateWithoutAMeasurement() {
    let paging = midFile(turnsHeld: 0, bytesFetched: 0)
    #expect(paging.estimatedNextFetchBytes == nil)
    #expect(paging.loadMore == nil, "no figure means no priced control")
  }

  // MARK: - The start of the file

  @Test("reaching the start removes the control rather than disabling it")
  func startOfFileRemovesTheControl() {
    let paging = wholeFile()
    #expect(paging.loadMore == nil)
    #expect(paging.estimatedNextFetchBytes == nil)
    #expect(paging.startOfFile == "This is the start of the session file.")
  }

  @Test("mid-file says nothing about the start of the file")
  func midFileHasNoStartNotice() {
    #expect(midFile().startOfFile == nil)
  }

  // MARK: - What is behind the page

  /// A large file can hold only a few turns, so the size is stated and no turn count is
  /// claimed.
  @Test("an enormous file states its size and never guesses the turns behind it")
  func unfetchedStatesBytesNotTurns() throws {
    let notice = try #require(midFile().unfetched)
    #expect(notice == "The file is 2.3 MB. Driverr only ever fetches the tail.")
    #expect(!notice.contains("turn"), "a turn count for unread bytes is a guess, not a fact")
  }

  @Test("a file with nothing behind the page says nothing about the tail")
  func noUnfetchedNoticeAtTheTop() {
    #expect(wholeFile().unfetched == nil)
  }

  @Test("the whole surface reads as one sentence to a screen reader")
  func accessibilityLabelCarriesBothFigures() {
    let label = midFile().accessibilityLabel
    #expect(label.contains("Last 6 turns"))
    #expect(label.contains("Load up to 14 more"))
  }

  // MARK: - A page the reader stopped growing

  private func stalled(turnsHeld: Int = 2) -> TranscriptPaging {
    TranscriptPaging(
      turnsHeld: turnsHeld,
      window: TranscriptWindow(
        bytesFetched: 62_914,
        bytesRead: 15_728_640,
        fileSizeInBytes: 300_000_000,
        records: 60,
        stoppedShort: true
      )
    )
  }

  @Test("a page the reader stopped growing says so rather than reading as a short session")
  func stoppedShortIsNamed() {
    #expect(
      stalled().stoppedShort
        == "Driverr stopped before it had all the turns it asked for. Load more to keep reading."
    )
  }

  @Test("an ordinary page says nothing about stopping short")
  func noStoppedShortNoticeOnAnOrdinaryPage() {
    #expect(midFile().stoppedShort == nil)
    #expect(wholeFile().stoppedShort == nil)
  }

  /// `Last 2 turns` is what a two-turn session says too.
  @Test("the bill still states the page, and the notice states what the page is not")
  func theBillIsUnchangedByStoppingShort() {
    #expect(stalled().held == "Last 2 turns · 61.4 KB fetched")
    #expect(stalled().loadMore != nil, "there is always a way forward from a stalled page")
  }

  @Test("a page at the start of the file cannot be stopped short")
  func startOfFileWinsOverStoppedShort() {
    let window = TranscriptWindow(
      bytesFetched: 512,
      bytesRead: 512,
      fileSizeInBytes: 512,
      records: 4,
      reachesStartOfFile: true,
      stoppedShort: true
    )
    #expect(window.stoppedShort == false)
    #expect(TranscriptPaging(turnsHeld: 1, window: window).stoppedShort == nil)
  }

  @Test("a screen reader hears the notice, and hears it right after the bill")
  func stoppedShortIsSpoken() {
    let label = stalled().accessibilityLabel
    #expect(label.contains("Driverr stopped before it had all the turns it asked for."))
    #expect(!label.contains(".."), "no part is given a second full stop")
    let bill = label.range(of: "Last 2 turns")
    let notice = label.range(of: "Driverr stopped")
    let control = label.range(of: "Load up to")
    #expect(bill != nil && notice != nil && control != nil)
    if let bill, let notice, let control {
      #expect(bill.lowerBound < notice.lowerBound)
      #expect(notice.lowerBound < control.lowerBound)
    }
  }

  // MARK: - Byte phrasing

  @Test(
    "bytes read the way a person reads them",
    arguments: [
      (0, "0 B"),
      (837, "837 B"),
      (1023, "1023 B"),
      (1024, "1.0 KB"),
      (7_065, "6.9 KB"),
      (62_914, "61.4 KB"),
      (1_048_576, "1.0 MB"),
      (2_411_724, "2.3 MB"),
    ])
  func bytePhrasing(bytes: Int, phrase: String) {
    #expect(ByteSize.phrase(bytes) == phrase)
  }

  @Test("a KB figure keeps its trailing zero so it reads as a measurement")
  func keepsTheTrailingZero() {
    #expect(ByteSize.phrase(5_120) == "5.0 KB")
  }

  // MARK: - Spoken byte phrasing

  @Test(
    "bytes read the way a screen reader says them",
    arguments: [
      (0, "0 bytes"),
      (1, "1 byte"),
      (837, "837 bytes"),
      (1024, "1.0 kilobytes"),
      (3_072, "3.0 kilobytes"),
      (1_048_576, "1.0 megabytes"),
    ])
  func spokenBytePhrasing(bytes: Int, phrase: String) {
    #expect(ByteSize.spoken(bytes) == phrase)
  }

  @Test("the load control's spoken form names turns and bytes as words")
  func spokenLoadMoreNamesTurnsAndBytesAsWords() {
    let paging = TranscriptPaging(
      turnsHeld: 6,
      window: TranscriptWindow(
        bytesFetched: 3_072,
        bytesRead: 3_072,
        fileSizeInBytes: 20_000,
        records: 6
      ),
      increment: 14
    )
    #expect(paging.spokenLoadMore != nil)
    #expect(paging.spokenLoadMore?.hasPrefix("Load up to 14 more turns, about") == true)
    #expect(paging.spokenLoadMore?.contains("~") == false, "the spoken form is never typeset")
    #expect(paging.spokenLoadMore?.contains("KB") == false, "the spoken form spells the unit out")
  }

  @Test("the accessibility label carries the spoken figure, not the typeset one")
  func accessibilityLabelUsesTheSpokenFigure() {
    let label = midFile().accessibilityLabel
    #expect(!label.contains("~"), "the accessibility label must never read a tilde aloud")
    #expect(label.contains("kilobytes"), "the accessibility label must spell the unit out")
  }

  // MARK: - Whether the bill would restate the mid-record notice

  @Test("the bill is redundant only when the page reaches the start of a file that ends mid-record")
  func billIsRedundantAtStartOfFileWithATruncatedTail() {
    #expect(wholeFile().isBillRedundant(outcome: .endsMidRecord))
  }

  @Test("a truncated tail mid-file still has more behind it, so the bill is not redundant")
  func billIsNotRedundantMidFile() {
    #expect(!midFile().isBillRedundant(outcome: .endsMidRecord))
  }

  @Test("a whole file that parsed cleanly has no notice to restate, so the bill stands")
  func billIsNotRedundantWithoutATruncatedTail() {
    #expect(!wholeFile().isBillRedundant(outcome: .parsed))
  }
}
