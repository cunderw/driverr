/// Naive matcher for the red run of #122's guards.
enum ClaudeTrustDialog {
  static func isShowing(_ lines: [String]) -> Bool {
    lines.contains { $0.contains("Quick safety check") }
  }
}
