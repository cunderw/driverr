import Foundation

/// Settings files for the hook editor, typed by hand. `realShape` is a full-size settings file
/// in the shape Claude Code writes. Every value is invented.
enum HookSettingsFixture {
  /// Driverr's group as the editor writes it in a file indented two spaces a level: the array
  /// at four spaces, the group at six.
  static let groupAtSix = """
          {
            "matcher": "AskUserQuestion",
            "hooks": [
              {
                "type": "command",
                "command": "cat >/dev/null # driverr:claude.ask-user-question:v1"
              }
            ]
          }
    """

  /// The same group at version 0, as an older build wrote it.
  static let oldGroupAtSix = """
          {
            "matcher": "AskUserQuestion",
            "hooks": [
              {
                "type": "command",
                "command": "true # driverr:claude.ask-user-question:v0"
              }
            ]
          }
    """

  static let secret = "sk-test-NOT-A-REAL-KEY-7f3a9c"

  /// `realShape` up to the end of the last `PreToolUse` group, where the editor appends.
  static let realShapeHead = """
    {
      "model": "example-model",
      "env": {
        "EXAMPLE_FLAG": "1",
        "EXAMPLE_API_KEY": "\(secret)"
      },
      "permissions": {
        "allow": [
          "Bash(echo:*)",
          "Read(/tmp/example/**)",
          "WebFetch(domain:example.com)",
          "Bash(ls:*)"
        ],
        "defaultMode": "default"
      },
      "attribution": {
        "commit": "Example trailer",
        "pr": "Example trailer",
        "sessionUrl": false
      },
      "hooks": {
        "Notification": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/notify.sh"
              }
            ]
          }
        ],
        "SessionStart": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/start.sh",
                "timeout": 10,
                "statusMessage": "Starting example"
              }
            ]
          },
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/start-all.sh",
                "timeout": 5
              }
            ]
          }
        ],
        "PreToolUse": [
          {
            "matcher": "Bash|Edit|Write",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/guard.sh",
                "timeout": 30
              }
            ]
          }
    """

  /// The rest of `realShape`, from the newline that closes the `PreToolUse` array.
  static let realShapeTail = """

        ],
        "PostToolUse": [
          {
            "matcher": "Edit|Write",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/after-edit.sh",
                "timeout": 20
              }
            ]
          },
          {
            "matcher": "Read|Grep",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/after-read.sh",
                "timeout": 20
              }
            ]
          }
        ],
        "Stop": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/example/stop-one.sh",
                "timeout": 15
              },
              {
                "type": "command",
                "command": "/opt/example/stop-two.sh",
                "timeout": 15
              }
            ]
          }
        ]
      },
      "effortLevel": "medium",
      "enabledPlugins": {
        "example-one@example-market": true,
        "example-two@example-market": false
      },
      "statusLine": {
        "type": "command",
        "command": "/opt/example/status.sh",
        "hideVimModeIndicator": true
      },
      "modelSettings": {
        "example-model": {
          "effortLevel": "high"
        }
      },
      "extraKnownMarketplaces": {
        "example-market": {
          "source": {
            "source": "git",
            "url": "https://example.com/market.git"
          }
        }
      }
    }

    """

  static let realShape = realShapeHead + realShapeTail
}
