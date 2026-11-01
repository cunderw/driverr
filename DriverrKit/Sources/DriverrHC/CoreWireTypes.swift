import Foundation

/// herdr-core's wire format, and the only place in Driverr that knows it.
///
/// These types are `internal`, so the compiler enforces the layering rule in `CLAUDE.md`.
///
/// As in `HerdrWireTypes`, fields Driverr does not use are absent. Within a generation the API
/// only grows, so an answer that gains a field must keep decoding.
struct CoreRequest<Params: Encodable & Sendable>: Encodable, Sendable {
  var jsonrpc = "2.0"
  let id: Int
  let method: String
  let params: Params
}

/// A call with every option at its default. `events.subscribe` with none is unfiltered.
struct CoreNoParams: Encodable, Sendable {}

/// `doc.get` on this core. There is no `CoreDocSetParams`, deliberately: Driverr reads the
/// app's document and never writes it.
struct CoreDocGetParams: Encodable, Sendable {
  let name: String
}

/// What `doc.get` answers. `value` is `null` for a document nobody has written.
struct CoreDocGetResult<Value: Decodable & Sendable>: Decodable, Sendable {
  let value: Value?
}

/// `file.read` of one whole file. `path` must be absolute: the core expands no `~`.
struct CoreFileReadParams: Encodable, Sendable {
  let path: String
}

struct CoreFileReadResult: Decodable, Sendable {
  let text: String
}

/// `terminal.read`, which opens no channel, so it is no viewer and takes no size.
///
/// `lines` is history above the screen, and stays 0: for history the core may scroll a
/// full-screen app (`how: "stitched"`).
struct CoreReadParams: Encodable, Sendable {
  let terminal: String
  var lines = 0
}

/// What `terminal.read` answers: logical lines with soft wraps joined, trimmed, and plain,
/// because core 0.1.15 keeps no styling in it. `how` says how history was found, and none is
/// asked for. `complete` is not read either: it is false after a core crash, and for a finished
/// terminal with no snapshot, whose text is empty and draws as a blank screen.
struct CoreReadResult: Decodable, Sendable {
  let text: String
}

/// Just enough of a reply to find the stream it opened.
struct CoreChannelResult: Decodable, Sendable {
  let channel: UInt32?
}

/// `terminal.attach`.
///
/// `display` is left out on purpose, and no FACTS frame is ever sent. With none, the core's
/// `set_display` keeps what the desk reported, and FACTS would count as activity and take the
/// size.
struct CoreAttachParams: Encodable, Sendable {
  let terminal: String
  var cols: Int
  var rows: Int
  /// Watch only. The core drops an observer's input and never takes its size.
  var observe = false
  /// Scrollback lines to paint first. The core skips them on the alternate screen.
  var history = 0
  /// Sets the size only once active again. `false` makes the attach itself active.
  var resumed = false
}

struct CoreAttachResult: Decodable, Sendable {
  /// The fields of `Terminal` that decide how to type into it.
  struct Attached: Decodable, Sendable {
    /// The key that submits, when the program's template says. `nil` is Enter.
    let submit: String?
    /// How long to wait between a paste and that key, when the template says.
    let pasteGapMilliseconds: Int?

    private enum CodingKeys: String, CodingKey {
      case submit
      case pasteGapMilliseconds = "paste_gap_ms"
    }
  }

  let channel: UInt32
  let terminal: Attached?
}

/// The JSON a core's CLOSE frame carries, or nothing, for the receipt of our own.
struct CoreCloseRecord: Decodable, Sendable {
  let reason: String?
  /// A kept terminal lost its program: `finished_ms` is there, and `null`. The record stays
  /// live, and a new shell is on the way.
  let isLoss: Bool

  private enum CodingKeys: String, CodingKey {
    case reason
    case finishedAt = "finished_ms"
  }

  init(from decoder: any Decoder) throws {
    let record = try decoder.container(keyedBy: CodingKeys.self)
    reason = try record.decodeIfPresent(String.self, forKey: .reason)
    isLoss = record.contains(.finishedAt) ? try record.decodeNil(forKey: .finishedAt) : false
  }
}

struct CoreHelloParams: Encodable, Sendable {
  let framed: Bool
  let generation: Int
}

/// Just enough of a channel 0 message to route it.
struct CoreEnvelope: Decodable, Sendable {
  let id: Int?
  let method: String?
}

struct CoreResponse<Result: Decodable & Sendable>: Decodable, Sendable {
  let id: Int?
  let result: Result?
  let error: CoreRPCError?
}

struct CoreRPCError: Decodable, Sendable {
  let message: String?
}

/// Only `generation` is required, so a core of a later generation still decodes far enough
/// to be refused by name rather than dismissed as not a core.
struct CoreHelloResult: Decodable, Equatable, Sendable {
  /// Who answered. `id` is permanent, reset only when the core's state is wiped.
  struct Core: Decodable, Equatable, Sendable {
    let id: String?
  }

  let generation: Int
  let version: String?
  let framed: Bool?
  let methods: [String]?
  let core: Core?
}

/// A machine this core added. `id` is that core's own `hello.core.id`, and it outlives a rename,
/// where `name`, the `box` in `box/t7`, is only this core's word for it.
struct CoreMachine: Decodable, Equatable, Sendable {
  let name: String
  let id: String
}

/// `machine.list`. A subscription says nothing about machines, in its reply or in an event.
struct CoreMachineListResult: Decodable, Sendable {
  let machines: [CoreMachine]
}

/// The terminals a tree is built from, and the machines they may be on. See
/// `CoreSnapshotMapper`.
struct CoreListResult: Decodable, Sendable {
  let terminals: [CoreTerminal]
  var machines: [CoreMachine]?
}

/// What `events.subscribe` answers, and what a `missed` line carries. **Finished terminals are
/// in both**, where `terminal.list` hides them.
struct CoreEventSnapshot: Decodable, Sendable {
  /// Events at or below this are already in `terminals`.
  let seq: UInt64
  let terminals: [CoreTerminal]
}

/// One line of an `events.subscribe` channel.
enum CoreEventLine: Decodable, Sendable {
  case event(CoreEvent)
  case missed(CoreEventSnapshot)
  case heartbeat
  /// A method this build does not know.
  case unknown

  private enum CodingKeys: String, CodingKey {
    case method, params
  }

  init(from decoder: any Decoder) throws {
    let line = try decoder.container(keyedBy: CodingKeys.self)
    switch try line.decode(String.self, forKey: .method) {
    case "event": self = .event(try line.decode(CoreEvent.self, forKey: .params))
    case "missed": self = .missed(try line.decode(CoreEventSnapshot.self, forKey: .params))
    case "heartbeat": self = .heartbeat
    default: self = .unknown
    }
  }
}

/// One fact change. The `apply` column of schema/README.md is `CoreEventState`.
struct CoreEvent: Decodable, Sendable {
  enum Change: Sendable {
    case created(CoreTerminal)
    case restarted(CoreTerminal)
    case lost
    case finished
    case removed
    case status(CoreTerminal.Status?)
    case title(String?)
    case labels([String: String]?)
    case size(rows: Int?)
    case foreground(CoreTerminal.Foreground?)
    /// `machine` is `nil` for this core.
    case document(name: String?, machine: String?)
    /// `turn` and `keep`, which draw nothing, and any type this build does not know.
    case ignored
  }

  private struct StatusData: Decodable {
    let status: CoreTerminal.Status?
  }

  private struct TitleData: Decodable {
    let title: String?
  }

  private struct LabelsData: Decodable {
    let labels: [String: String]?
  }

  private struct SizeData: Decodable {
    let rows: Int?
  }

  private struct DocumentData: Decodable {
    let name: String?
  }

  private enum CodingKeys: String, CodingKey {
    case seq, type, terminal, machine, data
  }

  let seq: UInt64
  /// The address, for all but `doc`.
  let terminal: String?
  let change: Change

  init(from decoder: any Decoder) throws {
    let event = try decoder.container(keyedBy: CodingKeys.self)
    seq = try event.decode(UInt64.self, forKey: .seq)
    terminal = try event.decodeIfPresent(String.self, forKey: .terminal)

    func data<Value: Decodable>(_ type: Value.Type) throws -> Value {
      try event.decode(type, forKey: .data)
    }
    switch try event.decode(String.self, forKey: .type) {
    case "created": change = .created(try data(CoreTerminal.self))
    case "restarted": change = .restarted(try data(CoreTerminal.self))
    case "lost": change = .lost
    case "finished": change = .finished
    case "removed": change = .removed
    case "status": change = .status(try data(StatusData.self).status)
    case "title": change = .title(try data(TitleData.self).title)
    case "labels": change = .labels(try data(LabelsData.self).labels)
    case "size": change = .size(rows: try data(SizeData.self).rows)
    case "foreground":
      change = .foreground(try event.decodeIfPresent(CoreTerminal.Foreground.self, forKey: .data))
    case "doc":
      change = .document(
        name: try data(DocumentData.self).name,
        machine: try event.decodeIfPresent(String.self, forKey: .machine))
    default: change = .ignored
    }
  }
}

struct CoreTerminal: Decodable, Sendable {
  struct Foreground: Decodable, Sendable {
    /// The foreground process group's leader. For Claude Code, the process itself.
    let pid: Int?
    let argv: [String]?
    /// As the OS has it, so not a program's name: Claude Code's is its version.
    let name: String?
    let cwd: String?
  }

  /// One OSC 7501 record, in the program's own words. The core translates nothing, so
  /// `state` can be a word this build does not know.
  ///
  /// `records`, a program's reports on other things, are not read: only the root status
  /// reaches a pane.
  struct Status: Decodable, Sendable {
    let state: String?
    /// The program's name for itself, such as `claude-code`.
    let app: String?
    /// `permission`, `question` or `auth`, when `state` is `blocked` and the program said.
    let kind: String?
  }

  /// `t7`, or `machine/t7` for a terminal on a machine this core added.
  let address: String
  let name: String?
  /// `live` or `finished`. A lost terminal is `live`, with a new shell on the way.
  let state: String?
  /// Often `""`, not absent.
  var title: String?
  let argv: [String]?
  let cwd: String?
  var rows: Int?
  /// What runs in it now. `null` once it has finished.
  var foreground: Foreground?
  /// `herdr.space`, `herdr.tab` and `where`, for a terminal the app opened.
  var labels: [String: String]?
  /// What its program last reported. `null` if it never did, which is what a plain shell is.
  var status: Status?

  var isLive: Bool { (state ?? "live") == "live" }

  /// The machine in `machine/t7`, or `nil` for a terminal on this core.
  var machine: String? {
    guard let slash = address.firstIndex(of: "/") else { return nil }
    return String(address[..<slash])
  }
}
