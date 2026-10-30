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

/// `terminal.list` with every option at its default: live terminals, unfiltered.
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
  let generation: Int
  let version: String?
  let framed: Bool?
  let methods: [String]?
}

struct CoreListResult: Decodable, Sendable {
  let terminals: [CoreTerminal]
}

struct CoreTerminal: Decodable, Sendable {
  struct Foreground: Decodable, Sendable {
    let argv: [String]?
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
  /// Often `""`, not absent.
  let title: String?
  let argv: [String]?
  let cwd: String?
  let rows: Int?
  /// What runs in it now. `null` once it has finished.
  let foreground: Foreground?
  /// `herdr.space`, `herdr.tab` and `where`, for a terminal the app opened.
  let labels: [String: String]?
  /// What its program last reported. `null` if it never did, which is what a plain shell is.
  let status: Status?
}
