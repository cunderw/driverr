import Testing

@testable import DriverrCore

@Suite("RenameTarget")
struct RenameTargetTests {
  @Test("a target carries herdr's own id, which is the command's first argument")
  func carriesTheID() {
    #expect(RenameTarget.workspace(id: "w1").id == "w1")
    #expect(RenameTarget.tab(id: "w1:t2").id == "w1:t2")
  }

  @Test("a workspace and a tab with the same id are different targets")
  func kindIsPartOfTheValue() {
    // herdr's ids share a shape across kinds, so comparing ids alone would record a tab rename
    // as a workspace one.
    #expect(RenameTarget.workspace(id: "w1") != RenameTarget.tab(id: "w1"))
  }
}

@Suite("RenameLabel")
struct RenameLabelTests {
  @Test(
    "a label with nothing in it is refused before it reaches herdr",
    arguments: ["", " ", "\t", "\n", "   \n  "]
  )
  func refusesEmptyLabels(raw: String) {
    // `shellQuoted("")` is `''`, a real empty argument, so the workspace would be named nothing.
    #expect(RenameLabel.sanitised(raw) == nil)
  }

  @Test("the ends are trimmed and the middle is left alone")
  func trimsOnlyTheEnds() {
    #expect(RenameLabel.sanitised("  build logs  ") == "build logs")
    #expect(RenameLabel.sanitised("build  logs") == "build  logs")
  }

  @Test("an unchanged label is not worth sending")
  func unchangedIsACancel() {
    #expect(RenameLabel.isWorthSending("driverr", whenCurrentLabelIs: "driverr") == false)
    #expect(RenameLabel.isWorthSending("  driverr  ", whenCurrentLabelIs: "driverr") == false)
    #expect(RenameLabel.isWorthSending("", whenCurrentLabelIs: "driverr") == false)
    #expect(RenameLabel.isWorthSending("ship it", whenCurrentLabelIs: "driverr"))
  }
}
