#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    final class TopologicalTableSortingTests: BaseCloudKitTests, @unchecked Sendable {
      /// Note `scopedModels`. It has no foreign key in either direction, and
      /// this expectation used to omit it — the map was built by walking only
      /// tables that appeared as a dependency key, so nothing ever reached it.
      /// The omission was not visible as a failure anywhere; it surfaced as a
      /// batch comparator that answered `true` in both directions for any pair
      /// involving such a table, which made `sort(by:)` undefined and put
      /// children ahead of the parents they reference.
      ///
      /// Which is to say this assertion previously encoded the bug. Every
      /// registered table belongs here.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func tablesByOrder() async throws {
        #expect(
          syncEngine.tablesByOrder == [
            "remindersLists": 0,
            "reminders": 1,
            "remindersListAssets": 2,
            "tags": 3,
            "reminderTags": 4,
            "parents": 5,
            "childWithOnDeleteSetNulls": 6,
            "childWithOnDeleteSetDefaults": 7,
            "modelAs": 8,
            "modelBs": 9,
            "modelCs": 10,
            "scopedModels": 11,
            "remindersListPrivates": 12,
          ]
        )
      }
    }
  }
#endif
