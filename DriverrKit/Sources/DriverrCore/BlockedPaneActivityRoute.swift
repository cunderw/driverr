import Foundation

/// Where a tap on the Live Activity lands, as a value both sides of the app boundary can
/// build and read.
///
/// `DriverrWatch` runs in a separate process with no shared state, so a card can only hand
/// over a URL. The widget builds one and `ActivityURLRouter` turns it back into a request on
/// `TerminalPresenter`. Foundation only, so the whole contract is `swift test`.
public enum BlockedPaneActivityRoute {
  /// Registered in `Driverr/Info.plist` under `CFBundleURLTypes`. Change both together, or
  /// taps arrive at a scheme nothing handles.
  public static let scheme = "driverr"

  /// The two places a card can send somebody.
  public enum Target: Equatable, Sendable {
    case pane(hostID: UUID, paneID: String)
    case host(hostID: UUID)
  }

  /// What the card in `state` should open.
  ///
  /// One blocked pane opens that pane, several open the host's tree, as
  /// `SessionTree.loneBlockedPane` does for the host list's badge. With no escalation, the
  /// first host on the card. The host comes from the state, not the attributes. Decided here
  /// so the widget holds no rule.
  ///
  /// `nil` only for a state with no hosts, which only a decoded payload from another build
  /// can have. A tap then does nothing.
  public static func target(of state: BlockedPaneActivityAttributes.ContentState) -> Target? {
    if let blocked = state.blocked {
      guard state.blockedCount == 1, !blocked.paneID.isEmpty else {
        return .host(hostID: blocked.hostID)
      }
      return .pane(hostID: blocked.hostID, paneID: blocked.paneID)
    }
    guard let first = state.hosts.first else { return nil }
    return .host(hostID: first.hostID)
  }

  /// Where a tap lands once the app has had its say.
  ///
  /// The URL grammar does not carry a "last pane": the widget cannot know whether that pane
  /// still exists, and the payload outlives the build. The card asks for the host, and the
  /// app resolves that against what it knows at the tap. Four rules:
  ///
  /// - A `.pane` target passes through. The escalated card is about a pane the reader is
  ///   being asked to look at now.
  /// - A `.host` target resumes the remembered pane when it is still on the host.
  ///   `panesOnHost` is the tree at that moment, so a pane closed elsewhere is not there.
  /// - An empty `panesOnHost` (no session, or not read yet) resumes nothing.
  /// - A pane whose witness has changed resumes nothing. herdr reuses positional pane ids, so
  ///   a rebuilt session puts a different pane behind `w1:p2`. `panesOnHost` maps pane id to
  ///   `Pane.sessionWitness`, and the record's witness must match.
  ///
  /// The last rule declines a resume after herdr restores a session from persistence, since
  /// restored terminals get new ids. The reader gets the tree, which is the safe way to be
  /// wrong. An empty pane id or witness in `lastPane` counts as no record.
  public static func resumed(
    _ target: Target, lastPane: LastPaneRecord?, panesOnHost: [String: String]
  ) -> Target {
    guard case .host(let hostID) = target else { return target }
    guard let lastPane, lastPane.isResumable,
      panesOnHost[lastPane.paneID] == lastPane.witness
    else { return target }
    return .pane(hostID: hostID, paneID: lastPane.paneID)
  }

  /// The card's URL, straight from the context the widget already has.
  public static func url(for state: BlockedPaneActivityAttributes.ContentState) -> URL? {
    target(of: state).map { url(for: $0) }
  }

  /// `driverr://pane?host=<uuid>&pane=<paneID>`, or `driverr://host?host=<uuid>`.
  ///
  /// Built through `URLComponents`, never by interpolation, with a stricter encoding than the
  /// default. herdr's pane ids are unconstrained, and `URLComponents` leaves `&`, `=` and `+`
  /// alone in a query value, so an id containing one would split the query.
  /// `queryValueAllowed` encodes them, and the round-trip test covers a hostile id.
  ///
  /// The force-unwrap cannot fail: the scheme and authority are fixed literals and every
  /// query value is percent-encoded.
  public static func url(for target: Target) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    switch target {
    case .pane(let hostID, let paneID):
      components.host = Authority.pane
      components.percentEncodedQueryItems = [
        encoded(Key.host, hostID.uuidString), encoded(Key.pane, paneID),
      ]
    case .host(let hostID):
      components.host = Authority.host
      components.percentEncodedQueryItems = [encoded(Key.host, hostID.uuidString)]
    }
    return components.url!
  }

  /// What `url` names, or `nil` for anything this build does not understand.
  ///
  /// `nil` is ordinary: a card outlives its build and the app can be handed any URL, so a
  /// wrong scheme, an unknown authority or a missing host means "do nothing", as
  /// `NotificationTapRouter.route(userInfo:)` does for an old notification. The authority
  /// decides the destination, never the parameters present, so a later build's extra
  /// parameter cannot change where a tap lands.
  public static func target(of url: URL) -> Target? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == scheme
    else { return nil }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? {
      guard let value = items.first(where: { $0.name == name })?.value, !value.isEmpty
      else { return nil }
      return value
    }
    guard let hostID = value(Key.host).flatMap(UUID.init(uuidString:)) else { return nil }
    switch components.host {
    case Authority.pane:
      guard let paneID = value(Key.pane) else { return nil }
      return .pane(hostID: hostID, paneID: paneID)
    case Authority.host:
      return .host(hostID: hostID)
    default:
      return nil
    }
  }

  private enum Authority {
    static let pane = "pane"
    static let host = "host"
  }

  private enum Key {
    static let host = "host"
    static let pane = "pane"
  }

  /// `urlQueryAllowed` minus the characters that carry structure inside a query.
  ///
  /// `&` and `=` end a field. `+` is read as a space by enough software to be a trap. `?` and
  /// `;` are separators elsewhere. `%` and `#` are already excluded.
  private static let queryValueAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+?;")
    return allowed
  }()

  /// `addingPercentEncoding` cannot fail for a Swift `String`, so the fallback is never used.
  private static func encoded(_ name: String, _ value: String) -> URLQueryItem {
    URLQueryItem(name: name, value: value.addingPercentEncoding(
      withAllowedCharacters: queryValueAllowed) ?? value)
  }
}
