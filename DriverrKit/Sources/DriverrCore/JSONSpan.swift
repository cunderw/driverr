import Foundation

/// A JSON document read for where each value sits, not only for what it holds.
///
/// `JSONSerialization` forgets key order and spacing, so writing its result back would
/// reorder the user's settings file. Driverr's edit must return the file as it was plus one
/// entry, so the editor finds the byte range of the array it appends to and splices there.
///
/// This parser does not judge validity. `ClaudeSettingsEditor` runs `JSONSerialization` over
/// the input first and over the edited text afterwards, so a disagreement fails the check
/// and nothing is written.
struct JSONSpan: Equatable {
  /// Byte offsets into the UTF-8 text, `start..<end`, covering the value exactly: the
  /// opening brace to the closing one, the opening quote to the closing one.
  let start: Int
  let end: Int
}

indirect enum JSONNode: Equatable {
  struct Member: Equatable {
    let key: String
    /// The key's opening quote, which is where a line's indentation is read from.
    let keyStart: Int
    let value: JSONNode
  }

  case object([Member], JSONSpan)
  case array([JSONNode], JSONSpan)
  case string(String, JSONSpan)
  /// A number, `true`, `false` or `null`. The editor never reads one, so it keeps no value.
  case scalar(JSONSpan)

  var span: JSONSpan {
    switch self {
    case .object(_, let span), .array(_, let span), .string(_, let span), .scalar(let span):
      return span
    }
  }

  /// The first member with this key, which is the one `JSONSerialization` keeps when a key
  /// repeats. The editor refuses a repeated key at the two levels it edits under
  /// (`HookSettingsError.duplicateKey`), and the check after an edit catches any other
  /// disagreement.
  func member(_ key: String) -> Member? {
    guard case .object(let members, _) = self else { return nil }
    return members.first { $0.key == key }
  }
}

struct JSONSpanParser {
  struct Failure: Error {}

  let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// Parses one whole document. Leading and trailing whitespace is allowed, as is a UTF-8
  /// byte-order mark at the very start; anything else after the value is a failure.
  static func parse(_ bytes: [UInt8]) throws(Failure) -> JSONNode {
    var parser = JSONSpanParser(bytes: bytes)
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
    parser.skipWhitespace()
    let node = try parser.value()
    parser.skipWhitespace()
    guard parser.index == bytes.count else { throw Failure() }
    return node
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }

  private mutating func expect(_ byte: UInt8) throws(Failure) {
    guard index < bytes.count, bytes[index] == byte else { throw Failure() }
    index += 1
  }

  private mutating func value() throws(Failure) -> JSONNode {
    guard index < bytes.count else { throw Failure() }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try object()
    case UInt8(ascii: "["): return try array()
    case UInt8(ascii: "\""):
      let start = index
      let text = try string()
      return .string(text, JSONSpan(start: start, end: index))
    default:
      return try scalar()
    }
  }

  private mutating func object() throws(Failure) -> JSONNode {
    let start = index
    try expect(UInt8(ascii: "{"))
    var members: [JSONNode.Member] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      index += 1
      return .object(members, JSONSpan(start: start, end: index))
    }
    while true {
      skipWhitespace()
      let keyStart = index
      let key = try string()
      skipWhitespace()
      try expect(UInt8(ascii: ":"))
      skipWhitespace()
      members.append(JSONNode.Member(key: key, keyStart: keyStart, value: try value()))
      skipWhitespace()
      guard index < bytes.count else { throw Failure() }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
        continue
      }
      try expect(UInt8(ascii: "}"))
      return .object(members, JSONSpan(start: start, end: index))
    }
  }

  private mutating func array() throws(Failure) -> JSONNode {
    let start = index
    try expect(UInt8(ascii: "["))
    var elements: [JSONNode] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      index += 1
      return .array(elements, JSONSpan(start: start, end: index))
    }
    while true {
      skipWhitespace()
      elements.append(try value())
      skipWhitespace()
      guard index < bytes.count else { throw Failure() }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
        continue
      }
      try expect(UInt8(ascii: "]"))
      return .array(elements, JSONSpan(start: start, end: index))
    }
  }

  /// A number or a literal. Only the extent matters here: `JSONSerialization` has already
  /// judged the text, so this consumes the characters a number or literal can hold.
  private mutating func scalar() throws(Failure) -> JSONNode {
    let start = index
    let allowed = Set("-+.0123456789eEtrufalsn".utf8)
    while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
    guard index > start else { throw Failure() }
    return .scalar(JSONSpan(start: start, end: index))
  }

  /// Decodes a string, escapes included, and leaves `index` after the closing quote.
  private mutating func string() throws(Failure) -> String {
    try expect(UInt8(ascii: "\""))
    var scalars = String.UnicodeScalarView()
    var run: [UInt8] = []
    func flush() {
      scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
      run.removeAll()
    }
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      switch byte {
      case UInt8(ascii: "\""):
        flush()
        return String(scalars)
      case UInt8(ascii: "\\"):
        flush()
        guard index < bytes.count else { throw Failure() }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"):
          let unit = try hex4()
          // A high surrogate combines only with a low one that follows it. Anything else,
          // a lone half or a high followed by a `\\u` that is not low, reads as U+FFFD, and
          // the second `\\u` is left to be read as its own escape.
          if (0xD800..<0xDC00).contains(unit), index + 5 < bytes.count,
            bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"),
            let low = UInt32(String(decoding: bytes[(index + 2)..<(index + 6)], as: UTF8.self), radix: 16),
            (0xDC00..<0xE000).contains(low)
          {
            index += 6
            scalars.append(Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}")
          } else {
            scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
          }
        default:
          throw Failure()
        }
      default:
        guard byte >= 0x20 else { throw Failure() }
        run.append(byte)
      }
    }
    throw Failure()
  }

  private mutating func hex4() throws(Failure) -> UInt32 {
    guard index + 4 <= bytes.count,
      let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
    else { throw Failure() }
    index += 4
    return value
  }
}

/// A JSON value Driverr writes, rendered the way Claude Code writes its own settings: two
/// spaces a level (or whatever the file already uses), `"key": value`, keys in the order
/// given.
enum JSONFragment {
  case string(String)
  case array([JSONFragment])
  case object([(String, JSONFragment)])

  /// `indent` is the indentation of the line the value starts on, and `unit` is one level.
  /// `nil` renders the value on one line with no spaces, for a file written that way.
  func rendered(indent: String?, unit: String) -> String {
    switch self {
    case .string(let value):
      return Self.quoted(value)
    case .array(let elements):
      guard !elements.isEmpty else { return "[]" }
      guard let indent else {
        return "[" + elements.map { $0.rendered(indent: nil, unit: unit) }.joined(separator: ",") + "]"
      }
      let inner = indent + unit
      let lines = elements.map { inner + $0.rendered(indent: inner, unit: unit) }
      return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
    case .object(let members):
      guard !members.isEmpty else { return "{}" }
      guard let indent else {
        return "{"
          + members.map { Self.quoted($0.0) + ":" + $0.1.rendered(indent: nil, unit: unit) }
          .joined(separator: ",") + "}"
      }
      let inner = indent + unit
      let lines = members.map { inner + Self.quoted($0.0) + ": " + $0.1.rendered(indent: inner, unit: unit) }
      return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    }
  }

  /// The same value as `JSONSerialization` would return it, for the check after an edit.
  var foundationValue: Any {
    switch self {
    case .string(let value): return value
    case .array(let elements): return elements.map(\.foundationValue)
    case .object(let members):
      var dictionary: [String: Any] = [:]
      for (key, value) in members { dictionary[key] = value.foundationValue }
      return dictionary
    }
  }

  static func quoted(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
