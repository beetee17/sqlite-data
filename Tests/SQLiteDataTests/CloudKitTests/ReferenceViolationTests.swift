#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import CustomDump
  import InlineSnapshotTesting
  import SQLiteData
  import SQLiteDataTestSupport
  import SnapshotTestingCustomDump
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    final class ReferenceViolationTests: BaseCloudKitTests, @unchecked Sendable {
      // * Local client moves a reminder to a list.
      // * At same time, remote deletes that list.
      // => When data is synchronized the reminder and list are deleted.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func moveReminderToList_RemoteDeletesList() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            RemindersList(id: 2, title: "Business")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let modifications = try syncEngine.modifyRecords(
          scope: .private,
          deleting: [RemindersList.recordID(for: 2)]
        )
        try withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.remindersListID = 2 }.execute(db)
          }
        }

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        await modifications.notify()
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(Reminder.find(1).fetchCount(db) == 0)
          try #expect(RemindersList.find(2).fetchCount(db) == 0)
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        try await userDatabase.read { db in
          try #expect(Reminder.count().fetchOne(db) == 0)
          try #expect(
            RemindersList.all.fetchAll(db) == [
              RemindersList(id: 1, title: "Personal")
            ]
          )
        }
      }

      // * Local client deletes a list
      // * At the same time, remote adds a reminder to that list.
      // * Local data is sync'd first, then remote data syncs.
      // => Deletion is rejected and the list and reminder are sync'd to local client.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteList_RemoteAddsReminderToList() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).delete().execute(db)
          }
        }
        let modifications = try withDependencies {
          $0.currentTime.now += 2
        } operation: {
          let reminderRecord = CKRecord(
            recordType: Reminder.tableName,
            recordID: Reminder.recordID(for: 1)
          )
          reminderRecord.setValue(1, forKey: "id", at: now)
          reminderRecord.setValue("Get milk", forKey: "title", at: now)
          reminderRecord.setValue(1, forKey: "remindersListID", at: now)
          reminderRecord.parent = CKRecord.Reference(
            recordID: RemindersList.recordID(for: 1),
            action: .none
          )
          return try syncEngine.modifyRecords(scope: .private, saving: [reminderRecord])
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        await modifications.notify()

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:reminders/zone/__defaultOwner__),
                  recordType: "reminders",
                  parent: CKReference(recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__)),
                  share: nil,
                  id: 1,
                  remindersListID: 1,
                  title: "Get milk"
                ),
                [1]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [Reminder(id: 1, title: "Get milk", remindersListID: 1)]
          )
          try #expect(
            RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Personal")]
          )
        }
      }

      // * Local client deletes a list
      // * At the same time, remote adds a reminder to that list.
      // * Remote data is sync'd first, then local data syncs.
      // => Deletion is rejected and the list and reminder are sync'd to local client.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteList_RemoteAddsReminderToList_Variation() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).delete().execute(db)
          }
        }
        let modifications = try withDependencies {
          $0.currentTime.now += 2
        } operation: {
          let reminderRecord = CKRecord(
            recordType: Reminder.tableName,
            recordID: Reminder.recordID(for: 1)
          )
          reminderRecord.setValue(1, forKey: "id", at: now)
          reminderRecord.setValue("Get milk", forKey: "title", at: now)
          reminderRecord.setValue(1, forKey: "remindersListID", at: now)
          reminderRecord.parent = CKRecord.Reference(
            recordID: RemindersList.recordID(for: 1),
            action: .none
          )
          return try syncEngine.modifyRecords(scope: .private, saving: [reminderRecord])
        }
        await modifications.notify()
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:reminders/zone/__defaultOwner__),
                  recordType: "reminders",
                  parent: CKReference(recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__)),
                  share: nil,
                  id: 1,
                  remindersListID: 1,
                  title: "Get milk"
                ),
                [1]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [Reminder(id: 1, title: "Get milk", remindersListID: 1)]
          )
          try #expect(
            RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Personal")]
          )
        }
      }

      // * Local client move child to parent.
      // * Remote client deletes parent.
      // * Local data is sync'd first, then remote data syncs.
      // => Local client sets parent relationship to NULL and parent is deleted.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func moveChildToParent_RemoteDeletesParent_CascadeSetNull() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Parent(id: 1)
            Parent(id: 2)
            ChildWithOnDeleteSetNull(id: 1, parentID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let modifications = try syncEngine.modifyRecords(
          scope: .private,
          deleting: [Parent.recordID(for: 2)]
        )
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try ChildWithOnDeleteSetNull.find(1).update { $0.parentID = #bind(2) }.execute(db)
          }
        }
        try await withDependencies {
          $0.currentTime.now += 2
        } operation: {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
          await modifications.notify()
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)

          assertInlineSnapshot(of: container, as: .customDump) {
            """
            MockCloudContainer(
              privateCloudDatabase: MockCloudDatabase(
                databaseScope: .private,
                storage: [
                  [0]: CKRecord(
                    recordID: CKRecord.ID(1:childWithOnDeleteSetNulls/zone/__defaultOwner__),
                    recordType: "childWithOnDeleteSetNulls",
                    parent: nil,
                    share: nil,
                    id: 1
                  ),
                  [1]: CKRecord(
                    recordID: CKRecord.ID(1:parents/zone/__defaultOwner__),
                    recordType: "parents",
                    parent: nil,
                    share: nil,
                    id: 1
                  )
                ]
              ),
              sharedCloudDatabase: MockCloudDatabase(
                databaseScope: .shared,
                storage: []
              )
            )
            """
          }
          assertQuery(ChildWithOnDeleteSetNull.all, database: userDatabase.database) {
            """
            ┌───────────────────────────┐
            │ ChildWithOnDeleteSetNull( │
            │   id: 1,                  │
            │   parentID: nil           │
            │ )                         │
            └───────────────────────────┘
            """
          }
          assertQuery(Parent.all, database: userDatabase.database) {
            """
            ┌───────────────┐
            │ Parent(id: 1) │
            └───────────────┘
            """
          }
        }
      }

      // * Local client move child to parent.
      // * Remote client deletes parent.
      // * Local data is sync'd first, then remote data syncs.
      // => Local client sets parent relationship to default value.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func moveChildToParent_RemoteDeletesParent_CascadeSetDefault() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Parent(id: 0)
            Parent(id: 1)
            Parent(id: 2)
            ChildWithOnDeleteSetDefault(id: 1, parentID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let modifications = try syncEngine.modifyRecords(
          scope: .private,
          deleting: [Parent.recordID(for: 2)]
        )
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try ChildWithOnDeleteSetDefault.find(1).update { $0.parentID = 2 }.execute(db)
          }
        }
        try await withDependencies {
          $0.currentTime.now += 2
        } operation: {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
          await modifications.notify()
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)

          assertInlineSnapshot(of: container, as: .customDump) {
            """
            MockCloudContainer(
              privateCloudDatabase: MockCloudDatabase(
                databaseScope: .private,
                storage: [
                  [0]: CKRecord(
                    recordID: CKRecord.ID(1:childWithOnDeleteSetDefaults/zone/__defaultOwner__),
                    recordType: "childWithOnDeleteSetDefaults",
                    parent: CKReference(recordID: CKRecord.ID(0:parents/zone/__defaultOwner__)),
                    share: nil,
                    id: 1,
                    parentID: 0
                  ),
                  [1]: CKRecord(
                    recordID: CKRecord.ID(0:parents/zone/__defaultOwner__),
                    recordType: "parents",
                    parent: nil,
                    share: nil,
                    id: 0
                  ),
                  [2]: CKRecord(
                    recordID: CKRecord.ID(1:parents/zone/__defaultOwner__),
                    recordType: "parents",
                    parent: nil,
                    share: nil,
                    id: 1
                  )
                ]
              ),
              sharedCloudDatabase: MockCloudDatabase(
                databaseScope: .shared,
                storage: []
              )
            )
            """
          }
          try await userDatabase.read { db in
            try #expect(
              ChildWithOnDeleteSetDefault.all.fetchAll(db) == [
                ChildWithOnDeleteSetDefault(id: 1, parentID: 0)
              ]
            )
            try #expect(
              Parent.all.fetchAll(db) == [Parent(id: 0), Parent(id: 1)]
            )
          }
        }
      }

      // A reference violation for a parent that has NEVER been uploaded is an
      // upload-ordering problem, not a remote deletion. The child must
      // survive, and both records must be re-queued so a later batch settles
      // the ordering.
      //
      // Any bulk insert produces this — thousands of records queue at once
      // with no ordering guarantee between parents and children — and
      // deleting the child destroys data the user still has.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      // * A bulk insert sends a parent and its child in one batch.
      // * CloudKit processes the child first and rejects it, then saves the
      //   parent — returning both outcomes in a single response.
      // => The child must survive and be retried, not cascade-deleted.
      //
      // This is the shape the mock cannot produce on its own:
      // `MockCloudDatabase` treats "the parent is in the same batch" as *no*
      // violation, and the engine sorts each batch root-first, so a same-batch
      // parent always lands before its child. Real CloudKit makes no such
      // promise — a batch has no internal ordering guarantee.
      //
      // So the response is delivered directly. That is the whole point: this
      // exact response is what a real migration produced, and the sibling test
      // below (which holds the parent out of the batch entirely) passes with
      // or without the fix, because it exercises the other shape.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func referenceViolation_ParentSavedInSameBatch_KeepsChildAndRetries() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        // Both land, so the parent has a last-known server record — the
        // precondition that made the guard answer "uploaded, then deleted".
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let listRecordID = RemindersList.recordID(for: 1)
        let reminderRecordID = Reminder.recordID(for: 1)
        let engine = syncEngine.syncEngine(for: .private)
        let records = engine.database.state.withValue { state in
          (
            list: state.storage[listRecordID.zoneID]?.records[listRecordID],
            reminder: state.storage[reminderRecordID.zoneID]?.records[reminderRecordID]
          )
        }
        let listRecord = try #require(records.list)
        let reminderRecord = try #require(records.reminder)

        await engine.parentSyncEngine.handleEvent(
          .sentRecordZoneChanges(
            savedRecords: [listRecord],
            failedRecordSaves: [
              (record: reminderRecord, error: CKError(.referenceViolation))
            ],
            deletedRecordIDs: [],
            failedRecordDeletes: [:]
          ),
          syncEngine: engine
        )

        // Before the fix the parent's freshly-written server record — written
        // by this very callback, one loop earlier — made the child look like a
        // remote deletion, and it was cascade-deleted here.
        try await userDatabase.read { db in
          try #expect(Reminder.find(1).fetchCount(db) == 1)
          try #expect(RemindersList.find(1).fetchCount(db) == 1)
        }

        // Both records were re-queued rather than resolved destructively.
        // Draining settles them, and leaves the pending set empty for the
        // base class's teardown check — which is itself a second assertion
        // that the re-queue happened at all.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [
              Reminder(id: 1, title: "Get milk", remindersListID: 1)
            ]
          )
          try #expect(
            RemindersList.all.fetchAll(db) == [
              RemindersList(id: 1, title: "Personal")
            ]
          )
        }
      }

      // The second same-batch shape, and the one that survived the first fix.
      //
      // CloudKit fails a batch as a unit: when one record in the request
      // errors, the rest come back `operationCancelled`. So a parent can be
      // in the same response as its rejected child and be in
      // `failedRecordSaves` rather than `savedRecords` — emphatically not on
      // the server, which is exactly why the child violated. Checking only
      // `savedRecords` misses it and falls through to the destructive branch:
      // 86 children deleted on a real migration, every parent merely
      // cancelled.
      //
      // The parent is synced first here so it has a last-known server record.
      // That is what makes the test bite: without the fix the same-batch check
      // misses, `parentWasEverUploaded` answers `true`, and the child is
      // deleted as a remote deletion.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func referenceViolation_ParentCancelledInSameBatch_KeepsChildAndRetries()
        async throws
      {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let listRecordID = RemindersList.recordID(for: 1)
        let reminderRecordID = Reminder.recordID(for: 1)
        let engine = syncEngine.syncEngine(for: .private)
        let records = engine.database.state.withValue { state in
          (
            list: state.storage[listRecordID.zoneID]?.records[listRecordID],
            reminder: state.storage[reminderRecordID.zoneID]?.records[reminderRecordID]
          )
        }
        let listRecord = try #require(records.list)
        let reminderRecord = try #require(records.reminder)

        await engine.parentSyncEngine.handleEvent(
          .sentRecordZoneChanges(
            savedRecords: [],
            failedRecordSaves: [
              (record: reminderRecord, error: CKError(.referenceViolation)),
              (record: listRecord, error: CKError(.operationCancelled)),
            ],
            deletedRecordIDs: [],
            failedRecordDeletes: [:]
          ),
          syncEngine: engine
        )

        try await userDatabase.read { db in
          try #expect(Reminder.find(1).fetchCount(db) == 1)
          try #expect(RemindersList.find(1).fetchCount(db) == 1)
        }

        // Both were re-queued by the child's branch — note that
        // `operationCancelled` re-queues nothing on its own, so the parent
        // getting back in line is entirely the guard's doing.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [
              Reminder(id: 1, title: "Get milk", remindersListID: 1)
            ]
          )
          try #expect(
            RemindersList.all.fetchAll(db) == [
              RemindersList(id: 1, title: "Personal")
            ]
          )
        }
      }

      // The cross-batch shape, and the one that survived both earlier fixes.
      //
      // The parent is queued in one batch and the child violates in a later
      // one, so the same-batch check cannot see the parent at all and the
      // discriminator is asked. It answered "uploaded" — because building a
      // record for sending calls `refreshLastKnownServerRecord` on it, so the
      // metadata gets a `lastKnownServerRecord` at *queue* time, before the
      // server has seen anything. 22 sub-todos deleted on a real migration
      // while their parents sat waiting to upload.
      //
      // Hence `wasAcceptedByServer`: only CloudKit issues a change tag, so a
      // locally-built record has none no matter what else is populated.
      //
      // Building the batch and discarding it is exactly what production did —
      // there the send came back `operationCancelled`, which re-queues nothing
      // and leaves the stamped metadata behind.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func referenceViolation_ParentQueuedButNeverAccepted_KeepsChild() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }

        let engine = syncEngine.syncEngine(for: .private)
        let batch = try #require(
          await engine.parentSyncEngine.nextRecordZoneChangeBatch(syncEngine: engine)
        )
        let reminderRecord = try #require(
          batch.recordsToSave.first { $0.recordID == Reminder.recordID(for: 1) }
        )

        // Nothing was sent: the server is still empty, yet the parent's
        // metadata has now been stamped by the act of queueing it.
        #expect(
          engine.database.state.withValue { $0.storage.values.allSatisfy { $0.records.isEmpty } }
        )

        // The parent is absent from this response — it was cancelled in the
        // earlier batch — so only the discriminator can save the child.
        await engine.parentSyncEngine.handleEvent(
          .sentRecordZoneChanges(
            savedRecords: [],
            failedRecordSaves: [
              (record: reminderRecord, error: CKError(.referenceViolation))
            ],
            deletedRecordIDs: [],
            failedRecordDeletes: [:]
          ),
          syncEngine: engine
        )

        try await userDatabase.read { db in
          try #expect(Reminder.find(1).fetchCount(db) == 1)
          try #expect(RemindersList.find(1).fetchCount(db) == 1)
        }

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [
              Reminder(id: 1, title: "Get milk", remindersListID: 1)
            ]
          )
          try #expect(
            RemindersList.all.fetchAll(db) == [
              RemindersList(id: 1, title: "Personal")
            ]
          )
        }
      }

      @Test func referenceViolation_ParentNeverUploaded_KeepsChildAndRetries() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }

        // Hold the parent back so the child is sent on its own — what the
        // engine does naturally when a bulk insert spans several batches.
        syncEngine.private.state.remove(
          pendingRecordZoneChanges: [.saveRecord(RemindersList.recordID(for: 1))]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // The child survived. Before this behavior existed it was
        // cascade-deleted right here, while its parent sat waiting to upload.
        try await userDatabase.read { db in
          try #expect(Reminder.find(1).fetchCount(db) == 1)
          try #expect(RemindersList.find(1).fetchCount(db) == 1)
        }

        // Draining the re-queued changes uploads the parent and lands the
        // child behind it.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [
              Reminder(id: 1, title: "Get milk", remindersListID: 1)
            ]
          )
          try #expect(
            RemindersList.all.fetchAll(db) == [
              RemindersList(id: 1, title: "Personal")
            ]
          )
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:reminders/zone/__defaultOwner__),
                  recordType: "reminders",
                  parent: CKReference(recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__)),
                  share: nil,
                  id: 1,
                  isCompleted: 0,
                  remindersListID: 1,
                  title: "Get milk"
                ),
                [1]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
      }
    }
  }
#endif
