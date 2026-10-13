import Testing

@testable import DriverrCore

/// The shortcut catalogue. The hold-⌘ overlay and the iPadOS menu bar list commands by
/// title and are the only shortcut reference, so every title must exist and be unique.
@Suite("KeyCommand")
struct KeyCommandTests {
  @Test("the catalogue holds every title of the eighteen bindings")
  func holdsEveryBinding() {
    // Add Host, Settings, nine places, next, previous, the surface key's two titles, ⌘W's six
    // titles, Escape and Send. The two ⌘, buttons are one command.
    #expect(KeyCommand.all.count == 23)
    #expect(Set(KeyCommand.all).count == KeyCommand.all.count)
  }

  @Test("every command has a title")
  func everyCommandHasATitle() {
    for command in KeyCommand.all {
      #expect(!command.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(command)")
    }
  }

  @Test("no two commands share a title")
  func titlesAreUnique() {
    let titles = KeyCommand.all.map(\.title)
    #expect(Set(titles).count == titles.count, "\(titles)")
  }

  /// Nothing decides which of two bindings on one key wins.
  @Test("no two commands share a key, except within a group that is never live at once")
  func keysAreUnique() {
    let commands = KeyCommand.all
    for (i, a) in commands.enumerated() {
      for b in commands[(i + 1)...] where a.key == b.key && a.modifiers == b.modifiers {
        #expect(
          KeyCommand.exclusiveGroups.contains { $0.contains(a) && $0.contains(b) },
          "\(a) and \(b) share a key"
        )
      }
    }
  }

  /// The order matches Escape's.
  @Test("⌘W closes what is up before it leaves the pane")
  func commandWClosesTheFrontmostThing() {
    func commandW(sheet: Bool, settings: Bool, photos: Bool) -> KeyCommand {
      KeyCommand.commandW(
        isShowingPaneSheet: sheet, isShowingSettings: settings, isShowingPhotoPicker: photos
      )
    }
    #expect(commandW(sheet: false, settings: false, photos: false) == .leavePane)
    #expect(commandW(sheet: true, settings: false, photos: false) == .closeSwitcher)
    #expect(commandW(sheet: false, settings: true, photos: false) == .closeSettings)
    #expect(commandW(sheet: false, settings: false, photos: true) == .closePhotos)
    #expect(commandW(sheet: true, settings: true, photos: true) == .closeSwitcher)
    #expect(commandW(sheet: false, settings: true, photos: true) == .closeSettings)
  }

  @Test("every ⌘W title is in one exclusive group")
  func commandWTitlesShareAGroup() {
    let group: Set<KeyCommand> = [
      .leavePane, .closeSwitcher, .closeSettings, .closePhotos, .leaveHost, .close,
    ]
    #expect(KeyCommand.exclusiveGroups.contains(group))
  }

  /// Close is a no-op that keeps the key from iPadOS.
  @Test("⌘W with no scene leaves the host, or is Close with none selected")
  func commandWWithoutAScene() {
    #expect(KeyCommand.commandWWithoutAScene(hasSelectedHost: true) == .leaveHost)
    #expect(KeyCommand.commandWWithoutAScene(hasSelectedHost: false) == .close)
    #expect(KeyCommand.leaveHost.title == "Leave Host")
    #expect(KeyCommand.close.title == "Close")
    for command in [KeyCommand.leaveHost, .close] {
      #expect(command.key == .character("w"))
      #expect(command.modifiers == .command)
    }
  }

  @Test("the places are ⌘1 to ⌘9, one-based like the keys")
  func placesMatchTheirDigits() {
    for index in 1...9 {
      let command = KeyCommand.goToPlace(index)
      #expect(command.key == .character(Character("\(index)")))
      #expect(command.modifiers == .command)
      #expect(command.title == "Go to Pane \(index)")
    }
  }

  /// Escape falls through to the far side, so no modifier may change what it sends.
  @Test("Escape is bound bare")
  func escapeIsBare() {
    #expect(KeyCommand.dismiss.key == .escape)
    #expect(KeyCommand.dismiss.modifiers.isEmpty)
  }
}
