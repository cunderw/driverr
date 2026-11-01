import Foundation

/// The terminals a subscription has been told about, with every event applied.
///
/// schema/README.md's table, as a value, so each row is a test with no stream behind it. What a
/// change should cost the app is said here too, because each row knows and nothing later does.
///
/// **Only live terminals are held.** A subscribe reply and a `missed` line carry finished ones,
/// which `terminal.list` hides. Anything said about a terminal not held is passed over, so a
/// `finished` needs no record of what it finished.
struct CoreEventState {
  /// What the rest of the app must do about a line that has been applied.
  struct Effect: Equatable, Sendable {
    var signal = CoreChangeUrgency.none
    /// Terminals whose Claude may have moved to another session. See `CoreSessionFiles`.
    var sessionReads: Set<String> = []
    /// Terminals carry nothing about the document, so it has to be read again.
    var readsDocument = false
  }

  private(set) var seq: UInt64
  private(set) var terminals: [CoreTerminal]

  init(_ snapshot: CoreEventSnapshot) {
    seq = snapshot.seq
    terminals = snapshot.terminals.filter(\.isLive)
  }

  mutating func apply(_ line: CoreEventLine) -> Effect {
    switch line {
    case .event(let event):
      return apply(event)
    case .missed(let snapshot):
      self = CoreEventState(snapshot)
      return Effect(
        signal: .prompt, sessionReads: Set(terminals.map(\.address)), readsDocument: true)
    case .heartbeat, .unknown:
      return Effect()
    }
  }

  /// `seq` restarts with each core process, so this holds only within one subscription.
  private mutating func apply(_ event: CoreEvent) -> Effect {
    guard event.seq > seq else { return Effect() }
    seq = event.seq

    switch event.change {
    case .created(let record), .restarted(let record):
      return place(record)
    case .document(let name, let machine):
      // Only this core's. A machine it added has its own document, which orders nothing here.
      return Effect(readsDocument: name == CoreAppDocument.name && machine == nil)
    case .ignored:
      return Effect()
    case let change:
      guard let address = event.terminal,
        let index = terminals.firstIndex(where: { $0.address == address })
      else { return Effect() }
      return apply(change, at: index)
    }
  }

  private mutating func apply(_ change: CoreEvent.Change, at index: Int) -> Effect {
    let address = terminals[index].address
    switch change {
    case .lost:
      // A kept terminal stays, waiting for its new shell.
      terminals[index].foreground = nil
      return Effect(signal: .prompt)
    case .finished, .removed:
      terminals.remove(at: index)
      // No file to read, but its remembered id goes with the read.
      return Effect(signal: .prompt, sessionReads: [address])
    case .status(let status):
      terminals[index].status = status
      // `/clear` and `/resume` raise nothing else. Measured on Claude Code 2.1.316: the new id
      // is in the record by the time the status that follows it arrives.
      return Effect(signal: .prompt, sessionReads: [address])
    case .labels(let labels):
      terminals[index].labels = labels
      return Effect(signal: .prompt)
    case .foreground(let foreground):
      let was = terminals[index].foreground
      terminals[index].foreground = foreground
      guard foreground?.pid != was?.pid else {
        return Effect(signal: foreground?.cwd == was?.cwd ? .paced : .prompt)
      }
      return Effect(signal: .prompt, sessionReads: [address])
    case .title(let title):
      terminals[index].title = title
      return Effect(signal: .paced)
    case .size(let rows):
      terminals[index].rows = rows
      return Effect(signal: .paced)
    case .created, .restarted, .document, .ignored:
      return Effect()
    }
  }

  /// A record arrives whole, for a new terminal or one that came back. A machine's line coming
  /// back says `created` of terminals already held, and of ones that finished meanwhile.
  private mutating func place(_ record: CoreTerminal) -> Effect {
    let index = terminals.firstIndex { $0.address == record.address }
    switch (index, record.isLive) {
    case (let index?, true): terminals[index] = record
    case (nil, true): terminals.append(record)
    case (let index?, false): terminals.remove(at: index)
    case (nil, false): return Effect()
    }
    return Effect(signal: .prompt, sessionReads: [record.address])
  }
}
