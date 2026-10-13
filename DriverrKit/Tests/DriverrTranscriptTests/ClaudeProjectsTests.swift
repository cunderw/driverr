import Foundation
import Testing

@testable import DriverrTranscript

/// The one derivation the whole tier-2 path stands on.
struct ClaudeProjectsTests {
  @Test("every slash becomes a dash")
  func slashes() {
    #expect(
      ClaudeProjects.slug(forWorkingDirectory: "/Users/x/Dev/projects/app")
        == "-Users-x-Dev-projects-app"
    )
  }

  @Test("a worktree path keeps its own shape")
  func worktrees() {
    #expect(
      ClaudeProjects.slug(
        forWorkingDirectory: "/Users/x/Dev/projects/app-worktrees/feat-1-example"
      ) == "-Users-x-Dev-projects-app-worktrees-feat-1-example"
    )
  }

  /// No real working directory here had a dot, so this was established with a throwaway
  /// session: `…/dot.test.dir` wrote `…-dot-test-dir`.
  @Test("every dot becomes a dash too, including in a worktree name")
  func dots() {
    #expect(ClaudeProjects.slug(forWorkingDirectory: "/tmp/dot.test.dir") == "-tmp-dot-test-dir")
    #expect(
      ClaudeProjects.slug(forWorkingDirectory: "/Users/x/Dev/my.app/worktrees/fix-1.2.3")
        == "-Users-x-Dev-my-app-worktrees-fix-1-2-3"
    )
    #expect(ClaudeProjects.slug(forWorkingDirectory: "/Users/x/.claude") == "-Users-x--claude")
  }

  @Test("a trailing slash names the same directory as no trailing slash")
  func trailingSlash() {
    #expect(
      ClaudeProjects.slug(forWorkingDirectory: "/Users/x/dev/")
        == ClaudeProjects.slug(forWorkingDirectory: "/Users/x/dev")
    )
    #expect(ClaudeProjects.slug(forWorkingDirectory: "/") == "-")
  }

  /// Not normalised on purpose. A relative or tilde `cwd` derives a directory that does not
  /// exist, which is the true answer; expanding `~` would guess the host's home.
  @Test("nothing else is normalised")
  func nothingElseIsNormalised() {
    #expect(ClaudeProjects.slug(forWorkingDirectory: "~/dev/driverr") == "~-dev-driverr")
    #expect(ClaudeProjects.slug(forWorkingDirectory: "dev/driverr") == "dev-driverr")
    #expect(ClaudeProjects.slug(forWorkingDirectory: "/Users/x/a b") == "-Users-x-a b")
  }
}
