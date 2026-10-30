/// Why a bridge session ended, including the two cases herdr never stated.
///
/// Here because `DriverrHerdr` decodes it and the app decides what to show, and neither may
/// use the other's types. The mapping from herdr's `reason` string happens in
/// `DriverrHerdr`.
///
/// Every case except `.streamEnded` and `.processFailed` comes from a `terminal.closed`
/// record or a core's CLOSE frame. Those two are read off the channel: a stream that stopped silently, and the
/// bridge process's exit status. See `.streamEnded` for why the split matters.
///
/// An `Error` so `PaneBridge.output` and `PaneObserver.output` can throw it. `.paneClosed`
/// finishes the stream cleanly instead; the others need a reaction.
public enum TerminalCloseReason: Error, Equatable, Sendable {
  /// Another client already controls this pane. The deliberate response is
  /// `open(takeover: true)`, which evicts it.
  case refused
  /// This client held the controller and lost it to another client's `--takeover`.
  case takenOver
  /// The pane itself ended the session. No other client was involved.
  case paneClosed
  /// herdr acknowledged a client's attach ending: its `detached`.
  ///
  /// Usually the receipt for our own hand-back (`demote`, `release`). The scene's pumps are
  /// cancelled before that write, and their `Task.isCancelled` guards keep the receipt from
  /// being read as news.
  ///
  /// One that reaches a live surface is herdr dropping our client for its own reason, and
  /// the pane is still running, so `TerminalEndDisposition` treats it like a stopped stream.
  /// herdr spoke, so the attach token went back with the client.
  case detached
  /// herdr is stopping: its `server is shutting down`.
  ///
  /// Every pane on the host ends and none was closed. There is nothing to reattach to until
  /// herdr is back, so this neither reattaches nor claims a close. The token is back.
  case serverShuttingDown
  /// herdr-core lost a kept terminal's program, and a new shell is on the way.
  ///
  /// The terminal is still listed, so this is not a close, and it reattaches once the shell
  /// is up. Until then an attach is refused as unavailable. Sent as a CLOSE frame with
  /// `finished_ms` null.
  case lost
  /// A reason string this build does not recognise, kept verbatim.
  case other(String)
  /// The stream stopped with no `terminal.closed` record: the transport dropped, or the
  /// remote `herdr terminal session control` process died silently.
  ///
  /// It reads to a user like `.paneClosed`, but it differs about herdr's attach token. Every
  /// stated reason means herdr took the token back with the client. A phone losing its link
  /// sends no FIN, so the host never learns and the token stays out.
  /// `TerminalSceneModel.unreleasedControllers` tracks what is still owed, and this
  /// distinction keeps it truthful.
  case streamEnded
  /// The remote `herdr terminal session control` process exited nonzero: it ran and refused.
  ///
  /// `message` is herdr's stderr, extracted and bounded, or `nil` when it said nothing. Not a
  /// `terminal.closed` record, so the pane may still be running and the closed banner must
  /// not show. The token is back, because the process exit closed its socket and herdr
  /// removed the client. No automatic reattach: the same command would refuse again, so the
  /// reader retries.
  case processFailed(status: Int, message: String?)
}
