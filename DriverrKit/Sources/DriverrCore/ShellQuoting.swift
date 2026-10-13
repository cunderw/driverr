import Foundation

/// Single-quotes a value for `/bin/sh`, because paths contain spaces, pane labels contain
/// anything, and the command runs as a string on the far side.
///
/// This stops user-typed text (a pane label, a directory) from reaching `/bin/sh` over an
/// SSH exec channel as syntax: command injection into the user's own machine. It lives here
/// because `DriverrHerdr` and `DriverrTranscript` both build commands and may not import each
/// other, and a second copy could be hardened in one module and forgotten in the other.
public func shellQuoted(_ path: String) -> String {
  // An unquoted empty string is no argument at all, which shifts every later argument.
  guard !path.isEmpty else { return "''" }
  guard path.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "-" && $0 != "_" && $0 != "." })
  else { return path }
  return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
