import Testing

@testable import Driverr

/// When Settings shows "Notifications are off". The claim is visibility, not geometry, so it is
/// a value test; `SettingsUITests` covers the rendering.
@Suite("NotificationsOffNotice")
struct NotificationsOffNoticeTests {
  @Test("a denial is the only status that shows the row")
  func onlyADenialShowsTheRow() {
    #expect(NotificationsOffNotice.isVisible(status: .denied, isStoreTour: false))
    #expect(!NotificationsOffNotice.isVisible(status: .authorized, isStoreTour: false))
    #expect(!NotificationsOffNotice.isVisible(status: .notDetermined, isStoreTour: false))
  }

  /// Before the first read comes back. A row that appears a beat after the screen is worse than
  /// none, and a fresh install is almost always `.notDetermined`.
  @Test("an unread status shows nothing")
  func anUnreadStatusShowsNothing() {
    #expect(!NotificationsOffNotice.isVisible(status: nil, isStoreTour: false))
  }

  /// The App Store screenshot run gets the ephemeral notification centre, which reports
  /// `.denied`. Without this, the Settings screenshot would carry a "Notifications are off" row.
  @Test("the store tour never shows it")
  func theStoreTourNeverShowsIt() {
    #expect(!NotificationsOffNotice.isVisible(status: .denied, isStoreTour: true))
  }
}
