# Plan: Abstract Away the SQLiteData Dependency from a Consumer SwiftUI Project

## Problem Statement

A SwiftUI project using SQLiteData for persistence becomes tightly coupled to SQLiteData-specific types throughout its codebase. The goal is to architect the consumer project so that SQLiteData is an **implementation detail** — swappable for another persistence solution (SwiftData, Core Data, plain file storage, a mock) — while preserving the power of `@FetchAll`, reactive observation, and SQL querying.

## Analysis: Where SQLiteData Couples to Consumer Code

After studying every example app (Reminders, SyncUps, CaseStudies) and their tests, here is every point where SQLiteData types appear in consumer code:

### 1. Model Definitions — `@Table`, `@Column`, `@Selection`
```swift
@Table struct Reminder: Identifiable { ... }
@Table struct RemindersList: Identifiable { ... }
@Selection struct Row { ... }
```
These macros generate StructuredQueries conformances. Every model is permanently coupled.

### 2. Property Wrappers — `@FetchAll`, `@FetchOne`, `@Fetch`
```swift
@FetchAll(Item.order(by: \.title)) var items
@FetchOne(Item.count()) var itemsCount = 0
@Fetch(MyRequest()) var data = MyRequest.Value()
```
Used in SwiftUI views, `@Observable` models, and UIKit controllers.

### 3. Query Building — StructuredQueries DSL
```swift
Reminder.where { !$0.isCompleted }.order(by: \.dueDate)
Item.group(by: \.id).leftJoin(Other.all) { $0.id.eq($1.itemID) }
ReminderText.where { $0.match(searchText) }
```
Complex query chains with joins, aggregates, FTS5, computed columns, etc.

### 4. Write Operations — `database.write { db in ... }`
```swift
@Dependency(\.defaultDatabase) var database
try database.write { db in
    try Item.insert { Item.Draft(title: "Milk") }.execute(db)
    try Item.where { $0.id.in(ids) }.delete().execute(db)
}
```
Uses `Database` (GRDB type) inside write closures.

### 5. Database Setup — `DatabaseQueue`, `DatabaseMigrator`, `Configuration`
```swift
let db = try DatabaseQueue()
var migrator = DatabaseMigrator()
migrator.registerMigration("v1") { db in
    try #sql("CREATE TABLE ...").execute(db)
}
```

### 6. Custom Fetch Requests — `FetchKeyRequest`
```swift
struct SearchRequest: FetchKeyRequest {
    func fetch(_ db: Database) throws -> Value { ... }
}
```

### 7. Dependencies — `@Dependency(\.defaultDatabase)`, `@Dependency(\.defaultSyncEngine)`

### 8. CloudKit — `SyncEngine`, `SyncMetadata`, `CloudSharingView`

## Key Insight: The Coupling is Intentional and Deep

Unlike a simple networking layer that can be hidden behind a `protocol NetworkClient`, SQLiteData's value proposition is **pervasive**: reactive property wrappers in views, type-safe query building in business logic, and raw SQL power in complex operations. The StructuredQueries DSL is the querying language itself — it's not wrapping something simpler underneath.

**You cannot fully abstract SQLiteData and keep its power.** The power IS the coupling. `@FetchAll(Item.order(by: \.title))` is simultaneously the abstraction AND the implementation.

However, you CAN architect the app to **isolate where SQLiteData appears** and provide clean boundaries for the rest of the app.

## Three Approaches Considered

### Approach A: Full Repository Pattern (Maximum Abstraction)

Hide SQLiteData entirely behind a dependency client:

```swift
// No SQLiteData imports anywhere except the implementation file
struct PersistenceClient: Sendable {
    var observeReminders: @Sendable (ReminderFilter) -> AsyncStream<[Reminder]>
    var insertReminder: @Sendable (Reminder) async throws -> Void
    var deleteReminders: @Sendable ([Reminder.ID]) async throws -> Void
    ...
}
```

**What you lose:**
- `@FetchAll` in views — replaced with `.task { for await ... }` boilerplate
- Inline query composition — complex dynamic queries become pre-designed client methods
- `FetchKeyRequest` composability — multi-query transactions become opaque client calls
- SwiftUI animation integration — `animation: .default` needs manual `withAnimation`
- Dynamic queries — `$items.load(newQuery)` becomes re-subscribing to a new stream

**What you gain:**
- Pure domain models with zero framework imports
- Full swappability to any persistence backend
- Complete testability with mock clients

### Approach B: No Abstraction (Current Pattern)

Use SQLiteData directly in views and models as the examples do.

**What you lose:** Testability without real DB, swappability

**What you gain:** Maximum ergonomics and power

### Approach C: Hybrid — Abstract Writes, Keep Reads (Recommended)

Keep `@FetchAll` and StructuredQueries for reads. Abstract only the write side through dependency clients.

## Recommended Architecture: Hybrid Approach

### Rationale

The observation/query side (`@FetchAll`, `@FetchOne`, StructuredQueries DSL) is the main value of SQLiteData. Abstracting it away defeats the purpose. But the write side (inserts, updates, deletes, complex transactions) is where business logic lives and benefits most from abstraction for testing.

The read side is inherently framework-coupled in **any** persistence solution — SwiftData's `@Query` has the same coupling — so abstracting it provides little value while sacrificing significant ergonomics.

### Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI Views                                       │
│  ┌──────────────┐  ┌─────────────────────────────┐  │
│  │ @FetchAll    │  │ model.delete(ids)            │  │
│  │ @FetchOne    │  │ model.insert(draft)          │  │
│  │ (SQLiteData) │  │ (abstracted via client)      │  │
│  └──────┬───────┘  └──────────────┬──────────────┘  │
│         │                         │                  │
├─────────┼─────────────────────────┼──────────────────┤
│  @Observable Models               │                  │
│  ┌──────┴───────┐  ┌─────────────┴──────────────┐  │
│  │ @FetchAll    │  │ @Dependency(\.reminders)    │  │
│  │ @Fetch       │  │ RemindersClient             │  │
│  │ (SQLiteData) │  │ (protocol/struct)           │  │
│  └──────────────┘  └──────────────┬──────────────┘  │
│                                   │                  │
├───────────────────────────────────┼──────────────────┤
│  Dependency Clients               │                  │
│  ┌────────────────────────────────┴──────────────┐  │
│  │ RemindersClient+Live.swift  (imports SQLiteData) │
│  │ RemindersClient+Mock.swift  (no SQLiteData)      │
│  └──────────────────────────────────────────────┘  │
│                                                      │
├──────────────────────────────────────────────────────┤
│  Database Layer (fully isolated)                     │
│  ┌──────────────────────────────────────────────┐  │
│  │ AppDatabase.swift — migrations, config        │  │
│  │ Triggers.swift — custom functions             │  │
│  │ Seed.swift — sample data                      │  │
│  └──────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

### Concrete Implementation

#### Domain Models: Keep `@Table` (lightweight coupling)

`@Table` structs are still plain value types — the macro just generates column metadata. Consumers can pass `Reminder` values around without importing SQLiteData:

```swift
// Models/Reminder.swift
import SQLiteData  // Only for @Table macro

@Table
struct Reminder: Identifiable, Hashable, Sendable {
    let id: UUID
    var title = ""
    var notes = ""
    var dueDate: Date?
    var isFlagged = false
    var status: Status = .incomplete
    var remindersListID: RemindersList.ID

    var isCompleted: Bool { status != .incomplete }

    enum Status: Int, QueryBindable { case incomplete = 0, completing = 2, completed = 1 }
    enum Priority: Int, QueryBindable { case low = 1, medium, high }
}
```

This coupling is acceptable because:
- The struct is a value type — no framework behavior attached
- Only files that BUILD queries or DEFINE models need `import SQLiteData`
- If migrating away, you just remove `@Table` and rewrite queries

#### Write Clients: Fully Abstracted

```swift
// Clients/RemindersClient.swift — NO SQLiteData import needed
import Dependencies

struct RemindersClient: Sendable {
    var insert: @Sendable (Reminder.Draft) async throws -> Void
    var upsert: @Sendable (Reminder.Draft) async throws -> Reminder.ID
    var delete: @Sendable ([Reminder.ID]) async throws -> Void
    var toggleStatus: @Sendable (Reminder.ID) async throws -> Void
    var reorder: @Sendable (_ ids: [Reminder.ID]) async throws -> Void
    var updateTags: @Sendable (Reminder.ID, [Tag]) async throws -> Void
}

extension RemindersClient: DependencyKey {
    static var liveValue: Self { .live }
    static var testValue: Self {
        Self(
            insert: unimplemented("RemindersClient.insert"),
            upsert: unimplemented("RemindersClient.upsert"),
            delete: unimplemented("RemindersClient.delete"),
            toggleStatus: unimplemented("RemindersClient.toggleStatus"),
            reorder: unimplemented("RemindersClient.reorder"),
            updateTags: unimplemented("RemindersClient.updateTags")
        )
    }
}

extension DependencyValues {
    var remindersClient: RemindersClient {
        get { self[RemindersClient.self] }
        set { self[RemindersClient.self] = newValue }
    }
}
```

```swift
// Clients/RemindersClient+Live.swift — SQLiteData implementation
import SQLiteData

extension RemindersClient {
    static var live: Self {
        @Dependency(\.defaultDatabase) var database
        return Self(
            insert: { draft in
                try await database.write { db in
                    try Reminder.insert { draft }.execute(db)
                }
            },
            upsert: { draft in
                try await database.write { db in
                    try Reminder.upsert { draft }
                        .returning(\.id)
                        .fetchOne(db)!
                }
            },
            delete: { ids in
                try await database.write { db in
                    try Reminder.where { $0.id.in(ids) }
                        .delete()
                        .execute(db)
                }
            },
            toggleStatus: { id in
                try await database.write { db in
                    try Reminder.find(id)
                        .update { $0.toggleStatus() }
                        .execute(db)
                }
            },
            reorder: { ids in
                try await database.write { db in
                    try Reminder
                        .where { $0.id.in(ids) }
                        .update {
                            let indexed = Array(ids.enumerated())
                            let (first, rest) = (indexed.first!, indexed.dropFirst())
                            $0.position = rest
                                .reduce(Case($0.id).when(first.element, then: first.offset)) { cases, id in
                                    cases.when(id.element, then: id.offset)
                                }
                                .else($0.position)
                        }
                        .execute(db)
                }
            },
            updateTags: { reminderID, tags in
                try await database.write { db in
                    try ReminderTag
                        .where { $0.reminderID.eq(reminderID) }
                        .delete()
                        .execute(db)
                    try ReminderTag.insert {
                        tags.map { ReminderTag.Draft(reminderID: reminderID, tagID: $0.id) }
                    }
                    .execute(db)
                }
            }
        )
    }
}
```

#### Observable Models: Reads via SQLiteData, Writes via Client

```swift
// Features/RemindersDetail/RemindersDetailModel.swift
import SQLiteData  // Needed for @FetchAll and query DSL

@Observable
class RemindersDetailModel {
    // READS: Direct SQLiteData — full power preserved
    @ObservationIgnored
    @FetchAll(Reminder.where { !$0.isCompleted }.order(by: \.dueDate), animation: .default)
    var reminders

    @ObservationIgnored
    @FetchOne(Reminder.count(), animation: .default)
    var count = 0

    // WRITES: Abstracted — testable without database
    @ObservationIgnored @Dependency(\.remindersClient) var client

    func delete(_ ids: [Reminder.ID]) {
        withErrorReporting {
            try await client.delete(ids)
        }
    }

    func toggleStatus(_ id: Reminder.ID) {
        withErrorReporting {
            try await client.toggleStatus(id)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        withErrorReporting {
            var ids = reminders.map(\.id)
            ids.move(fromOffsets: source, toOffset: destination)
            try await client.reorder(ids)
        }
    }
}
```

#### Tests: Mock Writes, Real Reads (or both mocked)

```swift
// Unit test — mock client, no database
@Test func deleteReminder() async throws {
    var deletedIDs: [[Reminder.ID]] = []
    let model = withDependencies {
        $0.remindersClient.delete = { ids in deletedIDs.append(ids) }
    } operation: {
        RemindersDetailModel()
    }

    await model.delete([UUID(0)])
    #expect(deletedIDs == [[UUID(0)]])
}

// Integration test — real database (like current examples)
@Test func fullFlow() async throws {
    withDependencies {
        try $0.bootstrapDatabase()
    } operation: {
        let model = RemindersDetailModel()
        try await model.$reminders.load()
        // ... test with real queries
    }
}
```

### File Structure

```
App/
├── Models/                              # @Table types
│   ├── Reminder.swift
│   ├── RemindersList.swift
│   ├── Tag.swift
│   └── Queries.swift                    # Shared query extensions (e.g., Reminder.incomplete)
│
├── Clients/                             # Write-side abstractions
│   ├── RemindersClient.swift            # Interface + DependencyKey
│   ├── RemindersClient+Live.swift       # SQLiteData write implementation
│   ├── RemindersListsClient.swift
│   ├── RemindersListsClient+Live.swift
│   ├── TagsClient.swift
│   └── TagsClient+Live.swift
│
├── Database/                            # SQLiteData infra (fully isolated)
│   ├── AppDatabase.swift                # DatabaseQueue, migrations, config
│   ├── Triggers.swift                   # Temporary triggers, custom functions
│   └── Seed.swift                       # Debug sample data
│
├── Features/                            # Views + Models
│   ├── RemindersDetail/
│   │   ├── RemindersDetailModel.swift   # @FetchAll + @Dependency(\.remindersClient)
│   │   └── RemindersDetailView.swift
│   ├── ReminderForm/
│   │   ├── ReminderFormModel.swift
│   │   └── ReminderFormView.swift
│   ├── RemindersLists/
│   │   ├── RemindersListsModel.swift
│   │   └── RemindersListsView.swift
│   └── Search/
│       ├── SearchModel.swift            # Uses @Fetch with FetchKeyRequest
│       └── SearchView.swift
│
└── App.swift                            # prepareDependencies { $0.bootstrapDatabase() }
```

## Implementation Steps

### Step 1: Create Write Clients
For each aggregate root, create a dependency client that wraps write operations. Start with `RemindersClient`, `RemindersListsClient`, `TagsClient`.

### Step 2: Implement Live Clients
Move all `database.write { ... }` logic from models/views into `*Client+Live.swift` files.

### Step 3: Refactor Observable Models
Replace `@Dependency(\.defaultDatabase) var database` + inline `database.write { ... }` calls with `@Dependency(\.remindersClient) var client` + client method calls. Keep all `@FetchAll`/`@FetchOne`/`@Fetch` usage unchanged.

### Step 4: Isolate Database Setup
Move `DatabaseQueue` creation, migrations, triggers, and `SyncEngine` config into `Database/`. Only `App.swift` references this layer.

### Step 5: Write Unit Tests
Test model business logic with mock clients. Keep integration tests for complex query validation.

### Step 6: (Optional) Shared Query Extensions
Extract reusable queries into extensions on `@Table` types in `Models/Queries.swift`:
```swift
extension Reminder {
    static let incomplete = Self.where { !$0.isCompleted }
    static let withTags = group(by: \.id)
        .leftJoin(ReminderTag.all) { $0.id.eq($1.reminderID) }
        .leftJoin(Tag.all) { $1.tagID.eq($2.primaryKey) }
}
```

## Summary

| Aspect | Before (no abstraction) | After (hybrid) |
|--------|:-:|:-:|
| `@FetchAll` in views/models | Direct | **Direct (unchanged)** |
| Query DSL (`.where`, `.order`, `.join`) | Direct | **Direct (unchanged)** |
| `FetchKeyRequest` | Direct | **Direct (unchanged)** |
| Dynamic queries (`$items.load(...)`) | Direct | **Direct (unchanged)** |
| Write operations | `database.write { ... }` inline | **`client.method()` (abstracted)** |
| Unit test writes | Needs real database | **Mock client** |
| Unit test reads | Needs real database | Needs real database (or mock via `SharedReader`) |
| Full swappability | None | **Write-side swappable** |
| Migration effort if leaving SQLiteData | Rewrite everything | **Rewrite queries + swap client implementations** |
