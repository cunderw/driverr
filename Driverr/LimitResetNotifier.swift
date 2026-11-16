import DriverrCore
import Foundation
import Observation

/// Turns one host's usage-limit stops into a notification at the reset time.
///
/// The rule is `DriverrCore.LimitResetReminder`. This part remembers what it scheduled for
/// each pane, checks permission, and holds the per-pane Continue opt-in. One per host, held
/// by `ConnectionModel`, so it outlives `disconnect()`, which drops the transcripts.
///
/// **The identifier, not this memory, is what keeps one stop to one card.** A request added
/// under an id the system already holds replaces it. The memory saves calls, and lets a
/// re-read of the same stop leave a Continue card alone.
///
/// Permission is never asked for here. A stop seen before permission exists is scheduled on
/// a later re-read, once the status is `.authorized`.
@MainActor
@Observable
final class LimitResetNotifier {
  /// What one landed page of a pane's own conversation says.
  struct Report: Equatable {
    let pane: Pane
    /// The session file's id. See `LimitResetReminder.notificationID(conversation:)`.
    let conversation: String
    let stop: AgentStop?
  }

  /// Where a pane's reminder stands.
  private struct Held {
    let pane: Pane
    let conversation: String
    let stop: AgentStop?
    /// The reminder for `stop`, kept after the reset passes, so the stop notice's opt-in can
    /// still name it and a later change can withdraw it.
    let reminder: LimitResetReminder?
    var phase: Phase

    /// The same conversation, stopped the same way with the same reset. Not `AgentStop`'s
    /// `==`, which also compares the record's text and time: two records of one limit are
    /// one card.
    func isSameLimit(as report: Report) -> Bool {
      conversation == report.conversation && stop?.kind == report.stop?.kind
        && stop?.resetsAt == report.stop?.resetsAt
    }
  }

  private enum Phase {
    /// Not scheduled yet, for want of permission. The next report tries again.
    case waiting
    case scheduling
    case done
  }

  @ObservationIgnored private let host: DriverrCore.Host
  @ObservationIgnored private let center: any NotificationScheduling
  @ObservationIgnored private let now: @MainActor () -> Date
  @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
  @ObservationIgnored private var held: [String: Held] = [:]

  /// The reminders that carry Continue, by notification id. Observed, because the stop
  /// notice's control draws it.
  private(set) var continuing: Set<String> = []

  init(
    host: DriverrCore.Host,
    center: any NotificationScheduling,
    now: @escaping @MainActor () -> Date = Date.init,
    timeZone: @escaping @MainActor () -> TimeZone = { .current }
  ) {
    self.host = host
    self.center = center
    self.now = now
    self.timeZone = timeZone
  }

  /// The scheduling in flight, so a test can wait for it.
  @ObservationIgnored private(set) var work: Task<Void, Never>?

  /// Folds in one landed page.
  ///
  /// - The same stop again does nothing, unless it is still waiting for permission.
  /// - A stop that is gone, or replaced by another, withdraws the old reminder. Only a page
  ///   does that. A disconnect drops the page and reports nothing, so it cancels nothing.
  /// - A reset that passes while the stop stands withdraws nothing, because the card has
  ///   just been delivered.
  /// - A pane's first page with no limit on it withdraws its conversation's reminder. A
  ///   previous process may have scheduled one, and the agent has gone on since.
  func report(_ report: Report) {
    let paneID = report.pane.id
    let was = held[paneID]
    let changed = was.map { !$0.isSameLimit(as: report) } ?? true
    if let was, !changed {
      guard was.phase == .waiting, let reminder = was.reminder, reminder.fireDate > now() else {
        return
      }
      held[paneID]?.phase = .scheduling
      start(reminder, pane: report.pane)
      return
    }

    let reminder = LimitResetReminder.schedule(
      for: report.stop, conversation: report.conversation, asOf: now(), timeZone: timeZone())
    var withdrawals: [String] = []
    if let old = was?.reminder {
      // A new stop starts with Continue off, even in the same conversation.
      continuing.remove(old.id)
      if old.id != reminder?.id { withdrawals.append(old.id) }
    } else if was == nil, report.stop?.kind != .rateLimit {
      withdrawals.append(LimitResetReminder.notificationID(conversation: report.conversation))
    }
    held[paneID] = Held(
      pane: report.pane, conversation: report.conversation, stop: report.stop,
      reminder: reminder, phase: reminder == nil ? .done : .scheduling)

    if !withdrawals.isEmpty {
      // On the same chain as the schedules, so a withdrawal cannot land after a newer card.
      let center = center
      let previous = work
      work = Task {
        await previous?.value
        await center.withdraw(ids: withdrawals)
      }
    }
    if let reminder { start(reminder, pane: report.pane) }
  }

  /// Whether the pane's reminder carries Continue.
  func continues(paneID: String) -> Bool {
    guard let id = held[paneID]?.reminder?.id else { return false }
    return continuing.contains(id)
  }

  /// Turns the pane's Continue on or off, and schedules its reminder again with or without
  /// the action. Does nothing once the reset has passed.
  func setContinues(_ on: Bool, paneID: String) {
    guard let held = held[paneID], let reminder = held.reminder, reminder.fireDate > now() else {
      return
    }
    if on { continuing.insert(reminder.id) } else { continuing.remove(reminder.id) }
    let notification = timed(reminder, pane: held.pane, continues: on)
    let center = center
    let previous = work
    work = Task {
      await previous?.value
      guard await center.authorizationStatus() == .authorized else { return }
      await center.schedule(notification)
    }
  }

  /// Schedules `reminder`, unless the system already holds it for the same instant. That
  /// request is kept, Continue and all: a relaunch, or a second host reading the same
  /// conversation, must not replace it with a plain one.
  private func start(_ reminder: LimitResetReminder, pane: Pane) {
    let center = center
    let previous = work
    work = Task { [weak self] in
      await previous?.value
      guard await center.authorizationStatus() == .authorized else {
        self?.settle(pane.id, reminder, as: .waiting)
        return
      }
      if let pending = await center.pendingNotification(id: reminder.id),
        pending.fireDate == reminder.fireDate
      {
        if pending.categoryID == LimitResetReminder.continueCategoryID {
          self?.adoptContinue(reminder, paneID: pane.id)
        }
      } else if let notification = self?.timedIfCurrent(reminder, paneID: pane.id) {
        await center.schedule(notification)
      }
      self?.settle(pane.id, reminder, as: .done)
    }
  }

  private func settle(_ paneID: String, _ reminder: LimitResetReminder, as phase: Phase) {
    guard held[paneID]?.reminder == reminder else { return }
    held[paneID]?.phase = phase
  }

  private func adoptContinue(_ reminder: LimitResetReminder, paneID: String) {
    guard held[paneID]?.reminder == reminder else { return }
    continuing.insert(reminder.id)
  }

  /// The card for `reminder`, or `nil` if a newer page replaced it during the awaits.
  private func timedIfCurrent(_ reminder: LimitResetReminder, paneID: String) -> TimedNotification? {
    guard let held = held[paneID], held.reminder == reminder else { return nil }
    return timed(reminder, pane: held.pane, continues: continuing.contains(reminder.id))
  }

  private func timed(
    _ reminder: LimitResetReminder, pane: Pane, continues: Bool
  ) -> TimedNotification {
    TimedNotification(
      id: reminder.id,
      title: LimitResetReminder.title,
      body: LimitResetReminder.body(paneTitle: pane.title, hostName: host.name),
      // The keys a tap reads; see `NotificationTapRouter`.
      userInfo: [
        NotificationTapRouter.hostIDKey: host.id.uuidString,
        NotificationTapRouter.paneIDKey: pane.id,
      ],
      trigger: reminder.trigger,
      categoryID: continues ? LimitResetReminder.continueCategoryID : nil)
  }
}
