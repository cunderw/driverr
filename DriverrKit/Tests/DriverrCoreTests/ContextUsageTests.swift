import DriverrCore
import Foundation
import Testing

/// What the provenance row says about the context count.
struct ContextUsageTests {
  private func usage(_ total: Int) -> ContextUsage {
    ContextUsage(inputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: total)
  }

  @Test("the compact count rounds down and changes unit at the edges")
  func compactEdges() {
    let cases: [(Int, String)] = [
      (0, "0 context"),
      (999, "999 context"),
      (1_000, "1k context"),
      (8_450, "8.4k context"),
      (9_999, "9.9k context"),
      (10_000, "10k context"),
      (84_999, "84k context"),
      (999_999, "999k context"),
      (1_000_000, "1M context"),
      (1_250_000, "1.2M context"),
      (12_000_000, "12M context"),
    ]
    for (total, expected) in cases {
      #expect(usage(total).compact == expected, "\(total)")
    }
  }

  @Test("the spoken form and the breakdown state the whole number")
  func spokenAndBreakdown() {
    let usage = ContextUsage(inputTokens: 3, cacheCreationTokens: 1_204, cacheReadTokens: 81_006)
    #expect(usage.totalTokens == 82_213)
    #expect(usage.spoken == "82,213 tokens in context")
    #expect(
      usage.breakdown
        == "82,213 tokens in context: 3 input, 1,204 cache write, 81,006 cache read"
    )
  }

  @Test("a page stopped short keeps its count")
  func stoppingShortKeepsTheCount() {
    let usage = ContextUsage(inputTokens: 3, cacheCreationTokens: 1_204, cacheReadTokens: 81_006)
    let page = Transcript(
      turns: [TranscriptTurn(id: "a1", speech: .assistant("done"), at: nil)],
      window: TranscriptWindow(bytesFetched: 10, bytesRead: 10, fileSizeInBytes: 100, records: 1),
      contextUsage: usage
    )
    let short = page.stoppingShort()
    #expect(short.window.stoppedShort)
    #expect(short.contextUsage == usage)
  }

  private func source() -> TranscriptSource {
    TranscriptSource(
      file: TranscriptFile(
        path: "/Users/x/.claude/projects/-x-driverr/3f8c1d20-0000-4000-8000-000000000002.jsonl",
        sizeInBytes: 541_536,
        age: 0
      ),
      provenance: .matchedByDirectory,
      directory: "/Users/x/Dev/projects/driverr"
    )
  }

  @Test("the header speaks the count as its value and leaves the label alone")
  func headerSpeaksTheCount() {
    let usage = ContextUsage(inputTokens: 3, cacheCreationTokens: 1_204, cacheReadTokens: 81_006)
    let with = TranscriptHeader(agentName: "Claude", source: source(), contextUsage: usage)
    let without = TranscriptHeader(agentName: "Claude", source: source())
    #expect(with.accessibilityValue == "82,213 tokens in context")
    #expect(without.accessibilityValue == nil)
    #expect(with.accessibilityLabel == without.accessibilityLabel)
    #expect(with.caption == without.caption)
  }
}
