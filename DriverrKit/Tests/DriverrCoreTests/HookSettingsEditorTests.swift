import Foundation
import Testing

@testable import DriverrCore

/// The settings merge: one group added to `hooks.PreToolUse`, every other byte kept.
@Suite("Hook settings editor")
struct HookSettingsEditorTests {
  private let claude = AgentIntegration.claudeCode
  private let hook = AgentHook.claudeAskUserQuestion

  private func install(_ text: String?) throws -> String? {
    try claude.installing(into: text)
  }

  @Test("a missing file is created holding only the hook")
  func aMissingFileIsCreated() throws {
    let expected = """
      {
        "hooks": {
          "PreToolUse": [
      \(HookSettingsFixture.groupAtSix)
          ]
        }
      }

      """
    #expect(try install(nil) == expected)
  }

  @Test("an empty object gains hooks, PreToolUse and the group")
  func anEmptyObjectGainsTheKeys() throws {
    let expected = """
      {
        "hooks": {
          "PreToolUse": [
      \(HookSettingsFixture.groupAtSix)
          ]
        }
      }

      """
    #expect(try install("{}\n") == expected)
  }

  @Test("a file with no hooks key keeps its keys and gains hooks last")
  func noHooksKey() throws {
    let original = """
      {
        "model": "example-model",
        "theme": "dark"
      }

      """
    let expected = """
      {
        "model": "example-model",
        "theme": "dark",
        "hooks": {
          "PreToolUse": [
      \(HookSettingsFixture.groupAtSix)
          ]
        }
      }

      """
    #expect(try install(original) == expected)
  }

  @Test("hooks with other events gain a PreToolUse key after them")
  func otherEvents() throws {
    let original = """
      {
        "hooks": {
          "Stop": [
            {
              "matcher": "",
              "hooks": [
                {
                  "type": "command",
                  "command": "/opt/example/stop.sh"
                }
              ]
            }
          ]
        }
      }

      """
    let expected = """
      {
        "hooks": {
          "Stop": [
            {
              "matcher": "",
              "hooks": [
                {
                  "type": "command",
                  "command": "/opt/example/stop.sh"
                }
              ]
            }
          ],
          "PreToolUse": [
      \(HookSettingsFixture.groupAtSix)
          ]
        }
      }

      """
    #expect(try install(original) == expected)
  }

  @Test("an empty PreToolUse array gets the group on its own lines")
  func emptyPreToolUse() throws {
    let original = """
      {
        "hooks": {
          "PreToolUse": []
        }
      }

      """
    let expected = """
      {
        "hooks": {
          "PreToolUse": [
      \(HookSettingsFixture.groupAtSix)
          ]
        }
      }

      """
    #expect(try install(original) == expected)
  }

  /// Other `PreToolUse` matchers, several other events, and keys on both sides of `hooks`.
  /// The result is head, new group and tail, byte for byte.
  @Test("the real shape keeps every byte and appends after the other PreToolUse matchers")
  func realShapeAppendsInPlace() throws {
    let expected =
      HookSettingsFixture.realShapeHead + ",\n" + HookSettingsFixture.groupAtSix + HookSettingsFixture.realShapeTail
    #expect(try install(HookSettingsFixture.realShape) == expected)
  }

  @Test("the top-level key order survives the edit")
  func topLevelOrderIsPreserved() throws {
    let edited = try #require(try install(HookSettingsFixture.realShape))
    #expect(topLevelKeys(edited) == topLevelKeys(HookSettingsFixture.realShape))
    #expect(
      topLevelKeys(edited) == [
        "model", "env", "permissions", "attribution", "hooks", "effortLevel", "enabledPlugins",
        "statusLine", "modelSettings", "extraKnownMarketplaces",
      ]
    )
  }

  @Test("installing twice changes nothing the second time")
  func idempotent() throws {
    let once = try #require(try install(HookSettingsFixture.realShape))
    #expect(try install(once) == nil)
    #expect(try claude.status(in: once) == .installed)
    #expect(try claude.hookStates(in: once) == [hook.id: .installed(version: 1)])
  }

  @Test("status reads absent before and installed after, and a missing file is absent")
  func statusBeforeAndAfter() throws {
    #expect(try claude.status(in: nil) == .absent)
    #expect(try claude.status(in: HookSettingsFixture.realShape) == .absent)
    #expect(try claude.hookStates(in: HookSettingsFixture.realShape) == [hook.id: .absent])
  }

  @Test("an outdated Driverr group is replaced where it stands, between the user's groups")
  func outdatedIsReplacedInPlace() throws {
    let before = """
      {
        "hooks": {
          "PreToolUse": [
            {
              "matcher": "Bash",
              "hooks": [
                {
                  "type": "command",
                  "command": "/opt/example/one.sh"
                }
              ]
            },

      """
    let after = """
      ,
            {
              "matcher": "Edit",
              "hooks": [
                {
                  "type": "command",
                  "command": "/opt/example/two.sh"
                }
              ]
            }
          ]
        }
      }

      """
    let original = before + HookSettingsFixture.oldGroupAtSix + after
    #expect(try claude.hookStates(in: original) == [hook.id: .outdated(version: 0)])
    #expect(try claude.status(in: original) == .outdated)
    #expect(try install(original) == before + HookSettingsFixture.groupAtSix + after)
  }

  /// Only the marked entry is Driverr's, so only it changes.
  @Test("an outdated entry beside the user's own command is replaced alone")
  func outdatedEntryBesideTheUsersCommand() throws {
    let before = """
      {
        "hooks": {
          "PreToolUse": [
            {
              "matcher": "AskUserQuestion",
              "hooks": [
                {
                  "type": "command",
                  "command": "/opt/example/mine.sh",
                  "timeout": 5
                },

      """
    let after = """

              ]
            }
          ]
        }
      }

      """
    let old = """
                {
                  "type": "command",
                  "command": "true # driverr:claude.ask-user-question:v0"
                }
      """
    let new = """
                {
                  "type": "command",
                  "command": "cat >/dev/null # driverr:claude.ask-user-question:v1"
                }
      """
    let original = before + old + after
    #expect(try claude.hookStates(in: original) == [hook.id: .outdated(version: 0)])
    let edited = try #require(try install(original))
    #expect(edited == before + new + after)
    #expect(edited.contains("/opt/example/mine.sh"))
  }

  /// The install must not turn the user's `Bash` group into Driverr's.
  @Test("a Driverr entry under another matcher is refused, not rewritten")
  func markerUnderAnotherMatcher() {
    let original = """
      {
        "hooks": {
          "PreToolUse": [
            {
              "matcher": "Bash",
              "hooks": [
                { "type": "command", "command": "/x/guard.sh" },
                { "type": "command", "command": "true # driverr:claude.ask-user-question:v0" }
              ]
            }
          ]
        }
      }

      """
    let error = HookSettingsError.markerUnderAnotherMatcher(path: "hooks.PreToolUse[0]")
    #expect(throws: error) { try claude.installing(into: original) }
    #expect(throws: error) { try claude.status(in: original) }
  }

  @Test("a repeated key Driverr edits under is its own error")
  func duplicateKeys() {
    #expect(throws: HookSettingsError.duplicateKey(path: "hooks")) {
      try claude.installing(into: #"{"hooks": {}, "hooks": {}}"#)
    }
    #expect(throws: HookSettingsError.duplicateKey(path: "hooks.PreToolUse")) {
      try claude.installing(into: #"{"hooks": {"PreToolUse": [], "PreToolUse": []}}"#)
    }
  }

  @Test("a high surrogate followed by an escape that is not a low one reads without a crash")
  func unpairedSurrogate() throws {
    let node = try JSONSpanParser.parse(Array(#"["\ud83dA", "😀", "\ud83d"]"#.utf8))
    guard case .array(let elements, _) = node else {
      Issue.record("not an array")
      return
    }
    let strings = elements.compactMap { element -> String? in
      if case .string(let text, _) = element { return text }
      return nil
    }
    #expect(strings == ["\u{FFFD}A", "😀", "\u{FFFD}"])
  }

  @Test("a newer Driverr group counts as installed and is left alone")
  func newerIsLeftAlone() throws {
    let newer = HookSettingsFixture.groupAtSix.replacingOccurrences(
      of: "ask-user-question:v1", with: "ask-user-question:v2"
    )
    let original = "{\n  \"hooks\": {\n    \"PreToolUse\": [\n" + newer + "\n    ]\n  }\n}\n"
    #expect(try claude.hookStates(in: original) == [hook.id: .installed(version: 2)])
    #expect(try install(original) == nil)
  }

  @Test("another hook's marker does not count as this one")
  func anotherMarkerIsNotThisHook() throws {
    let other = HookSettingsFixture.groupAtSix.replacingOccurrences(
      of: "driverr:claude.ask-user-question:v1", with: "driverr:claude.ask-user-question-extra:v1"
    )
    let original = "{\n  \"hooks\": {\n    \"PreToolUse\": [\n" + other + "\n    ]\n  }\n}\n"
    #expect(try claude.hookStates(in: original) == [hook.id: .absent])
  }

  @Test("invalid JSON is reported and never replaced", arguments: ["", "   \n", "{", "{\"a\": 1,}", "{'a': 1}", "nul"])
  func invalidJSON(text: String) {
    #expect(throws: HookSettingsError.invalidJSON) { try claude.installing(into: text) }
    #expect(throws: HookSettingsError.invalidJSON) { try claude.status(in: text) }
  }

  @Test("a value of the wrong kind is reported by its path")
  func unexpectedShapes() {
    #expect(throws: HookSettingsError.unexpectedShape(path: "the top level")) {
      try claude.installing(into: "[]")
    }
    #expect(throws: HookSettingsError.unexpectedShape(path: "hooks")) {
      try claude.installing(into: "{\"hooks\": []}")
    }
    #expect(throws: HookSettingsError.unexpectedShape(path: "hooks.PreToolUse")) {
      try claude.installing(into: "{\"hooks\": {\"PreToolUse\": {}}}")
    }
  }

  @Test("a file written on one line stays on one line")
  func compactFile() throws {
    let expected =
      #"{"a":1,"hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"cat >/dev/null # driverr:claude.ask-user-question:v1"}]}]}}"#
    #expect(try install(#"{"a":1}"#) == expected)
  }

  @Test("a file with CRLF line endings keeps them")
  func crlfFile() throws {
    let original = "{\r\n  \"model\": \"x\"\r\n}\r\n"
    let edited = try #require(try install(original))
    #expect(edited.hasPrefix("{\r\n  \"model\": \"x\",\r\n  \"hooks\": {\r\n"))
    #expect(!edited.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    #expect(try claude.status(in: edited) == .installed)
  }

  @Test("a file indented with tabs is extended with tabs")
  func tabIndentedFile() throws {
    let original = "{\n\t\"model\": \"x\"\n}\n"
    let edited = try #require(try install(original))
    #expect(edited.hasPrefix("{\n\t\"model\": \"x\",\n\t\"hooks\": {\n\t\t\"PreToolUse\": [\n\t\t\t{\n\t\t\t\t\"matcher\""))
  }

  @Test("escapes and non-ASCII text elsewhere in the file are kept as written")
  func escapesAreKept() throws {
    let original = "{\n  \"note\": \"caf\\u00e9 \\\"q\\\" \\ud83d\\ude00 ✓\",\n  \"path\": \"a\\/b\"\n}\n"
    let edited = try #require(try install(original))
    #expect(edited.hasPrefix("{\n  \"note\": \"caf\\u00e9 \\\"q\\\" \\ud83d\\ude00 ✓\",\n  \"path\": \"a\\/b\",\n"))
  }

  private func topLevelKeys(_ text: String) -> [String] {
    guard case .object(let members, _)? = try? JSONSpanParser.parse(Array(text.utf8)) else { return [] }
    return members.map(\.key)
  }
}
