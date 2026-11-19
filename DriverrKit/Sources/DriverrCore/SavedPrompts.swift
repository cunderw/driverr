import Foundation

/// A prompt the reader saved from the composer, to insert again later.
///
/// Global, not per host or per pane: the same instruction is worth repeating to any agent.
public struct SavedPrompt: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  /// What the list shows. The first line of `text` until the reader renames it.
  public var name: String
  /// What an insert puts in the composer.
  public let text: String

  public init(id: UUID = UUID(), name: String, text: String) {
    self.id = id
    self.name = name
    self.text = text
  }

  /// The second line a row draws under the name: what the name does not already say, or
  /// `nil` when it says all of it.
  ///
  /// A save names a prompt after its first line, so that line is left out: a one-line prompt
  /// has no preview, and a longer one previews the rest. After a rename the whole text is the
  /// preview, because the name no longer quotes it.
  public var preview: String? {
    var lines = text.split(whereSeparator: \.isNewline).map(String.init)
    while let first = lines.first, RenameLabel.sanitised(first) == nil { lines.removeFirst() }
    if let first = lines.first, RenameLabel.sanitised(first) == name { lines.removeFirst() }
    return RenameLabel.sanitised(lines.joined(separator: "\n"))
  }
}

/// The saved prompts and every rule about changing them. A value, so `swift test` covers the
/// rules and the app's model only stores the result.
///
/// The newest save is first. A rename keeps a prompt where it is, so a row does not move
/// under a thumb.
public struct SavedPromptList: Codable, Equatable, Sendable {
  public private(set) var prompts: [SavedPrompt]

  /// The longest name a save gives a prompt, in characters, before the ellipsis.
  public static let defaultNameLimit = 40

  public init(_ prompts: [SavedPrompt] = []) {
    self.prompts = prompts
  }

  /// Whether `text` would be saved: it holds more than whitespace and is not already in the
  /// list.
  public func canSave(_ text: String) -> Bool {
    guard let trimmed = RenameLabel.sanitised(text) else { return false }
    return !prompts.contains { $0.text == trimmed }
  }

  /// Saves `text`, trimmed at both ends, at the top of the list. Returns the new prompt, or
  /// `nil` when `canSave` refuses: an empty prompt is no use, and a second copy of the same
  /// text is a row that does nothing new.
  @discardableResult
  public mutating func save(_ text: String, id: UUID = UUID()) -> SavedPrompt? {
    guard canSave(text), let trimmed = RenameLabel.sanitised(text) else { return nil }
    let prompt = SavedPrompt(id: id, name: Self.defaultName(for: trimmed), text: trimmed)
    prompts.insert(prompt, at: 0)
    return prompt
  }

  /// Gives the prompt `id` a new name, trimmed at both ends. Returns `false` and changes
  /// nothing for an empty name or an unknown id.
  @discardableResult
  public mutating func rename(_ id: UUID, to name: String) -> Bool {
    guard let label = RenameLabel.sanitised(name),
      let index = prompts.firstIndex(where: { $0.id == id })
    else { return false }
    prompts[index].name = label
    return true
  }

  /// Removes the prompt `id`. An unknown id changes nothing.
  public mutating func delete(_ id: UUID) {
    prompts.removeAll { $0.id == id }
  }

  /// The name a save gives `text`: its first line that holds anything, cut to
  /// `defaultNameLimit` characters with an ellipsis.
  public static func defaultName(for text: String) -> String {
    let firstLine =
      text.split(whereSeparator: \.isNewline)
      .lazy
      .compactMap { RenameLabel.sanitised(String($0)) }
      .first ?? ""
    guard firstLine.count > defaultNameLimit else { return firstLine }
    let cut = firstLine.prefix(defaultNameLimit).trimmingCharacters(in: .whitespaces)
    return cut + "…"
  }
}

/// Where a saved prompt lands in the composer.
public enum SavedPromptInsertion {
  /// The composer's text after inserting `prompt` into `text`.
  ///
  /// An empty field takes the prompt as it is. Otherwise the prompt goes at the end, after
  /// one space, or straight after the text when it already ends in whitespace. Nothing is
  /// sent: the reader still reads and sends.
  public static func inserting(_ prompt: String, into text: String) -> String {
    guard !text.isEmpty else { return prompt }
    if let last = text.last, last.isWhitespace { return text + prompt }
    return text + " " + prompt
  }
}

/// Where the saved prompts are kept.
public protocol SavedPromptStore: Sendable {
  func prompts() async -> [SavedPrompt]
  func save(_ prompts: [SavedPrompt]) async
}

#if DEBUG
/// A non-persistent store for tests, previews and UI runs, so one UI test's save cannot reach
/// the next launch.
public actor InMemorySavedPromptStore: SavedPromptStore {
  private var current: [SavedPrompt]

  public init(_ initial: [SavedPrompt] = []) { current = initial }

  public func prompts() async -> [SavedPrompt] { current }
  public func save(_ prompts: [SavedPrompt]) async { current = prompts }
}
#endif
