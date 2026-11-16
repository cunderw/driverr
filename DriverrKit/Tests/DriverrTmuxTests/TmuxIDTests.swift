import Testing

@testable import DriverrTmux

@Suite("TmuxID")
struct TmuxIDTests {
  @Test("a pane, a window and a session each keep their sigil behind the prefix")
  func prefixes() {
    #expect(TmuxID.pane("%3") == "tmux:%3")
    #expect(TmuxID.window("@2") == "tmux:@2")
    #expect(TmuxID.session("$1") == "tmux:$1")
  }

  @Test("the raw id and the kind come back out")
  func roundTrip() {
    #expect(TmuxID.raw(of: "tmux:%12") == "%12")
    #expect(TmuxID.kind(of: "tmux:%12") == .pane)
    #expect(TmuxID.kind(of: "tmux:@2") == .window)
    #expect(TmuxID.kind(of: "tmux:$1") == .session)
    #expect(TmuxID.rawPane(of: "tmux:%12") == "%12")
    #expect(TmuxID.rawPane(of: "tmux:@2") == nil, "a window is not a pane")
  }

  @Test(
    "anything that is not a sigil and digits is refused, so it cannot carry a flag",
    arguments: [
      "", "tmux:", "tmux:%", "tmux:%a", "tmux:%1 -x", "tmux:%1;x", "tmux:-t", "tmux:3", "w1:p2",
      "core:box/t7", "%3", "tmux:%1\n", "tmux:%٣",
    ])
  func refuses(id: String) {
    #expect(TmuxID.raw(of: id) == nil)
    #expect(TmuxID.kind(of: id) == nil)
  }

  @Test("the prefix tells tmux ids from herdr's and a core's")
  func isTmux() {
    #expect(TmuxID.isTmux("tmux:%1"))
    #expect(!TmuxID.isTmux("w1:p2"))
    #expect(!TmuxID.isTmux("core:tmux:%1"))
  }
}
