import Foundation

/// Where one hook stands in a settings file.
public enum AgentHookState: Hashable, Sendable {
  case absent
  /// The file carries this hook at this version or a later one. A later one was written by
  /// a newer Driverr, and an older one must not replace it.
  case installed(version: Int)
  /// The file carries this hook at an earlier version, which an install replaces in place.
  case outdated(version: Int)
}

/// Where a whole integration stands on a host, which is what the connect-time offer reads.
public enum AgentIntegrationStatus: Hashable, Sendable {
  /// No hook of the set is present.
  case absent
  /// Some are present and at least one is missing or older than the catalog's.
  case outdated
  /// Every hook of the set is present at its current version or later.
  case installed
}

/// Why a settings file could not be read or edited. None of these writes anything.
public enum HookSettingsError: Error, Hashable, Sendable {
  /// `JSONSerialization` rejects the file. It is reported, never replaced: the file is the
  /// user's, and a Claude Code that cannot read it says so itself.
  case invalidJSON
  /// Valid JSON, but a value Driverr would edit is the wrong kind: `path` names it, e.g.
  /// `hooks.PreToolUse` holding an object instead of an array.
  case unexpectedShape(path: String)
  /// A key Driverr would edit under appears more than once, e.g. two top-level `hooks`.
  case duplicateKey(path: String)
  /// A Driverr entry sits in a group whose matcher is not the hook's, at `path`. Driverr does
  /// not guess whether to move it or leave it.
  case markerUnderAnotherMatcher(path: String)
  /// The edited text did not parse to the original plus exactly the one change. This is a
  /// bug in the editor, and it is caught here rather than on the host.
  case verificationFailed
}

extension AgentIntegration {
  /// Each hook's state in the settings text, keyed by ``AgentHook/id``. `nil` text is a file
  /// that does not exist, where every hook is absent.
  public func hookStates(in text: String?) throws(HookSettingsError) -> [String: AgentHookState] {
    switch format {
    case .claudeCodeJSON:
      guard let text else { return Dictionary(uniqueKeysWithValues: hooks.map { ($0.id, .absent) }) }
      var states: [String: AgentHookState] = [:]
      for hook in hooks {
        states[hook.id] = try ClaudeSettingsEditor(text: text).find(hook).state
      }
      return states
    }
  }

  public func status(in text: String?) throws(HookSettingsError) -> AgentIntegrationStatus {
    let states = try hookStates(in: text).values
    if states.allSatisfy({ if case .installed = $0 { true } else { false } }) { return .installed }
    if states.allSatisfy({ $0 == .absent }) { return .absent }
    return .outdated
  }

  /// The settings text with every hook of the set installed, or `nil` when the file already
  /// has them all, so running an install twice changes nothing.
  ///
  /// `nil` text creates the file. Every other byte of an existing file is kept: the edit
  /// appends one group to the event's array, or replaces an outdated Driverr group where it
  /// stands, and creates `hooks` and the event's key when they are missing.
  public func installing(into text: String?) throws(HookSettingsError) -> String? {
    switch format {
    case .claudeCodeJSON:
      var current = text
      var changed = false
      for hook in hooks {
        if let edited = try ClaudeSettingsEditor.install(hook, into: current) {
          current = edited
          changed = true
        }
      }
      return changed ? current : nil
    }
  }
}

/// Claude Code's `settings.json`, edited by splicing text so the rest of the file keeps its
/// bytes. See `JSONSpan` for why it does not round-trip through `JSONSerialization`.
struct ClaudeSettingsEditor {
  /// Where the hook was found, and what an install does about it.
  struct Finding {
    let state: AgentHookState
    /// The entry an install replaces, when outdated.
    let location: EntryLocation?
  }

  /// An entry's place: the group's index in the event's array, and the entry's index in the
  /// group's `hooks`.
  struct EntryLocation: Equatable {
    let group: Int
    let entry: Int
  }

  let bytes: [UInt8]
  let root: JSONNode

  init(text: String) throws(HookSettingsError) {
    let data = Data(text.utf8)
    guard (try? JSONSerialization.jsonObject(with: data)) != nil,
      let root = try? JSONSpanParser.parse(Array(data))
    else { throw .invalidJSON }
    guard case .object = root else { throw .unexpectedShape(path: "the top level") }
    self.bytes = Array(data)
    self.root = root
  }

  /// The one command entry Claude Code runs for this hook.
  static func entry(for hook: AgentHook) -> JSONFragment {
    .object([("type", .string("command")), ("command", .string(hook.command))])
  }

  /// The group a fresh install appends: the hook's matcher and its one entry.
  static func group(for hook: AgentHook) -> JSONFragment {
    .object([("matcher", .string(hook.matcher)), ("hooks", .array([entry(for: hook)]))])
  }

  /// `hooks`, or `nil` when the file has none.
  func hooksObject() throws(HookSettingsError) -> JSONNode? {
    guard let member = try Self.onlyMember("hooks", of: root, path: "hooks") else { return nil }
    guard case .object = member.value else { throw .unexpectedShape(path: "hooks") }
    return member.value
  }

  /// The event's array under `hooks`, or `nil` when either key is missing.
  func eventArray(_ event: String) throws(HookSettingsError) -> JSONNode? {
    guard let hooks = try hooksObject(),
      let member = try Self.onlyMember(event, of: hooks, path: "hooks.\(event)")
    else { return nil }
    guard case .array = member.value else { throw .unexpectedShape(path: "hooks.\(event)") }
    return member.value
  }

  /// A key Driverr edits under must appear once. `JSONSerialization` keeps the first of a
  /// repeated key and Claude Code's own parser may keep another, so there is no one right
  /// place to edit.
  private static func onlyMember(_ key: String, of object: JSONNode, path: String) throws(HookSettingsError)
    -> JSONNode.Member?
  {
    guard case .object(let members, _) = object else { return nil }
    let matches = members.filter { $0.key == key }
    guard matches.count <= 1 else { throw .duplicateKey(path: path) }
    return matches.first
  }

  /// Looks at every command entry of every group under the hook's event.
  ///
  /// Only the marked entry is Driverr's. A group can hold the user's own commands beside it,
  /// so an outdated install replaces that one entry and nothing else. A marked entry in a
  /// group with a different matcher is refused: rewriting the user's matcher and leaving a
  /// second copy are both unsafe guesses.
  func find(_ hook: AgentHook) throws(HookSettingsError) -> Finding {
    guard case .array(let groups, _)? = try eventArray(hook.event) else {
      return Finding(state: .absent, location: nil)
    }
    var oldest: (location: EntryLocation, version: Int)?
    for (groupIndex, group) in groups.enumerated() {
      guard case .array(let entries, _)? = group.member("hooks")?.value else { continue }
      for (entryIndex, entry) in entries.enumerated() {
        guard let version = Self.version(of: hook, in: entry) else { continue }
        guard case .string(hook.matcher, _)? = group.member("matcher")?.value else {
          throw .markerUnderAnotherMatcher(path: "hooks.\(hook.event)[\(groupIndex)]")
        }
        if version >= hook.version { return Finding(state: .installed(version: version), location: nil) }
        if oldest == nil { oldest = (EntryLocation(group: groupIndex, entry: entryIndex), version) }
      }
    }
    guard let oldest else { return Finding(state: .absent, location: nil) }
    return Finding(state: .outdated(version: oldest.version), location: oldest.location)
  }

  /// The version in an entry whose command carries the hook's marker. A marker with no
  /// number after it reads as version 0, so it is replaced.
  static func version(of hook: AgentHook, in entry: JSONNode) -> Int? {
    guard case .string(let command, _)? = entry.member("command")?.value,
      let range = command.range(of: hook.marker)
    else { return nil }
    return Int(command[range.upperBound...].prefix { $0.isASCII && $0.isNumber }) ?? 0
  }

  /// The text with the hook installed, or `nil` when it already is. `nil` text is a file
  /// that does not exist yet.
  static func install(_ hook: AgentHook, into text: String?) throws(HookSettingsError) -> String? {
    guard let text else {
      let created = JSONFragment.object([("hooks", .object([(hook.event, .array([group(for: hook)]))]))])
      let result = created.rendered(indent: "", unit: "  ") + "\n"
      try verify(original: nil, edited: result, hook: hook, replacing: nil)
      return result
    }
    let editor = try ClaudeSettingsEditor(text: text)
    let finding = try editor.find(hook)
    if case .installed = finding.state { return nil }
    let result = try editor.splice(hook, replacing: finding.location)
    try verify(original: text, edited: result, hook: hook, replacing: finding.location)
    return result
  }

  // MARK: - Splicing

  private func splice(_ hook: AgentHook, replacing location: EntryLocation?) throws(HookSettingsError) -> String {
    if let location, case .array(let groups, _)? = try eventArray(hook.event),
      case .array(let entries, _)? = groups[location.group].member("hooks")?.value
    {
      let old = entries[location.entry].span
      let indent = leadingIndent(at: old.start)
      return replaced(old.start..<old.end, with: Self.entry(for: hook).rendered(indent: indent, unit: unit))
    }
    let group = Self.group(for: hook)
    if let array = try eventArray(hook.event) {
      return inserted(element: group, into: array)
    }
    if let hooks = try hooksObject() {
      return inserted(member: (hook.event, .array([group])), into: hooks)
    }
    return inserted(member: ("hooks", .object([(hook.event, .array([group]))])), into: root)
  }

  private func inserted(member: (String, JSONFragment), into object: JSONNode) -> String {
    guard case .object(let members, let span) = object else { return text }
    guard let last = members.last else {
      return filledEmpty(span) { indent in
        JSONFragment.quoted(member.0) + (indent == nil ? ":" : ": ") + member.1.rendered(indent: indent, unit: unit)
      }
    }
    let indent = leadingIndent(at: last.keyStart)
    let separator = indent.map { ",\n" + $0 } ?? ","
    let body = JSONFragment.quoted(member.0) + (indent == nil ? ":" : ": ") + member.1.rendered(indent: indent, unit: unit)
    return replaced(last.value.span.end..<last.value.span.end, with: separator + body)
  }

  private func inserted(element: JSONFragment, into array: JSONNode) -> String {
    guard case .array(let elements, let span) = array else { return text }
    guard let last = elements.last else {
      return filledEmpty(span) { indent in element.rendered(indent: indent, unit: unit) }
    }
    let indent = leadingIndent(at: last.span.start)
    let separator = indent.map { ",\n" + $0 } ?? ","
    return replaced(last.span.end..<last.span.end, with: separator + element.rendered(indent: indent, unit: unit))
  }

  /// Fills `{}` or `[]` (whitespace inside allowed) with one entry, on its own line one
  /// level in when the file is written on several lines, and inline otherwise.
  private func filledEmpty(_ span: JSONSpan, entry: (String?) -> String) -> String {
    let interior = (span.start + 1)..<(span.end - 1)
    guard isMultiline else { return replaced(interior, with: entry(nil)) }
    let outer = lineIndent(at: span.start)
    let inner = outer + unit
    return replaced(interior, with: "\n" + inner + entry(inner) + "\n" + outer)
  }

  // MARK: - Text

  private var text: String { String(decoding: bytes, as: UTF8.self) }

  /// Every insertion is built with `\n` and converted here, once, to the file's own line
  /// ending.
  private func replaced(_ range: Range<Int>, with insertion: String) -> String {
    let normalized = newline == "\n" ? insertion : insertion.replacingOccurrences(of: "\n", with: newline)
    return String(decoding: bytes[..<range.lowerBound] + Array(normalized.utf8) + bytes[range.upperBound...], as: UTF8.self)
  }

  /// `\r\n` when the file already uses it, so an insertion does not mix line endings.
  private var newline: String {
    bytes.firstIndex(of: 0x0A).map { $0 > 0 && bytes[$0 - 1] == 0x0D } == true ? "\r\n" : "\n"
  }

  private var isMultiline: Bool { bytes.contains(0x0A) }

  /// One level of indentation as the file writes it, read off the top level's first key;
  /// two spaces, Claude Code's own, when the file does not say.
  private var unit: String {
    guard case .object(let members, let span) = root, let first = members.first,
      let indent = leadingIndent(at: first.keyStart)
    else { return "  " }
    let outer = lineIndent(at: span.start)
    guard indent.count > outer.count, indent.hasPrefix(outer) else { return "  " }
    return String(indent.dropFirst(outer.count))
  }

  /// The whitespace before `offset` on its line, or `nil` when anything else precedes it
  /// there, meaning the value does not start its own line.
  private func leadingIndent(at offset: Int) -> String? {
    var start = offset
    while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
    let prefix = bytes[start..<offset]
    guard prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
    return String(decoding: prefix, as: UTF8.self)
  }

  /// The whitespace that starts the line holding `offset`, whatever follows it.
  private func lineIndent(at offset: Int) -> String {
    var start = offset
    while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
    var end = start
    while end < offset, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
    return String(decoding: bytes[start..<end], as: UTF8.self)
  }

  // MARK: - Verification

  /// Parses both texts with `JSONSerialization` and requires two things of the edited one.
  ///
  /// It must equal the original with the one entry replaced, or the one group appended to
  /// `hooks.<event>`. And, checked without that model, every command string in the
  /// original that does not carry the hook's marker must still be there, as often as it
  /// was: a model of the edit that dropped the user's command beside Driverr's would pass
  /// the first check and fail this one.
  private static func verify(
    original: String?,
    edited: String,
    hook: AgentHook,
    replacing location: EntryLocation?
  ) throws(HookSettingsError) {
    var root: [String: Any] = [:]
    if let original {
      guard let parsed = (try? JSONSerialization.jsonObject(with: Data(original.utf8))) as? [String: Any]
      else { throw .verificationFailed }
      root = parsed
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var groups = hooks[hook.event] as? [Any] ?? []
    if let location {
      guard groups.indices.contains(location.group), var group = groups[location.group] as? [String: Any],
        var entries = group["hooks"] as? [Any], entries.indices.contains(location.entry)
      else { throw .verificationFailed }
      entries[location.entry] = entry(for: hook).foundationValue
      group["hooks"] = entries
      groups[location.group] = group
    } else {
      groups.append(group(for: hook).foundationValue)
    }
    hooks[hook.event] = groups
    let expected = root.merging(["hooks": hooks]) { $1 }
    guard let after = (try? JSONSerialization.jsonObject(with: Data(edited.utf8))) as? [String: Any],
      (after as NSDictionary).isEqual(to: expected)
    else { throw .verificationFailed }

    let theirs = { (value: Any) in commands(in: value).filter { !$0.contains(hook.marker) }.sorted() }
    guard theirs(root) == theirs(after), commands(in: after).contains(hook.command) else {
      throw .verificationFailed
    }
  }

  /// Every string under a `command` key, anywhere in the value.
  private static func commands(in value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
      return dictionary.flatMap { key, child in
        key == "command" ? (child as? String).map { [$0] } ?? commands(in: child) : commands(in: child)
      }
    }
    if let array = value as? [Any] { return array.flatMap(commands(in:)) }
    return []
  }
}
