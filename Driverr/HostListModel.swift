import DriverrCore
import Foundation
import Observation

/// Drives the host list: load, add, edit, delete.
@MainActor
@Observable
final class HostListModel {
  private(set) var hosts: [DriverrCore.Host] = []
  private(set) var errorMessage: String?

  private let store: any HostStore
  private let knownHosts: any KnownHostsStore
  private let credentials: PasswordCredentials
  private let lastPanes: any LastPaneStore
  private let hookOffers: any HookOfferStore
  private let announcedPanes: any AnnouncedPaneStore

  /// No store has a default. A default would be an in-memory store, and a caller that left
  /// the argument out would delete a host and leave its record in the real store.
  init(
    store: any HostStore,
    knownHosts: any KnownHostsStore,
    credentials: PasswordCredentials,
    lastPanes: any LastPaneStore,
    hookOffers: any HookOfferStore,
    announcedPanes: any AnnouncedPaneStore
  ) {
    self.store = store
    self.knownHosts = knownHosts
    self.credentials = credentials
    self.lastPanes = lastPanes
    self.hookOffers = hookOffers
    self.announcedPanes = announcedPanes
  }

  func load() async {
    do {
      hosts = try await store.hosts()
      errorMessage = nil
    } catch {
      errorMessage = (error as? AppError)?.errorDescription ?? "Could not load hosts."
    }
  }

  func save(_ host: DriverrCore.Host) async {
    do {
      try await store.save(host)
      await load()
    } catch {
      errorMessage = (error as? AppError)?.errorDescription ?? "Could not save that host."
    }
  }

  /// Deletes a host and what the app kept about it: the row, its trusted key, its last-pane
  /// record, its announced panes, its hook-offer record and its password.
  ///
  /// Without that, the password stays on the device with no screen to delete it, and re-adding
  /// the hostname would inherit the old trust decision, since keys are stored by hostname.
  ///
  /// The host row goes first, because that is what the user asked for. A Keychain failure is
  /// reported, not swallowed.
  ///
  /// The trusted key is forgotten only if no remaining host has that hostname. The check
  /// reads the store again rather than `hosts`: `load()` swallows its error, so `hosts` can
  /// still hold the deleted host, which would keep its key trusted. If that read fails, the
  /// key is forgotten, because asking again is the safe side.
  func delete(_ host: DriverrCore.Host) async {
    do {
      try await store.delete(host.id)
      await load()
    } catch {
      errorMessage = (error as? AppError)?.errorDescription ?? "Could not delete that host."
      return
    }
    let remaining = (try? await store.hosts()) ?? []
    await knownHosts.forget(host, unlessUsedBy: remaining)
    // Otherwise a key per deleted host would stay in the defaults forever.
    await lastPanes.setLastPane(nil, forHost: host.id)
    // The same for the panes it was alerted about. An empty set removes the store's key. A
    // connection that is still closing can write the set once more until `disconnect()`
    // clears its session, so the key can come back for a connected host with a blocked pane.
    // The delete alert promises only the password and the host key.
    await announcedPanes.setAnnouncedPanes([], forHost: host.id)
    // So a host added again under this id is offered the hook afresh.
    for integration in AgentIntegration.catalog {
      await hookOffers.setState(nil, forHost: host.id, agent: integration.agent)
    }
    do {
      try await credentials.forget(for: host.id)
    } catch {
      errorMessage = "\(host.displayName) was removed, but its saved password could not be."
    }
  }
}
