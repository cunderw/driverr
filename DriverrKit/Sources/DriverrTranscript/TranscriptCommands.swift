import DriverrCore
import Foundation

/// Every command this module runs on the host, as strings, asserted directly by
/// `TranscriptCommandsTests`. Only the opt-in `LiveTranscriptProbeTests` can catch a
/// well-formed but wrong command.
///
/// **Nothing here needs more than POSIX.** `jq` and `python3` are not installed
/// everywhere; `sh`, `tail`, `wc`, `stat`, `awk` and `printf` are.
enum TranscriptCommands {
  /// Separates fields in a header or listing line. A tab-separated first line rather than a
  /// marker, because a marker could appear inside a record.
  static let fieldSeparator: Character = "\t"

  /// The record selector for a Claude session's tail.
  ///
  /// **A line selector, not a parser.** It decides per line whether the line is worth
  /// sending. What a record means is decided in Swift against typed fields.
  ///
  /// Clauses:
  ///
  /// 0. **Keep `system` records with `subtype == "turn_duration"`**, the elapsed time the
  ///    terminal prints under a turn. Other `system` subtypes are not conversation. This is
  ///    a top-level alternation so the later clauses cannot drop it. There is deliberately no
  ///    sidechain filter here; that is decided once, in Swift.
  /// 1. **Keep `user` and `assistant` records.** Everything else is bookkeeping.
  /// 2. **Drop tool results** (records with a top-level `toolUseResult`). They are over half
  ///    of a file's bytes and none of their output is rendered. `resultSelector` sends a
  ///    short line of the fields that matter instead.
  /// 3. **Drop records that are only thinking**, but keep one that also has a `tool_use` or
  ///    `text` block. Thinking is about 30% of what survives and is never rendered.
  /// 4. **Keep an `AskUserQuestion` reply**, the one tool result that travels, so the chat
  ///    can show the answers. It matches a `toolUseResult` whose first key is `questions`,
  ///    and is a top-level alternation so clause 2 cannot drop it. `[{]` rather than `\{`,
  ///    because an escaped brace is an interval in some `awk`s.
  ///
  /// **Why raw-byte matching is safe.** Each pattern is a quoted-key sequence, and inside a
  /// JSON string a quote is written `\"`. So the bytes can only occur as a real key/value
  /// pair, never as text a person or an agent wrote.
  ///
  /// `awk` rather than two `grep`s because clause 3 is a conjunction with an escape hatch,
  /// which `grep -v` cannot express.
  static let recordSelector = #"(/"type":"system"/&&/"subtype":"turn_duration"/)"#
    + #"||(/"type":"user"|"type":"assistant"/"#
    + #"&&!/"toolUseResult":/"#
    + #"&&(!/"type":"thinking"/||/"type":"tool_use"|"type":"text"/))"#
    + #"||/"toolUseResult":[{]"questions":/"#

  /// What opens a **result line**. A record opens with `{`, so `!` cannot collide with one.
  /// The mark alone is the header meaning the results were scanned; `!<id><TAB><0|1>` after
  /// it is one call's answer.
  static let resultMark = "!"

  /// The key that joins a tool's reply to the call it answers.
  static let resultKey = #""tool_use_id":""#

  /// Which calls have been answered, and which answers failed.
  ///
  /// `recordSelector` drops tool results, but their absence is what a pane at a permission
  /// prompt looks like on disk: a prompt writes nothing until it is answered. So two fields
  /// of each result travel instead, as a line of about 33 bytes:
  ///
  /// ```
  /// !toolu_01AbCdEfGhIjKlMnOpQrStUv	0
  /// ```
  ///
  /// Raw-byte matching is safe for `recordSelector`'s reason: `"tool_use_id":"` and
  /// `"is_error":true` occur unescaped only in tool results. `match()` takes the first
  /// occurrence, which is the block's own id. Bounded by the page's `records`, the lines cost
  /// about 1% of a page at every rung of the reader's ladder.
  ///
  /// **An `Agent` call's answer carries three more fields.** An async spawn answers at once,
  /// so a bare `0` would say the agent finished when it had only started:
  ///
  /// ```
  /// !toolu_01Bcdefg…	0	async_launched	a0000000000000001
  /// !toolu_01Hijklm…	0	teammate_spawned
  /// !toolu_01Nopqr…	0	completed	a0000000000000002	9406
  /// ```
  ///
  /// The launch kind, the `agentId` and a sync spawn's `totalDurationMs`. The kind must
  /// travel because a teammate and an async spawn write the same input keys. The `agentId`
  /// joins a handback, which names the agent and not the call (see `taskSelector`). The
  /// fields are written only for the three launch statuses, and `completed` only beside an
  /// `agentId`, so other results keep two fields. Any tool whose answer says
  /// `async_launched` gets them; the parser reads them only on an `Agent` call.
  ///
  /// The `status` match may take the first unescaped occurrence. The launch status is
  /// `toolUseResult`'s first or second key, so the first raw match is the answer's own;
  /// nested `status` keys, such as a `TodoWrite` todo's `"status":"completed"`, come later.
  static let resultSelector = #"/"toolUseResult":/&&match($0,/"tool_use_id":"[^"]*"/){"#
    + #"i=substr($0,RSTART+\#(resultKey.count),RLENGTH-\#(resultKey.count + 1));x="";"#
    + #"if(match($0,/"status":"(async_launched|teammate_spawned|completed)"/)){"#
    + #"s=substr($0,RSTART+10,RLENGTH-11);a="";d="";"#
    + #"if(match($0,/"agentId":"[^"]*"/))a=substr($0,RSTART+11,RLENGTH-12);"#
    + #"if(match($0,/"totalDurationMs":[0-9]+/))d=substr($0,RSTART+18,RLENGTH-18);"#
    + #"if(s!="completed"||a!="")x="\t" s "\t" a "\t" d}"#
    + #"print "\#(resultMark)" i "\t" (index($0,"\"is_error\":true")?1:0) x}"#

  /// What opens a **task line**. Neither a record's `{` nor a result line's `!`.
  static let taskMark = "%"

  /// Where work that outlives its call has got to.
  ///
  /// An async `Agent` call and a `run_in_background` `Bash` call both answer at once. Their
  /// end is written later as a `task-notification` `user` record, a `queued_command`
  /// attachment carrying the same notification, or a handback naming the agent's `agentId`.
  /// Teammates get none of these. Like `resultSelector`, this reads inside the record and
  /// sends one line of about 60 bytes per end:
  ///
  /// ```
  /// %toolu_01Stuvwx…	completed	2026-08-26T22:07:55.206Z
  /// %a0000000000000001	completed	2026-09-19T12:38:56.322Z
  /// ```
  ///
  /// The key is the call's `<tool-use-id>` for a notification and the `agentId` for a
  /// handback, which `TranscriptParser` joins through the result line. The status is the
  /// notification's own word (`completed`, `failed`, `killed`, `stopped`), or `completed`
  /// for a handback. The time is the record's first `timestamp`.
  ///
  /// **The handback clause comes first and ends the line**, so a handback whose report
  /// quotes a `<tool-use-id>` is read as a handback. Nothing escapes `<` inside a JSON
  /// string, so the tags match as written; the record-kind clause keeps out a person who
  /// typed one.
  static let taskSelector =
    #"/"handback":true/&&match($0,/"from":"[^"]*"/){"#
    + #"k=substr($0,RSTART+8,RLENGTH-9);t="?";"#
    + #"if(match($0,/"timestamp":"[^"]*"/))t=substr($0,RSTART+13,RLENGTH-14);"#
    + #"print "\#(taskMark)" k "\tcompleted\t" t;next}"#
    + #"(/"kind":"task-notification"/||/"type":"queued_command"/)"#
    + #"&&match($0,/<tool-use-id>[^<]*</){"#
    + #"k=substr($0,RSTART+13,RLENGTH-14);s="?";t="?";"#
    + #"if(match($0,/<status>[a-z_]*</))s=substr($0,RSTART+8,RLENGTH-9);"#
    + #"if(match($0,/"timestamp":"[^"]*"/))t=substr($0,RSTART+13,RLENGTH-14);"#
    + #"print "\#(taskMark)" k "\t" s "\t" t}"#

  // MARK: - A sub-agent's own file

  /// Which sub-agent files carry a given link, in one round trip.
  ///
  /// A sub-agent's file is `<projectDir>/<sessionId>/subagents/agent-<agentId>.jsonl`, with
  /// a one-line `.meta.json` beside it. The link is `"toolUseId":"<id>"` for an `Agent`
  /// call, or `"name":"<name>"` for an in-process teammate, whose meta has no `toolUseId`.
  /// The caller passes the whole `"key":"value"` fragment as `literal`, so a value recurring
  /// under another key cannot link the wrong file.
  ///
  /// `grep -lF` is the whole job, since each meta file is one line. A `.jsonl` with no
  /// `.meta.json` yet matches nothing, which is right for a sub-agent still starting.
  ///
  /// The answer has `listCommand`'s shape, so `TranscriptReader.listing(from:)` reads it
  /// and `TranscriptFile.newestFirst` picks the newest when a respawned teammate leaves
  /// several files under one name.
  ///
  /// Always exits 0: a missing directory, no match, or a vanished `.jsonl` all mean "no
  /// such link", not a channel failure.
  ///
  /// **`sessionID` `nil` searches every session in the project directory.** A spawn made
  /// before a `continued-in` handover can have its meta file under either session, and
  /// nothing in its record says which. `grep -r --include` walks the tree itself so
  /// thousands of meta files cannot hit the argument limit. The printed names are relative
  /// to the project directory, so `listing(from:)` joins them as it joins a session file.
  static func subagentLinkCommand(directory: String, sessionID: String?, literal: String) -> String {
    let d = sessionID.map { "\(directory)/\($0)/subagents" } ?? directory
    let search =
      sessionID == nil
      ? "grep -rlF --include='*.meta.json' -e \(shellQuoted(literal)) . 2>/dev/null"
      : "grep -lF -e \(shellQuoted(literal)) -- *.meta.json 2>/dev/null"
    return [
      literalEmptyGlobs,
      "date +%s",
      "d=\(shellQuoted(d))",
      "printf '%s\\n' \"$d\"",
      "if [ -d \"$d\" ]; then cd \"$d\" || exit 0",
      // `do` carries its first statement on the same element: `do; cmd` is a syntax error
      // in `sh`.
      "for m in $(\(search)); do f=\"${m%.meta.json}.jsonl\"",
      // The project-wide search prints `./<sessionId>/subagents/…`. Only a meta file inside
      // a `subagents` directory counts, and the `./` comes off the name.
      "case \"$f\" in ./*/subagents/*) f=\"${f#./}\" ;; ./*) continue ;; esac",
      "[ -f \"$f\" ] || continue",
      "mt=$(\(statModified) \"$f\" 2>/dev/null || stat -f %m \"$f\" 2>/dev/null)",
      "s=$(wc -c < \"$f\" 2>/dev/null)",
      "printf '%s\\t%s\\t%s\\n' \"${mt:-?}\" \"${s:-?}\" \"$f\"",
      "done",
      "fi",
    ].joined(separator: "; ")
  }

  /// What opens the line that counts a session's meta files. Neither a path nor an epoch.
  static let subagentCountMark = "#"

  /// How many meta files `subagentListCommand` prints. A session has been seen with 243;
  /// at about 500 bytes a line this keeps the answer under 30 KB.
  static let subagentListLimit = 50

  /// The part of `subagentListCommand` no other command carries, so `FakeTranscriptHost`
  /// can key on it.
  static let subagentListSelector = "ls -t -- *.meta.json"

  /// Every sub-agent one session spawned, newest spawned first, in one round trip.
  ///
  /// The host's clock, the directory, the count of meta files, then one line per meta file,
  /// at most `subagentListLimit`:
  ///
  /// ```
  /// 1787780603
  /// /home/me/.claude/projects/-home-me-dev-driverr/<sessionId>/subagents
  /// #3
  /// 1787780001<TAB>1787780590<TAB>48211<TAB>agent-ascout-23ad….jsonl<TAB>{"agentType":…}
  /// ```
  ///
  /// The meta file's mtime (when it was spawned; the file is written once), the `.jsonl`'s
  /// mtime and size, the `.jsonl`'s name, and **the meta file's one line, as written**. The
  /// meta is about 400 bytes of JSON whose `description` can carry an escaped quote, which
  /// an `awk` field match would cut short. JSON cannot hold a raw tab or newline, so it
  /// travels last and whole, and `TranscriptReader` decodes it. The `.jsonl` is only
  /// `stat`ed and measured, never read.
  ///
  /// `ls -t` orders by the meta's mtime, so the cap keeps the newest spawns. A `.jsonl` not
  /// written yet prints `?` for its mtime and size.
  ///
  /// Always exits 0: a missing directory or no meta files is a session with no sub-agents.
  static func subagentListCommand(directory: String, sessionID: String) -> String {
    let d = "\(directory)/\(sessionID)/subagents"
    return [
      literalEmptyGlobs,
      "date +%s",
      "d=\(shellQuoted(d))",
      "printf '%s\\n' \"$d\"",
      "if [ -d \"$d\" ]; then cd \"$d\" || exit 0",
      // `wc -l` pads its count on BSD; the reader trims it.
      "printf '\(subagentCountMark)%s\\n' \"$(ls -- *.meta.json 2>/dev/null | wc -l)\"",
      // `do` carries its first statement on the same element, as in `subagentLinkCommand`.
      "for m in $(\(subagentListSelector) 2>/dev/null | head -n \(subagentListLimit)); do"
        + " [ -f \"$m\" ] || continue",
      "f=\"${m%.meta.json}.jsonl\"",
      "ms=$(\(statModified) \"$m\" 2>/dev/null || stat -f %m \"$m\" 2>/dev/null)",
      "mt=$(\(statModified) \"$f\" 2>/dev/null || stat -f %m \"$f\" 2>/dev/null)",
      // Guarded, because zsh reports a failed `<` on its own stderr, whatever the command
      // itself redirects.
      "s=; [ -f \"$f\" ] && s=$(wc -c < \"$f\" 2>/dev/null)",
      "printf '%s\\t%s\\t%s\\t%s\\t' \"${ms:-?}\" \"${mt:-?}\" \"${s:-?}\" \"$f\"",
      "tr -d '\\n' < \"$m\"",
      "printf '\\n'",
      "done",
      "fi",
    ].joined(separator: "; ")
  }

  /// Everything the resolver needs about one project directory, in one round trip.
  ///
  /// The **host's** clock comes first, then one line per session file. Ages are the host's
  /// clock minus the host's mtime, so a phone clock that is minutes out cannot make a live
  /// session look stale.
  ///
  /// ```
  /// 1787780603
  /// /home/me/.claude/projects/-home-me-dev-driverr
  /// 1787780591<TAB>541536<TAB>0a1b2c3d-….jsonl
  /// ```
  ///
  /// **`stat -c` is tried before `stat -f`.** GNU's `-f` is `--file-system`, so
  /// `stat -f %m <file>` on Linux succeeds and prints the mount point. BSD's `stat` rejects
  /// `-c` and falls through. The Swift side also digit-checks the answer.
  ///
  /// Always exits 0, including when the directory does not exist: "no session files" is an
  /// answer.
  static func listCommand(projectSlug: String) -> String {
    return [
      literalEmptyGlobs,
      "date +%s",
      // Built on the host because `$HOME` is the host's answer. The slug is quoted
      // separately and the shell concatenates the two.
      "d=\(ClaudeProjects.root)/\(shellQuoted(projectSlug))",
      // Echoed back so the phone can build absolute paths. A relative one would depend on
      // where the next exec channel's shell starts.
      "printf '%s\\n' \"$d\"",
      "if [ -d \"$d\" ]; then cd \"$d\" || exit 0",
      "for f in *.\(ClaudeProjects.fileExtension); do [ -f \"$f\" ] || continue",
      // stderr is discarded because the failing spelling always writes a usage error.
      "m=$(\(statModified) \"$f\" 2>/dev/null || stat -f %m \"$f\" 2>/dev/null)",
      "s=$(wc -c < \"$f\" 2>/dev/null)",
      // `?` rather than an empty field, so a missing value cannot collapse two tabs and
      // shift the filename into the size column.
      "printf '%s\\t%s\\t%s\\n' \"${m:-?}\" \"${s:-?}\" \"$f\"",
      "done",
      "fi",
    ].joined(separator: "; ")
  }

  /// Makes zsh treat a glob that matches nothing the way `sh` does.
  ///
  /// The exec channel runs the login shell, which on a Mac is zsh. zsh's default `nomatch`
  /// turns an empty `for f in *.jsonl` into `no matches found`, exit 1, and nothing after it
  /// runs. `sh`, `bash` and `dash` pass the pattern through, which every loop here skips
  /// with its `[ -f ]` or `[ -d ]` guard. Those shells have no `unsetopt` and discard the
  /// error. csh fails earlier, at `for … do`. It is the first statement of every command
  /// that globs; `EmptyGlobCommandTests` runs each one through all four shells.
  static let literalEmptyGlobs = "unsetopt nomatch 2>/dev/null"

  /// The GNU spelling of "print this file's mtime", tried before the BSD one. Named once
  /// because `FakeTranscriptHost` keys the size command on it.
  static let statModified = "stat -c %Y"

  /// Has this file been written to: mtime and size, and nothing else.
  ///
  /// ```
  /// 1787780591	541536
  /// ```
  ///
  /// An open chat asks this every few seconds and fetches a page only when the answer moves.
  /// A page costs three to four orders of magnitude more; see `readCommand`.
  ///
  /// `stat -c` before `stat -f`, and `?` for an unreadable value, for `listCommand`'s
  /// reasons. Always exits 0: a file that has gone shows as `?`, and a non-zero exit means
  /// the channel failed.
  static func sizeCommand(path: String) -> String {
    sizeCommand(assigning: shellQuoted(path))
  }

  /// The size command for a session file herdr has named but the listing has not found yet.
  ///
  /// A restarted Claude Code reports its new session id about a second after it starts but
  /// writes no file until its first prompt. The watcher asks this on each tick until then,
  /// instead of a whole listing. The path is built on the host, as in `listCommand`.
  ///
  /// ```
  /// f="$HOME/.claude/projects"/'-Users-x-dev'/'0a1b2c3d-….jsonl'
  /// ```
  static func reportedSizeCommand(projectSlug: String, sessionID: String) -> String {
    sizeCommand(
      assigning: "\(ClaudeProjects.root)/\(shellQuoted(projectSlug))/"
        + shellQuoted("\(sessionID).\(ClaudeProjects.fileExtension)"))
  }

  /// `sizeCommand`'s body, over a path that is already a shell word.
  private static func sizeCommand(assigning path: String) -> String {
    return [
      "f=\(path)",
      // stderr is discarded because the failing spelling always writes a usage error.
      "m=$(\(statModified) \"$f\" 2>/dev/null || stat -f %m \"$f\" 2>/dev/null)",
      "s=$(wc -c < \"$f\" 2>/dev/null)",
      "printf '%s\\t%s\\n' \"${m:-?}\" \"${s:-?}\"",
    ].joined(separator: "; ")
  }

  /// The **head**-end selector: records that could be something a person typed. Keeps
  /// `user` records, drops tool results, and drops `isMeta` injected text, which dominates
  /// the front of a real file. Raw-byte matching is safe for `recordSelector`'s reason.
  static let briefSelector = #"/"type":"user"/&&!/"toolUseResult":/&&!/"isMeta":true/"#

  /// How far into a file to look for its opening line, in lines. The first human record is
  /// around line 11 and almost always within forty. Lines rather than bytes, because a
  /// file's head holds a few huge `attachment` records that make byte offsets vary widely.
  static let briefLines = 40

  /// How many selected records travel per file. Four, because a cleared conversation opens
  /// with `/clear` and the real opening line is a record or two later.
  static let briefRecords = 4

  /// The longest record worth sending. Guards against a pasted image: a normal opening
  /// record is a few KB, one with a screenshot is hundreds. A skipped candidate falls back
  /// to its filename and mtime.
  static let briefRecordBytes = 32_768

  /// Every candidate's opening records, in one round trip. The only command that reads the
  /// front of a file, because the opening line is what names a conversation.
  ///
  /// ```
  /// 0a1b2c3d-….jsonl<TAB>{"type":"user","message":{…"review the diff on the focus branch"…}}
  /// 4e5f6a7b-….jsonl<TAB>{"type":"user","message":{…"start on the pane-focus bug"…}}
  /// ```
  ///
  /// About 1 KB per file at the median, an order of magnitude less than a first page.
  ///
  /// `FILENAME` rather than `awk -v`, because `-v` expands escape sequences in a filename.
  /// One `awk` per file, because resetting a counter per file needs `nextfile`, which is
  /// not POSIX.
  ///
  /// Always exits 0: a file that vanished has no brief. Without the trailing `exit 0` the
  /// loop's status would be the last `[ -f ]` test's. `nil` for an empty list, so no round
  /// trip is spent on it.
  static func briefCommand(directory: String, names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    let program = [
      "FNR>\(briefLines){exit}",
      briefSelector + "{",
      "if(length($0)<=\(briefRecordBytes)){print FILENAME \"\\t\" $0; c++}",
      "if(c>=\(briefRecords))exit",
      "}",
    ].joined()
    return [
      // Entered once so each record is labelled with a filename, not the whole path.
      "cd \(shellQuoted(directory)) 2>/dev/null || exit 0",
      "for f in \(names.map(shellQuoted).joined(separator: " ")); do [ -f \"$f\" ] || continue",
      "awk \(shellQuoted(program)) \"$f\" 2>/dev/null",
      "done",
      "exit 0",
    ].joined(separator: "; ")
  }

  /// The record Claude Code appends when it carries a session into a new file. It must be a
  /// `continued-in` and name a successor. `match()` sets `RSTART` and `RLENGTH` so the id can
  /// be cut out. Raw-byte matching is safe for `recordSelector`'s reason.
  static let continuationSelector = #"/"type":"continued-in"/"#
    + #"&&match($0,/"continuedInSessionId":"[^"]*"/)"#

  /// The key whose value is the session the conversation moved to.
  static let continuationKey = #""continuedInSessionId":""#

  /// How far back to look for the handover, in bytes. The record is the last line of the
  /// file and about 170 bytes; 8 KB allows for a large record before it. It is read on the
  /// host, so only a filename and a uuid cross the wire.
  static let continuationBytes = 8192

  /// Which of these files were continued into another, and into which.
  ///
  /// herdr reports the session id a pane's agent started with and never revises it, so a
  /// continued session leaves the resolver on a file that stopped growing. This recovers the
  /// pointer from the old file's tail:
  ///
  /// ```
  /// !8c9d0e1f-….jsonl<TAB>2a3b4c5d-0000-4000-8000-000000000001
  /// ```
  ///
  /// Every candidate in one command, because a chain is walked and one file per call would
  /// cost a round trip per hop. The filename comes from the shell, because `awk` reads a
  /// pipe here and `FILENAME` is empty.
  ///
  /// Always exits 0, and `nil` for an empty list, for `briefCommand`'s reasons.
  static func continuationCommand(directory: String, names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    let program = continuationSelector
      + #"{v=substr($0,RSTART+\#(continuationKey.count),RLENGTH-\#(continuationKey.count + 1))}"#
      // The **last** handover wins, so the whole tail is scanned. Stopping at the first hit
      // could send the walk to a file the conversation already left.
      + #"END{if(v!="")print v}"#
    return [
      "cd \(shellQuoted(directory)) 2>/dev/null || exit 0",
      "for f in \(names.map(shellQuoted).joined(separator: " ")); do [ -f \"$f\" ] || continue",
      "i=$(tail -c \(continuationBytes) \"$f\" 2>/dev/null | awk \(shellQuoted(program)))",
      "[ -n \"$i\" ] && printf '%s%s\\t%s\\n' \(shellQuoted(resultMark)) \"$f\" \"$i\"",
      "done",
      "exit 0",
    ].joined(separator: "; ")
  }

  // MARK: - What is installed on this host

  /// What opens an **entry line** in the skills answer: the mark, a one-letter scope, a tab,
  /// and the command's name. Every frontmatter line is prefixed with `frontmatterMark`, so a
  /// description that begins with `!` cannot be read as an entry.
  static let skillMark = "!"

  /// What opens a **frontmatter line**. A description can contain anything, including a
  /// line of three dashes, so a terminator could be forged by content; a per-line prefix
  /// cannot.
  static let frontmatterMark = "+"

  /// The scope letters. One character, because the scope travels on every entry.
  static let userSkillScope = "u"
  static let projectSkillScope = "p"
  static let projectCommandScope = "c"
  static let pluginSkillScope = "g"

  /// How much of a `SKILL.md` is read looking for its frontmatter. Real blocks are under
  /// 700 bytes. The read is on the host; only the selected frontmatter crosses the wire.
  static let frontmatterBytes = 1024

  /// How many frontmatter lines are sent per entry. Bounds only an unclosed block, so a
  /// broken skill costs one entry.
  static let frontmatterLines = 24

  /// How many entries the answer may carry. A real machine has about 90; this bounds a
  /// plugin cache that has grown without limit.
  static let skillEntries = 300

  /// How many bytes the whole answer may be; the bound that holds whatever the others did.
  /// A real answer is about 34 KB and is fetched once per pane appearance. A truncated
  /// answer is a shorter catalogue, because the parser drops a partial entry.
  static let skillPayloadBytes = 65_536

  /// The `awk` that turns one skill file into prefixed frontmatter lines:
  ///
  /// 1. A file that does not open with `---` has no frontmatter, so nothing is printed. That
  ///    is the usual `.claude/commands/*.md`; the entry line is already printed, so the
  ///    command appears with no caption.
  /// 2. The opening `---` is not content.
  /// 3. The closing `---` ends the block, which keeps a body's own `---` out.
  /// 4. Everything else is printed with `frontmatterMark` in front.
  ///
  /// **A trailing carriage return is stripped first.** A CRLF file opens with `---\r`, which
  /// would fire clause 1 and lose the frontmatter, and the `\r` would ride the description
  /// across the wire. `sub` in a leading rule rewrites `$0` before later patterns test it.
  static var frontmatterSelector: String {
    [
      #"{sub(/\r$/,"")}"#,
      #"NR==1&&$0!="---"{exit}"#,
      "NR==1{next}",
      #"/^---[ \t]*$/{exit}"#,
      "NR>\(frontmatterLines){exit}",
      #"{print "\#(frontmatterMark)" $0}"#,
    ].joined()
  }

  /// Every slash command installed for this session, in one round trip.
  ///
  /// ```
  /// !u	lint
  /// +name: lint
  /// +description: >-
  /// +  Find and fix compiler warnings in the files this branch changed …
  /// !c	analyze
  /// !g	acme:sync-files
  /// +name: sync-files
  /// +description: Copy the build output to the shared folder.
  /// ```
  ///
  /// Four locations:
  ///
  /// - `$HOME/.claude/skills/*/SKILL.md`, the user's own. Some are symlinks, so the test is
  ///   `[ -f "$d/SKILL.md" ]`, not a directory check.
  /// - `<cwd>/.claude/skills/*/SKILL.md` and `<cwd>/.claude/commands/*.md`, the project's.
  ///   Absent when the pane has no `cwd`.
  /// - Plugin skills under the `installPath` values in
  ///   `$HOME/.claude/plugins/installed_plugins.json`.
  ///
  /// **Plugins are filtered by that file, not globbed from the cache.** The cache keeps old
  /// version directories, and a skill from a version that is not installed is a command the
  /// far side will not recognise.
  ///
  /// **The glob under an install path is `*/*/SKILL.md`, not `skills/*/`**, because plugins
  /// use more than one directory name (`skills` is one of several).
  ///
  /// **The plugin's name is prepended** (`acme:sync-files`), because that is how Claude Code
  /// addresses a plugin's skill.
  ///
  /// `grep -Eo` and `sed` rather than `jq`, which is not installed everywhere.
  ///
  /// Always exits 0 through `head`. A host with no `.claude` prints nothing, which means no
  /// skills. `TranscriptReader.skills(cwd:)` treats a failure as an empty catalogue.
  static func skillsCommand(home: String = hostHome, cwd: String?) -> String {
    let selector = shellQuoted(frontmatterSelector)
    // `n` is the entry counter. `a` holds the awk program so it crosses the wire once,
    // not four times.
    var lines: [String] = [
      literalEmptyGlobs,
      "(h=\(home)",
      "a=\(selector)",
      "n=0",
    ]
    lines += entryLoop(
      glob: #""$h"/.claude/skills/*/"#,
      scope: userSkillScope
    )
    if let cwd, !cwd.isEmpty {
      lines.append("c=\(shellQuoted(cwd))")
      lines += entryLoop(
        glob: #""$c"/.claude/skills/*/"#,
        scope: projectSkillScope
      )
      lines += [
        #"for f in "$c"/.claude/commands/*.md; do [ -f "$f" ] || continue"#,
        "n=$((n+1)); [ \"$n\" -gt \(skillEntries) ] && break",
        "b=${f##*/}; b=${b%.md}",
        #"printf '\#(skillMark)\#(projectCommandScope)\t%s\n' "$b""#,
        "head -c \(frontmatterBytes) \"$f\" 2>/dev/null | awk \"$a\"",
        "done",
      ]
    }
    lines += [
      "j=$h/.claude/plugins/installed_plugins.json",
      // **`then` and `do` carry their first statement on the same element.** The lines are
      // joined with `; `, and `then; cmd` and `do; cmd` are syntax errors in `sh`.
      //
      // `sort -u` because an install path can be recorded twice. The plugin's name is the
      // parent of the version directory the install path names.
      //
      // **`IFS` is a newline for this loop**, so an install path with a space is not split
      // into two words, which would drop all its skills. A home directory with a space is
      // ordinary on a Mac. `$(printf '\n')` cannot build the newline because command
      // substitution strips trailing newlines; the `_` sentinel survives, and `${IFS%_}`
      // removes it.
      "o=$IFS; IFS=$(printf '\\n_'); IFS=${IFS%_}",
      "if [ -f \"$j\" ]; then for p in"
        + " $(grep -Eo '\"installPath\"[ ]*:[ ]*\"[^\"]*\"' \"$j\" 2>/dev/null"
        + " | sed 's/.*\"\\(.*\\)\"$/\\1/' | sort -u); do g=${p%/*}; g=${g##*/}",
      "for s in \"$p\"/*/*/SKILL.md; do [ -f \"$s\" ] || continue",
      "n=$((n+1)); [ \"$n\" -gt \(skillEntries) ] && break",
      "b=${s%/SKILL.md}; b=${b##*/}",
      #"printf '\#(skillMark)\#(pluginSkillScope)\t%s:%s\n' "$g" "$b""#,
      "head -c \(frontmatterBytes) \"$s\" 2>/dev/null | awk \"$a\"",
      "done",
      "done",
      "fi",
      "IFS=$o",
      ") 2>/dev/null | head -c \(skillPayloadBytes)",
    ]
    return lines.joined(separator: "; ")
  }

  /// The host's home directory, as a shell fragment the host expands, for
  /// `ClaudeProjects.root`'s reason. A parameter on `skillsCommand` so a test can pin a
  /// literal home.
  static let hostHome = "\"$HOME\""

  /// One `for` loop over a glob of skill directories. The user and project scopes differ
  /// only in glob and letter, so they share this.
  private static func entryLoop(glob: String, scope: String) -> [String] {
    let file = "$d/SKILL.md"
    return [
      "for d in \(glob); do [ -f \"\(file)\" ] || continue",
      "n=$((n+1)); [ \"$n\" -gt \(skillEntries) ] && break",
      "b=${d%/}; b=${b##*/}",
      #"printf '\#(skillMark)\#(scope)\t%s\n' "$b""#,
      "head -c \(frontmatterBytes) \"\(file)\" 2>/dev/null | awk \"$a\"",
      "done",
    ]
  }

  /// A bounded tail of one session file, with a header describing the whole file.
  ///
  /// ```
  /// 541536<TAB>complete
  /// {"parentUuid":…,"type":"assistant",…}
  /// !
  /// !toolu_01AbCdEfGhIjKlMnOpQrStUv<TAB>0
  /// ```
  ///
  /// **The parser tells the sections apart on the first byte**: the header is line 1, a
  /// record opens with `{`, a result line with `!`, a task line with `%`. The bare `!` is
  /// printed unconditionally. Without it, a page with no result lines would look like a host
  /// that never looked, and every run would read as still waiting. Result and task lines
  /// come after the records so they cannot eat the record bound.
  ///
  /// Three bounds:
  ///
  /// - `tail -c bytes` bounds what the host reads off its own disk, which is free.
  /// - The selector decides the bill; it cuts a real tail by 3 to 63 times.
  /// - `tail -n records` bounds what crosses the wire whatever the first two did.
  ///
  /// A first page is one round trip for most files and 1 KB to about 100 KB on the wire.
  /// Most of what is left is `tool_use` input, such as the whole file a `Write` wrote.
  /// Cutting that would need a JSON extractor on the host, which is not built.
  ///
  /// **A partial last record is detected from the final byte.** An appender writes its
  /// newline last, so a final byte that is not a newline is a half-written record. A parse
  /// failure cannot tell this, because a byte tail always begins mid-record.
  static func readCommand(path: String, bytes: Int, records: Int) -> String {
    let file = shellQuoted(path)
    return [
      "f=\(file)",
      "s=$(wc -c < \"$f\" 2>/dev/null)",
      "if [ -n \"$(tail -c 1 \"$f\" 2>/dev/null)\" ]; then t=partial; else t=complete; fi",
      // `?` for an unreadable size, so a missing file is not mistaken for an empty one.
      "printf '%s\\t%s\\n' \"${s:-?}\" \"$t\"",
      "tail -c \(bytes) \"$f\" 2>/dev/null | awk \(shellQuoted(recordSelector)) | tail -n \(records)",
      // Unconditional, and before the scan, so "the host looked" is never mistaken for "the
      // host found nothing".
      "printf '%s\\n' \(shellQuoted(resultMark))",
      // The same byte tail, read again on the host, so result lines stay outside the record
      // bound. Bounded by the same `records`, which keeps them about 1% of a page.
      "tail -c \(bytes) \"$f\" 2>/dev/null | awk \(shellQuoted(resultSelector)) | tail -n \(records)",
      // Task lines, from a third read bounded the same way. After the results, so neither
      // eats the other's bound.
      "tail -c \(bytes) \"$f\" 2>/dev/null | awk \(shellQuoted(taskSelector)) | tail -n \(records)",
    ].joined(separator: "; ")
  }

  // MARK: - Codex rollouts

  /// Prints `payload.cwd`, `payload.thread_source` and `payload.id`, tab-separated, from a
  /// rollout's line 1. Raw-byte matching is safe for `recordSelector`'s reason. A raw Swift
  /// string, so `\t` reaches `awk`'s `printf` as two characters.
  static let codexHeaderProgram =
    #"{cwd="?";ts="?";id="?";"#
    + #"if(match($0,/"cwd":"[^"]*"/))cwd=substr($0,RSTART+7,RLENGTH-8);"#
    + #"if(match($0,/"thread_source":"[^"]*"/))ts=substr($0,RSTART+17,RLENGTH-18);"#
    + #"if(match($0,/"id":"[^"]*"/))id=substr($0,RSTART+6,RLENGTH-7);"#
    + #"printf "%s\t%s\t%s",cwd,ts,id}"#

  /// Every rollout on this host, in one round trip. The Codex counterpart to `listCommand`.
  ///
  /// ```
  /// 1789145200
  /// /Users/x/.codex/sessions/2026/09/11/rollout-….jsonl<TAB>/Users/x/repo<TAB>user<TAB>01a00000-…<TAB>1789000000<TAB>3000000
  /// ```
  ///
  /// **`date +%s` opens it, as in `listCommand`.** Every age is the host's own subtraction,
  /// so without the host's clock every age is `nil`. Codex writes a rollout per day, so a
  /// directory with several would then always be ambiguous.
  ///
  /// It walks day directories, because Codex files rollouts by date, not by project.
  /// Narrowing to one pane's thread happens in Swift, in
  /// `CodexRollouts.mainThreadCandidates(from:workingDirectory:)`.
  ///
  /// `while IFS= read -r day` rather than `for day in $(…)`, because word splitting breaks a
  /// `$HOME` with a space in it.
  ///
  /// Always exits 0. A rollout the host cannot read gives an empty header and does not fail
  /// the listing.
  static func codexListCommand() -> String {
    return [
      literalEmptyGlobs,
      "date +%s",
      "d=\(CodexRollouts.root)",
      "if [ -d \"$d\" ]; then find \"$d\" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r"
        + " | head -n \(CodexRollouts.maxDayDirectories) | while IFS= read -r day",
      "do for f in \"$day\"/*.\(CodexRollouts.fileExtension); do [ -f \"$f\" ] || continue",
      "h=$(head -n 1 \"$f\" 2>/dev/null | awk \(shellQuoted(codexHeaderProgram)))",
      "m=$(\(statModified) \"$f\" 2>/dev/null || stat -f %m \"$f\" 2>/dev/null)",
      "s=$(wc -c < \"$f\" 2>/dev/null)",
      "printf '%s\\t%s\\t%s\\t%s\\n' \"$f\" \"$h\" \"${m:-?}\" \"${s:-?}\"",
      "done",
      "done",
      "fi",
    ].joined(separator: "; ")
  }

  /// The line selector for a rollout's tail: `UserMessage` and `AgentMessage` from
  /// `event_msg`, `custom_tool_call` and `function_call` from `response_item`. See
  /// `CodexRecord` for why. Raw-byte matching is safe for `recordSelector`'s reason.
  static let codexRecordSelector =
    #"/"type":"UserMessage"|"type":"AgentMessage"|"type":"custom_tool_call"|"type":"function_call"/"#

  /// The host-side extractor for a `CommandExecution` completion.
  ///
  /// It reads inside the record, as `resultSelector` does, because an item carries its full
  /// output (tens of KB) and Driverr wants `id`, `status`, `exit_code` and the command run.
  ///
  /// **The command cannot be captured with `[^"]*`.** A tool-use id never contains a quote,
  /// but a shell command often does, and a truncated key would fail to join. So `scanStr`
  /// walks the string honouring JSON's escape rule (`\` consumes the next byte), and
  /// `lastCommandElement` keeps the last element of `"command":[…]`, the command after the
  /// `["/bin/zsh","-lc",…]` prefix. User-defined `function`s are POSIX awk.
  ///
  /// The command travels still JSON-escaped, and `TranscriptParser.codexUnescape` decodes
  /// it. The call's `cmd:"…"` literal goes through the same function, so both sides of the
  /// join compare like text.
  ///
  /// `match()`'s first occurrence is safe for `id`, `status` and `exit_code`, even though
  /// `exit_code` follows `stdout`, because a quote inside a JSON string is escaped.
  ///
  /// One line per completion, with `?` for a field that was not found:
  ///
  /// ```
  /// !exec-00000000-0000-4000-8000-000000000001	completed	0	sed -n '1,40p' README.md
  /// ```
  static let codexOutcomeProgram = #"""
    function scanStr(s, i,    n, c) {
      n = length(s)
      i++
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\"") return i
        i++
      }
      return 0
    }
    function lastCommandElement(s,    p, c, endp, ls, le) {
      p = index(s, "\"command\":[")
      if (p == 0) return ""
      p += 11
      ls = 0; le = 0
      while (1) {
        c = substr(s, p, 1)
        if (c == "" || c == "]") break
        if (c == ",") { p++; continue }
        if (c != "\"") break
        endp = scanStr(s, p)
        if (endp == 0) break
        ls = p + 1
        le = endp - 1
        p = endp + 1
      }
      if (ls == 0) return ""
      return substr(s, ls, le - ls + 1)
    }
    /"type":"item_completed"/&&/"type":"CommandExecution"/{
      id="?"; st="?"; ec="?"
      if (match($0, /"id":"[^"]*"/)) id = substr($0, RSTART+6, RLENGTH-7)
      if (match($0, /"status":"[^"]*"/)) st = substr($0, RSTART+10, RLENGTH-11)
      if (match($0, /"exit_code":-?[0-9]+/)) ec = substr($0, RSTART+12, RLENGTH-12)
      cmd = lastCommandElement($0)
      printf "!%s\t%s\t%s\t%s\n", id, st, ec, cmd
    }
    """#

  /// A bounded tail of one Codex rollout, the counterpart to `readCommand`. Outcome lines
  /// come from a second read of the same tail, bounded by the same `records`. The bare `!`
  /// is printed unconditionally before that scan, for `readCommand`'s reason: otherwise a
  /// trailing `exec_command` call would read as pending when it is only unaccounted for.
  static func codexReadCommand(path: String, bytes: Int, records: Int) -> String {
    let file = shellQuoted(path)
    return [
      "f=\(file)",
      "s=$(wc -c < \"$f\" 2>/dev/null)",
      "if [ -n \"$(tail -c 1 \"$f\" 2>/dev/null)\" ]; then t=partial; else t=complete; fi",
      "printf '%s\\t%s\\n' \"${s:-?}\" \"$t\"",
      "tail -c \(bytes) \"$f\" 2>/dev/null | awk \(shellQuoted(codexRecordSelector)) | tail -n \(records)",
      "printf '%s\\n' \(shellQuoted(resultMark))",
      "tail -c \(bytes) \"$f\" 2>/dev/null | awk \(shellQuoted(codexOutcomeProgram)) | tail -n \(records)",
    ].joined(separator: "; ")
  }
}
