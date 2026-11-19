import DriverrCore
import Observation
import SwiftUI

/// One New Agent sheet's state: the form, and what the start did.
///
/// The form's rules are `NewAgentForm`, in `DriverrCore`. This holds what needs the app: the
/// start, which goes through the host's `SessionModel`, and opening the pane it started.
@MainActor
@Observable
final class NewAgentModel {
  enum Phase: Equatable {
    case editing
    /// A start is out. It can take about 13 s on herdr's TUI. See `HerdrControl.startAgent`.
    case starting
    case failed(AppError)
  }

  let hostName: String
  /// The folders the host's panes are in, offered first. See `SessionTree.agentFolders`.
  let recentFolders: [String]

  /// What the person has chosen so far. A change clears a failure, which was about what the
  /// form held before.
  var form = NewAgentForm() {
    didSet {
      if case .failed = phase, form != oldValue { phase = .editing }
    }
  }

  private(set) var phase: Phase = .editing

  /// Starts the agent and answers with its pane's id. See `SessionModel.startAgent`.
  @ObservationIgnored private let start: @MainActor (AgentLaunch) async throws -> String
  /// Opens a pane on the host, and takes the sheet down.
  @ObservationIgnored private let open: @MainActor (String) -> Void
  /// The folder browser's runner, resolved per listing. See `FolderBrowserModel`.
  @ObservationIgnored let runner: @MainActor () -> CommandRunner?

  init(
    hostName: String,
    recentFolders: [String],
    start: @escaping @MainActor (AgentLaunch) async throws -> String,
    open: @escaping @MainActor (String) -> Void,
    runner: @escaping @MainActor () -> CommandRunner?
  ) {
    self.hostName = hostName
    self.recentFolders = recentFolders
    self.start = start
    self.open = open
    self.runner = runner
  }

  var isStarting: Bool { phase == .starting }

  /// Whether Start can be tapped now.
  var canStart: Bool { form.canStart && !isStarting }

  /// Starts the agent the form describes, then opens its pane. A failure stays on the sheet.
  func startAgent() async {
    guard canStart, let launch = form.launch else { return }
    phase = .starting
    do {
      let id = try await start(launch)
      phase = .editing
      open(id)
    } catch let error as AppError {
      phase = .failed(error)
    } catch {
      phase = .failed(.herdrCommandFailed(reason: "The agent could not be started."))
    }
  }

  /// The pane a start opened and the agent did not come up in, which the sheet offers to open.
  var paneLeftOpen: (id: String, place: String)? {
    guard case .failed(.agentDidNotStart(let id, let place, _)) = phase else { return nil }
    return (id, place)
  }

  /// Opens `paneLeftOpen`.
  func openPaneLeftOpen() {
    if let paneLeftOpen { open(paneLeftOpen.id) }
  }

  /// A folder picked in the browser or from the recent list.
  func use(folder: String) {
    form.directory = folder
  }
}

/// One folder's listing, for the browser inside the New Agent sheet.
@MainActor
@Observable
final class FolderBrowserModel {
  enum State: Equatable {
    case loading
    case loaded(DirectoryListing)
    case failed(AppError)
  }

  /// The path as asked for: typed, picked, or a listed folder's child. Empty means home.
  let path: String
  let hostName: String
  private(set) var state: State = .loading

  @ObservationIgnored private let runner: @MainActor () -> CommandRunner?

  init(path: String, hostName: String, runner: @escaping @MainActor () -> CommandRunner?) {
    self.path = path
    self.hostName = hostName
    self.runner = runner
  }

  /// Lists the folder, once. A listing the screen cancelled by leaving is asked again on return.
  func load() async {
    if case .loaded = state { return }
    guard let run = runner() else {
      state = .failed(.notConnected(host: hostName))
      return
    }
    state = .loading
    do {
      let listing = try await DirectoryListing.read(path, run: run)
      state = .loaded(listing)
    } catch {
      // Left by a push or a pop before the answer: the next appearance asks again.
      if Task.isCancelled { return }
      state = .failed(
        (error as? AppError) ?? .herdrCommandFailed(reason: "The folder could not be read."))
    }
  }
}

/// A folder to browse, pushed on the sheet's own stack.
struct FolderRoute: Hashable {
  let path: String
}

/// Start Claude Code or Codex in a folder on the host, with an optional first message.
///
/// Presented by `ContentView`'s root, because its entries are on the host screen, which is the
/// iPad's detail column, where nothing may present. Everything it needs comes in through the
/// model, so no environment value has to reach it across the presentation.
///
/// The folder browser is a push on the sheet's own `NavigationStack`, not a second sheet. See
/// CLAUDE.md, "Never present from inside a presentation".
struct NewAgentSheet: View {
  @State var model: NewAgentModel
  @State private var browsePath: [FolderRoute] = []

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeAccent) private var themeAccent

  var body: some View {
    NavigationStack(path: $browsePath) {
      Form {
        agentSection
        folderSection
        if !model.recentFolders.isEmpty { recentSection }
        promptSection
        startSection
      }
      .navigationTitle("New Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(model.isStarting)
            // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
            .tint(Color.primary)
            .accessibilityIdentifier("newAgent.cancel")
        }
      }
      .navigationDestination(for: FolderRoute.self) { route in
        FolderBrowserView(
          model: FolderBrowserModel(path: route.path, hostName: model.hostName, runner: model.runner)
        ) { folder in
          model.use(folder: folder)
          browsePath.removeAll()
        }
      }
    }
    // A start cannot be taken back, so the sheet stays until it answers.
    .interactiveDismissDisabled(model.isStarting)
  }

  private var agentSection: some View {
    Section {
      Picker("Agent", selection: $model.form.kind) {
        ForEach(AgentLaunch.Kind.allCases, id: \.self) { kind in
          Text(kind.displayName).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("newAgent.kind")
    } header: {
      Text("Agent")
    }
    .disabled(model.isStarting)
  }

  private var folderSection: some View {
    Section {
      TextField("Folder", text: $model.form.directory, prompt: Text(verbatim: "~/projects/app"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(.none)
        .accessibilityIdentifier("newAgent.folder")
      NavigationLink(value: FolderRoute(path: model.form.trimmedDirectory)) {
        Label("Browse Folders", systemImage: "folder")
      }
      .accessibilityIdentifier("newAgent.browse")
    } header: {
      Text("Folder")
    } footer: {
      Text("The agent starts in a new workspace named after the folder.")
    }
    .disabled(model.isStarting)
  }

  private var recentSection: some View {
    Section {
      ForEach(model.recentFolders, id: \.self) { folder in
        Button {
          model.use(folder: folder)
        } label: {
          HStack {
            Text(folder)
              .foregroundStyle(Color.primary)
              .lineLimit(1)
              .truncationMode(.head)
            Spacer()
            if model.form.trimmedDirectory == folder {
              Image(systemName: "checkmark")
                .foregroundStyle(themeAccent)
                .fontWeight(.semibold)
            }
          }
        }
        .accessibilityAddTraits(model.form.trimmedDirectory == folder ? .isSelected : [])
        .accessibilityIdentifier("newAgent.recent")
      }
    } header: {
      Text("Folders Open on \(model.hostName)")
    }
    .disabled(model.isStarting)
  }

  private var promptSection: some View {
    Section {
      TextField("Optional", text: $model.form.prompt, axis: .vertical)
        .lineLimit(3...8)
        .accessibilityIdentifier("newAgent.prompt")
    } header: {
      Text("First Message")
    } footer: {
      if model.form.isPromptTooLong {
        RowProblemLabel(
          AppError.agentPromptTooLong.errorDescription ?? "The first message is too long.",
          systemImage: "exclamationmark.triangle"
        )
        .accessibilityIdentifier("newAgent.promptTooLong")
      } else {
        Text("Sent as the agent starts. Line breaks become spaces.")
      }
    }
    .disabled(model.isStarting)
  }

  private var startSection: some View {
    Section {
      Button {
        Task { await model.startAgent() }
      } label: {
        HStack {
          Spacer()
          if model.isStarting {
            ProgressView()
              .accessibilityIdentifier("newAgent.starting")
          } else {
            ProminentButtonLabel("Start \(model.form.kind.displayName)")
          }
          Spacer()
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!model.canStart)
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
      .accessibilityIdentifier("newAgent.start")

      if case .failed(let error) = model.phase {
        RowProblemLabel(
          error.errorDescription ?? "The agent could not be started.",
          systemImage: "xmark.octagon"
        )
        .accessibilityIdentifier("newAgent.error")
        if let pane = model.paneLeftOpen {
          Button {
            model.openPaneLeftOpen()
          } label: {
            Label("Open \(pane.place)", systemImage: "terminal")
          }
          .accessibilityIdentifier("newAgent.openPane")
        }
      }
    } footer: {
      Text(
        "Starting can take several seconds. If \(model.form.kind.displayName) is not installed on \(model.hostName), the new pane shows the shell’s error."
      )
    }
  }
}

/// One folder's sub-folders, pushed inside the New Agent sheet. A row goes one level down, and
/// Use Folder hands this folder back to the form.
struct FolderBrowserView: View {
  @State var model: FolderBrowserModel
  let onUse: (String) -> Void

  var body: some View {
    List {
      switch model.state {
      case .loading:
        HStack {
          ProgressView()
          Text("Reading the folder…")
        }
        .accessibilityIdentifier("newAgent.browser.loading")
      case .failed(let error):
        RowProblemLabel(
          error.errorDescription ?? "The folder could not be read.",
          systemImage: "exclamationmark.triangle"
        )
        .accessibilityIdentifier("newAgent.browser.error")
      case .loaded(let listing):
        Section {
          if listing.names.isEmpty {
            Text("No folders inside.")
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("newAgent.browser.empty")
          }
          ForEach(listing.names, id: \.self) { name in
            NavigationLink(value: FolderRoute(path: listing.childPath(name))) {
              Label(name, systemImage: "folder")
            }
            .accessibilityIdentifier("newAgent.browser.folder")
          }
        } header: {
          Text(verbatim: listing.path)
            .textCase(nil)
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityIdentifier("newAgent.browser.path")
        } footer: {
          if listing.isTruncated {
            Text(
              "Showing the first \(DirectoryListing.entryLimit) folders. Type a path on the form to reach the others."
            )
            .accessibilityIdentifier("newAgent.browser.truncated")
          }
        }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Use Folder") {
          if case .loaded(let listing) = model.state { onUse(listing.path) }
        }
        .disabled(!isLoaded)
        // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
        .tint(Color.primary)
        .accessibilityIdentifier("newAgent.browser.use")
      }
    }
    .task { await model.load() }
  }

  private var isLoaded: Bool {
    if case .loaded = model.state { return true }
    return false
  }

  /// The folder's own name once it is known, and the home folder's name before.
  private var title: String {
    if case .loaded(let listing) = model.state { return AgentLaunch.folderName(of: listing.path) }
    return model.path.isEmpty || model.path == "~" ? "Home" : AgentLaunch.folderName(of: model.path)
  }
}
