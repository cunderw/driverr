import Foundation
import Testing

/// The kit's fakes and in-memory stores are test doubles, so a Release build compiles none of
/// them.
///
/// A source scan, because nothing else reports a new one that ships. The Release build fails
/// when non-`DEBUG` code uses a guarded type. It does not fail when a new type has no guard.
struct DebugOnlyFixturesTests {
  /// `DriverrKit/Sources`, found from this file in `DriverrKit/Tests/DriverrCoreTests`.
  private static let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources")

  /// Every Swift file in the kit's five modules, as a path below `Sources` and its text.
  ///
  /// Throws if `Sources` is not where this file expects it, and requires at least one file,
  /// so a scan of nothing cannot pass.
  private static func swiftFiles() throws -> [(path: String, text: String)] {
    let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
      .filter { $0.hasSuffix(".swift") }
      .sorted()
    try #require(!paths.isEmpty, "no Swift file under \(sources.path)")
    return try paths.map { path in
      (path, try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8))
    }
  }

  /// The lines a Release build compiles: every line that is not blank, not a `#if` directive
  /// and not inside a `#if DEBUG` branch.
  ///
  /// `#else` and `#elseif` count as outside, whatever the condition was. That is stricter
  /// than the compiler for `#if !DEBUG`, which the kit does not use.
  private static func linesOutsideDebug(in text: String) -> [(number: Int, text: String)] {
    var branches: [Bool] = []
    var outside: [(number: Int, text: String)] = []
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#if ") {
        branches.append(trimmed == "#if DEBUG")
      } else if trimmed.hasPrefix("#else") {
        if !branches.isEmpty { branches[branches.count - 1] = false }
      } else if trimmed.hasPrefix("#endif") {
        _ = branches.popLast()
      } else if !trimmed.isEmpty, !branches.contains(true) {
        outside.append((index + 1, trimmed))
      }
    }
    return outside
  }

  @Test("Every Fake file is inside #if DEBUG from its first line to its last")
  func fakeFilesAreDebugOnly() throws {
    let fakes = try Self.swiftFiles().filter {
      URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("Fake")
    }
    for fake in fakes {
      if let line = Self.linesOutsideDebug(in: fake.text).first {
        Issue.record(
          "\(fake.path):\(line.number) is outside #if DEBUG, so Release compiles it: \(line.text)")
      }
    }
  }

  @Test("Every InMemory actor is declared inside #if DEBUG")
  func inMemoryActorsAreDebugOnly() throws {
    for file in try Self.swiftFiles() {
      for line in Self.linesOutsideDebug(in: file.text) where line.text.contains("actor InMemory") {
        Issue.record(
          "\(file.path):\(line.number) is outside #if DEBUG, so Release compiles it: \(line.text)")
      }
    }
  }
}
