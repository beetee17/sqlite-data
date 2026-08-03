#if canImport(CloudKit)
  public import CloudKit
  import CustomDump
  import IssueReporting

  /// An interface for observing ``SyncEngine`` events and customizing ``SyncEngine`` behavior.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// An event indicating a change to the device's iCloud account.
    ///
    /// By default, a sync engine will clear out local data when detecting a logout or account
    /// change. To override this behavior, _e.g._ if you want to prompt the user and let them decide
    /// if they want to clear their local data or not, implement this method, and explicitly call
    /// ``SyncEngine/deleteLocalData()`` if/when the data should be cleared.
    ///
    /// For example, an observable model could override this method to set up some alert state:
    ///
    /// ```swift
    /// @MainActor
    /// @Observable
    /// class MySyncEngineDelegate: SyncEngineDelegate {
    ///   var isResetDataAlertPresented = false
    ///
    ///   func syncEngine(
    ///     _ syncEngine: SyncEngine,
    ///     accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ///   ) {
    ///     switch changeType {
    ///     case .signOut, .switchAccounts:
    ///       isResetDataAlertPresented = true
    ///     case .signIn:
    ///       break
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// And then SwiftUI could drive an alert with this state:
    ///
    /// ```swift
    /// struct MyApp: App {
    ///   @State var syncEngineDelegate = MySyncEngineDelegate()
    ///
    ///   init() {
    ///     prepareDependencies {
    ///       try! $0.bootstrapDatabase(syncEngineDelegate: syncEngineDelegate)
    ///     }
    ///   }
    ///
    ///   var body: some Scene {
    ///     WindowGroup {
    ///       MyRootView()
    ///         .alert(
    ///           "Reset local data?",
    ///           isPresented: $syncEngineDelegate.isDeleteLocalDataAlertPresented
    ///         ) {
    ///           Button("Reset", role: .destructive) {
    ///             Task {
    ///               try await syncEngine.deleteLocalData()
    ///             }
    ///           }
    ///         } message: {
    ///           Text(
    ///             """
    ///             You are no longer logged into iCloud. Would you like to reset your local data \
    ///             to the defaults? This will not affect your data in iCloud.
    ///             """
    ///           )
    ///         }
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that generates the event.
    ///   - changeType: The iCloud account's change type.
    func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async

    /// The engine's current sync activity, reported as it changes.
    ///
    /// `CKSyncEngine` completes a full fetch pass across every zone in the
    /// database before it sends anything. On an account carrying many zones
    /// that pass can run for minutes, during which nothing observable moves:
    /// `isSynchronizing` is merely `true`, and no record has been accepted by
    /// the server yet, so an app showing upload progress is pinned at zero
    /// with nothing to say about why.
    ///
    /// This reports the phase, and during the fetch a zone count — the
    /// denominator arrives with `fetchedDatabaseChanges`, which enumerates
    /// the zones about to be fetched — so an app can distinguish "preparing"
    /// from "stuck" and show real movement.
    ///
    /// Called on every transition. The default implementation does nothing.
    func syncEngine(
      _ syncEngine: SyncEngine,
      syncActivityChanged activity: SyncEngine.SyncActivity
    ) async
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// What the engine is doing right now, for progress reporting.
    public enum SyncActivity: Equatable, Sendable {
      case idle
      /// Enumerating which zones have changes; no denominator yet.
      case fetchingDatabaseChanges
      /// Fetching per-zone changes. `total` is the zone count reported by
      /// `fetchedDatabaseChanges`; `completed` counts those finished.
      case fetchingZoneChanges(completed: Int, total: Int)
      case sendingChanges

      /// 0...1 where a denominator exists, else nil.
      public var fractionCompleted: Double? {
        guard case .fetchingZoneChanges(let completed, let total) = self, total > 0
        else { return nil }
        return min(1, Double(completed) / Double(total))
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngineDelegate {
    public func syncEngine(
      _ syncEngine: SyncEngine,
      syncActivityChanged activity: SyncEngine.SyncActivity
    ) async {}

    public func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      switch changeType {
      case .signOut, .switchAccounts:
        await withErrorReporting {
          try await syncEngine.deleteLocalData()
        }
      case .signIn:
        break
      @unknown default:
        break
      }
    }
  }
#endif
