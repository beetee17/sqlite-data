#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing

  /// The ordering that decides what goes into a record-zone batch.
  ///
  /// A real migration deadlocked here for ten launches. `scopedModels` is this
  /// schema's version of the table that caused it: no foreign key in either
  /// direction, so nothing reaches it while walking the dependency graph and
  /// it was absent from `tablesByOrder` entirely. The batch comparator then
  /// answered `true` in *both* directions for every pair involving one, which
  /// is not a strict weak ordering, and `sort(by:)` is documented to leave the
  /// whole array unspecified in that case — so 1,350 children were ordered
  /// ahead of the 76 parents they reference, every child was rejected with
  /// `referenceViolation`, and the parents were never sent at all.
  ///
  /// These assert the two properties that failure needed, separately, because
  /// they have separate fixes and either alone would have masked the other.
  extension BaseCloudKitTests {
    @MainActor
    final class TableOrderingTests: BaseCloudKitTests, @unchecked Sendable {

      // MARK: - The order map is complete

      /// Every registered table has an index — including one that neither
      /// references another table nor is referenced by one.
      ///
      /// Discriminatory: `scopedModels` is exactly that table, and before the
      /// fix the map was built by walking `tableDependencies.keys`, which it
      /// could never appear in.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func everySynchronizedTableIsOrdered() {
        let ordered = syncEngine.tablesByOrder
        #expect(
          ordered["scopedModels"] != nil,
          """
          A table with no foreign keys in either direction is missing from \
          tablesByOrder. Callers then have to invent a position for it, which \
          is what made the batch comparator non-total.
          """
        )
        for table in ["remindersLists", "reminders", "tags", "reminderTags", "scopedModels"] {
          #expect(ordered[table] != nil, "\(table) has no order")
        }
      }

      /// Completing the map must not disturb the ordering it already had:
      /// a dependency still precedes its dependents.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func dependenciesStillPrecedeDependents() throws {
        let ordered = syncEngine.tablesByOrder
        let list = try #require(ordered["remindersLists"])
        let reminder = try #require(ordered["reminders"])
        let tag = try #require(ordered["tags"])
        let reminderTag = try #require(ordered["reminderTags"])
        #expect(list < reminder)
        #expect(reminder < reminderTag)
        #expect(tag < reminderTag)
      }

      // MARK: - The comparator is a strict weak ordering

      /// Asymmetry over a table the order map does not know.
      ///
      /// This is the property that failed. Asked directly rather than through
      /// a sorted batch, because an invalid predicate makes `sort` unspecified
      /// — a batch-level assertion can pass by luck and prove nothing.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [true, false]) func unknownTableComparesAsymmetrically(
        rootFirst: Bool
      ) {
        let forward = syncEngine.topologicallyAscending(
          lhsTableName: "aTableNobodyRegistered", rhsTableName: "remindersLists",
          rootFirst: rootFirst
        )
        let backward = syncEngine.topologicallyAscending(
          lhsTableName: "remindersLists", rhsTableName: "aTableNobodyRegistered",
          rootFirst: rootFirst
        )
        #expect(
          forward != backward,
          """
          cmp(a, b) and cmp(b, a) are both \(forward) for an unknown table. \
          That is not a strict weak ordering and sort(by:) is undefined for \
          the entire batch, not just this pair.
          """
        )
      }

      /// The same, for a record name that carries no table suffix — the other
      /// way `tableName` comes back nil. Fixing the order map alone does not
      /// cover this, which is why the comparator has to be total in its own
      /// right.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [true, false]) func nilTableNameComparesAsymmetrically(
        rootFirst: Bool
      ) {
        let forward = syncEngine.topologicallyAscending(
          lhsTableName: nil, rhsTableName: "remindersLists", rootFirst: rootFirst
        )
        let backward = syncEngine.topologicallyAscending(
          lhsTableName: "remindersLists", rhsTableName: nil, rootFirst: rootFirst
        )
        #expect(forward != backward)
      }

      /// Irreflexivity: nothing precedes itself, including two unknowns.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [true, false]) func nothingPrecedesItself(rootFirst: Bool) {
        for name in ["remindersLists", "aTableNobodyRegistered"] {
          #expect(
            !syncEngine.topologicallyAscending(
              lhsTableName: name, rhsTableName: name, rootFirst: rootFirst
            ),
            "\(name) compares less than itself"
          )
        }
        #expect(
          !syncEngine.topologicallyAscending(
            lhsTableName: nil, rhsTableName: nil, rootFirst: rootFirst
          )
        )
      }

      /// Two *different* unknown tables must still order deterministically
      /// against each other. Both take the same fallback index, so without the
      /// name tie-break they would compare equal-and-both-true.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [true, false]) func twoUnknownTablesOrderDeterministically(
        rootFirst: Bool
      ) {
        let forward = syncEngine.topologicallyAscending(
          lhsTableName: "unknownA", rhsTableName: "unknownB", rootFirst: rootFirst
        )
        let backward = syncEngine.topologicallyAscending(
          lhsTableName: "unknownB", rhsTableName: "unknownA", rootFirst: rootFirst
        )
        #expect(forward != backward)
      }

      /// Transitivity across the boundary between known and unknown. An
      /// unknown table sorts last for saves; a known parent must still
      /// precede a known child, and both must precede the unknown.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func knownTablesPrecedeUnknownOnesWhenSaving() {
        let parentBeforeChild = syncEngine.topologicallyAscending(
          lhsTableName: "remindersLists", rhsTableName: "reminders", rootFirst: true
        )
        let parentBeforeUnknown = syncEngine.topologicallyAscending(
          lhsTableName: "remindersLists", rhsTableName: "aTableNobodyRegistered",
          rootFirst: true
        )
        let childBeforeUnknown = syncEngine.topologicallyAscending(
          lhsTableName: "reminders", rhsTableName: "aTableNobodyRegistered",
          rootFirst: true
        )
        #expect(parentBeforeChild)
        #expect(parentBeforeUnknown)
        #expect(childBeforeUnknown)
      }

      // MARK: - The predicate the batch actually sorts with

      /// `pendingChangeIsAscending` is the closure `nextRecordZoneChangeBatch`
      /// hands to `sort(by:)`. These assert it is a strict weak ordering over
      /// the case that broke: a pending change whose table is not in
      /// `tablesByOrder`.
      ///
      /// Asserted on the predicate rather than on a sorted batch, deliberately.
      /// A broken predicate makes `sort` *unspecified*, not wrong — verified
      /// here: with the original comparator, a fixture matching the real
      /// distribution exactly (76 parents, 1,350 children, 13 unordered, fed
      /// in children-first) still came out correctly sorted. A batch-level
      /// assertion would have passed against the code that deadlocked a real
      /// account for ten launches. This one cannot.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func batchPredicateIsAsymmetricOverAnUnorderedTable() {
        let unknown = CKSyncEngine.PendingRecordZoneChange
          .saveRecord(CKRecord.ID(recordName: "1:aTableNobodyRegistered"))
        let known = CKSyncEngine.PendingRecordZoneChange
          .saveRecord(RemindersList.recordID(for: 1))

        let forward = syncEngine.pendingChangeIsAscending(unknown, known)
        let backward = syncEngine.pendingChangeIsAscending(known, unknown)
        #expect(
          forward != backward,
          """
          The batch predicate answers \(forward) in both directions for a \
          change whose table has no order. sort(by:) is then undefined for \
          the whole batch, which is how children ended up ahead of the \
          parents they reference.
          """
        )
      }

      /// Same, for a record name with no table suffix at all.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func batchPredicateIsAsymmetricOverAnUnparseableRecordName() {
        let nameless = CKSyncEngine.PendingRecordZoneChange
          .saveRecord(CKRecord.ID(recordName: "noTableSuffixHere"))
        let known = CKSyncEngine.PendingRecordZoneChange
          .saveRecord(RemindersList.recordID(for: 1))

        #expect(
          syncEngine.pendingChangeIsAscending(nameless, known)
            != syncEngine.pendingChangeIsAscending(known, nameless)
        )
      }

      /// Irreflexive over every shape, including the ones that take fallbacks.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func batchPredicateIsIrreflexive() {
        for change: CKSyncEngine.PendingRecordZoneChange in [
          .saveRecord(RemindersList.recordID(for: 1)),
          .saveRecord(CKRecord.ID(recordName: "1:aTableNobodyRegistered")),
          .saveRecord(CKRecord.ID(recordName: "noTableSuffixHere")),
          .deleteRecord(RemindersList.recordID(for: 1)),
        ] {
          #expect(!syncEngine.pendingChangeIsAscending(change, change))
        }
      }

      /// Saves and deletes must order consistently against each other too —
      /// deletes lead, and asking the other way round must disagree.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deletesPrecedeSaves() {
        let save = CKSyncEngine.PendingRecordZoneChange
          .saveRecord(RemindersList.recordID(for: 1))
        let delete = CKSyncEngine.PendingRecordZoneChange
          .deleteRecord(Reminder.recordID(for: 1))
        #expect(syncEngine.pendingChangeIsAscending(delete, save))
        #expect(!syncEngine.pendingChangeIsAscending(save, delete))
      }

      // MARK: - End to end

      /// A smoke test over the real batch path, at the distribution that
      /// deadlocked. It passed against the broken code too — see the note on
      /// `batchPredicateIsAsymmetricOverAnUnorderedTable` — so it is here to
      /// catch a gross regression, not to prove the ordering is sound.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func batchLeadsWithParents() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            for id in 1...76 { RemindersList(id: id, title: "List \(id)") }
            for id in 1...1350 {
              Reminder(id: id, title: "Reminder \(id)", remindersListID: (id % 76) + 1)
            }
            for id in 1...13 { ScopedModel(id: id) }
          }
        }

        // Children first, then the unordered table, parents last.
        let pending = syncEngine.private.state.pendingRecordZoneChanges
        syncEngine.private.state.remove(pendingRecordZoneChanges: pending)
        func changes(_ table: String) -> [CKSyncEngine.PendingRecordZoneChange] {
          pending.filter { change in
            guard case .saveRecord(let id) = change else { return false }
            return id.tableName == table
          }
        }
        syncEngine.private.state.add(
          pendingRecordZoneChanges: changes("reminders")
            + changes("scopedModels")
            + changes("remindersLists")
        )

        let batch = try #require(
          await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        )
        let tables = batch.recordsToSave.map(\.recordType)
        let lastParent = try #require(tables.lastIndex(of: "remindersLists"))
        let firstChild = try #require(tables.firstIndex(of: "reminders"))
        #expect(
          lastParent < firstChild,
          "a child precedes a parent; head of batch: \(tables.prefix(12))"
        )
      }
    }
  }
#endif
