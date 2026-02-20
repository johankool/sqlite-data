import Foundation
import SQLiteData
import Testing

// MARK: - Schema

@Table private struct Item: Equatable, Identifiable {
  let id: Int
  var title: String
}

// MARK: - Database helpers

extension DatabaseWriter where Self == DatabaseQueue {
  fileprivate static func undoDatabase(tableNames: [String] = ["items"]) throws -> DatabaseQueue {
    let database = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create items") { db in
      try #sql(
        """
        CREATE TABLE "items" (
          "id" INTEGER PRIMARY KEY AUTOINCREMENT,
          "title" TEXT NOT NULL DEFAULT ''
        )
        """
      )
      .execute(db)
    }
    try migrator.migrate(database)
    return database
  }
}

// MARK: - Tests

@Suite struct UndoManagerTests {

  // 1. Basic undo removes the inserted row and leaves canUndo false.
  @Test func basicUndo() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.withGroup("Insert") { db in
      _ = try Item.insert { Item.Draft(title: "Hello") }.execute(db)
    }
    #expect(undoManager.canUndo)
    #expect(undoManager.undoStack.count == 1)

    try await undoManager.undo()

    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.isEmpty)
    #expect(!undoManager.canUndo)
    #expect(undoManager.undoStack.isEmpty)
  }

  // 2. After undo, redo restores the row and leaves canRedo false.
  @Test func basicRedo() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.withGroup("Insert") { db in
      _ = try Item.insert { Item.Draft(title: "Hello") }.execute(db)
    }
    try await undoManager.undo()
    #expect(undoManager.canRedo)

    try await undoManager.redo()

    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.count == 1)
    #expect(items[0].title == "Hello")
    #expect(!undoManager.canRedo)
    #expect(undoManager.redoStack.isEmpty)
  }

  // 3. Two inserts in one withGroup are undone together.
  @Test func undoGroup() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.withGroup("Batch insert") { db in
      _ = try Item.insert { Item.Draft(title: "A") }.execute(db)
      _ = try Item.insert { Item.Draft(title: "B") }.execute(db)
    }
    #expect(undoManager.undoStack.count == 1)

    try await undoManager.undo()

    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.isEmpty)
  }

  // 4. Separate groups produce separate undo entries; undoing removes only the last one.
  @Test func multipleGroups() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.withGroup("Insert A") { db in
      _ = try Item.insert { Item.Draft(title: "A") }.execute(db)
    }
    try await undoManager.withGroup("Insert B") { db in
      _ = try Item.insert { Item.Draft(title: "B") }.execute(db)
    }
    #expect(undoManager.undoStack.count == 2)

    try await undoManager.undo()

    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.count == 1)
    #expect(items[0].title == "A")
    #expect(undoManager.undoStack.count == 1)
  }

  // 5. Writes performed while _isSynchronizingChanges is true are not recorded.
  @Test func syncExcluded() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    // Simulate a sync-engine write by setting the TaskLocal directly.
    try await $_isSynchronizingChanges.withValue(true) {
      try await db.write { db in
        _ = try Item.insert { Item.Draft(title: "Sync item") }.execute(db)
      }
    }

    #expect(!undoManager.canUndo)
    #expect(undoManager.undoStack.isEmpty)

    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.count == 1)   // row IS in the database, just not undoable
  }

  // 6. Inverse SQL executed during undo is not added to the undo stack; it goes to redo.
  @Test func undoingNotRecorded() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.withGroup("Insert") { db in
      _ = try Item.insert { Item.Draft(title: "X") }.execute(db)
    }
    try await undoManager.undo()

    // Only the redo entry should exist; no additional undo entry.
    #expect(undoManager.undoStack.isEmpty)
    #expect(undoManager.redoStack.count == 1)
  }

  // 7. Changes made while frozen are not undoable.
  @Test func freeze() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.freeze()
    // Direct write (not through withGroup) so we can test the trigger suppression via freeze.
    try await db.write { db in
      _ = try Item.insert { Item.Draft(title: "Frozen") }.execute(db)
    }
    try await undoManager.unfreeze()

    #expect(!undoManager.canUndo)
    #expect(undoManager.undoStack.isEmpty)

    // The row should still be in the database.
    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.count == 1)
  }

  // 8. When the delegate does not call performAction, the undo is cancelled.
  @Test func delegateCancel() async throws {
    final class CancelDelegate: UndoManagerDelegate {
      func undoManager(
        _ undoManager: SQLiteData.UndoManager,
        willPerform action: UndoAction,
        for group: UndoGroup,
        performAction: @Sendable () async throws -> Void
      ) async throws {
        // Intentionally do NOT call performAction — cancel the undo.
      }
    }

    let db = try DatabaseQueue.undoDatabase()
    let delegate = CancelDelegate()
    let undoManager = try UndoManager(for: db, tableNames: ["items"], delegate: delegate)

    try await undoManager.withGroup("Insert") { db in
      _ = try Item.insert { Item.Draft(title: "Persistent") }.execute(db)
    }
    #expect(undoManager.undoStack.count == 1)

    try await undoManager.undo()

    // Stack unchanged; row still present.
    #expect(undoManager.undoStack.count == 1)
    let items = try await db.read { try Item.fetchAll($0) }
    #expect(items.count == 1)
  }

  // 9. The delegate receives metadata matching what was passed to withGroup.
  @Test func delegateReceivesMetadata() async throws {
    actor MetadataCapture {
      var capturedGroup: UndoGroup?
      func capture(_ group: UndoGroup) { capturedGroup = group }
    }
    let capture = MetadataCapture()

    final class MetadataDelegate: UndoManagerDelegate, @unchecked Sendable {
      let capture: MetadataCapture
      init(_ capture: MetadataCapture) { self.capture = capture }
      func undoManager(
        _ undoManager: SQLiteData.UndoManager,
        willPerform action: UndoAction,
        for group: UndoGroup,
        performAction: @Sendable () async throws -> Void
      ) async throws {
        await capture.capture(group)
        try await performAction()
      }
    }

    let db = try DatabaseQueue.undoDatabase()
    let delegate = MetadataDelegate(capture)
    let undoManager = try UndoManager(
      for: db,
      tableNames: ["items"],
      deviceID: "test-device",
      delegate: delegate
    )

    try await undoManager.withGroup("My operation") { db in
      _ = try Item.insert { Item.Draft(title: "Hi") }.execute(db)
    }
    try await undoManager.undo()

    let group = await capture.capturedGroup
    #expect(group?.description == "My operation")
    #expect(group?.deviceID == "test-device")
  }

  // 10. The delegate receives `.undo` for undo and `.redo` for redo.
  @Test func delegateActionType() async throws {
    actor ActionCapture {
      var actions: [UndoAction] = []
      func append(_ action: UndoAction) { actions.append(action) }
    }
    let capture = ActionCapture()

    final class ActionDelegate: UndoManagerDelegate, @unchecked Sendable {
      let capture: ActionCapture
      init(_ capture: ActionCapture) { self.capture = capture }
      func undoManager(
        _ undoManager: SQLiteData.UndoManager,
        willPerform action: UndoAction,
        for group: UndoGroup,
        performAction: @Sendable () async throws -> Void
      ) async throws {
        await capture.append(action)
        try await performAction()
      }
    }

    let db = try DatabaseQueue.undoDatabase()
    let delegate = ActionDelegate(capture)
    let undoManager = try UndoManager(for: db, tableNames: ["items"], delegate: delegate)

    try await undoManager.withGroup("Insert") { db in
      _ = try Item.insert { Item.Draft(title: "Z") }.execute(db)
    }
    try await undoManager.undo()
    try await undoManager.redo()

    let actions = await capture.actions
    #expect(actions == [.undo, .redo])
  }

  // 11. The description from withGroup appears in undoStack.
  @Test func undoDescriptionRoundtrip() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.withGroup("Delete all items") { db in
      _ = try Item.insert { Item.Draft(title: "Temp") }.execute(db)
    }

    #expect(undoManager.undoStack.first?.description == "Delete all items")
  }

  // 12. Nested freeze calls require matching unfreeze calls before recording resumes.
  @Test func nestedFreezeRequiresMatchingUnfreeze() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let undoManager = try UndoManager(for: db, tableNames: ["items"])

    try await undoManager.freeze()
    try await undoManager.freeze()

    try await undoManager.withGroup("Frozen A") { db in
      _ = try Item.insert { Item.Draft(title: "A") }.execute(db)
    }
    try await undoManager.unfreeze()

    try await undoManager.withGroup("Frozen B") { db in
      _ = try Item.insert { Item.Draft(title: "B") }.execute(db)
    }

    #expect(!undoManager.canUndo)

    try await undoManager.unfreeze()

    try await undoManager.withGroup("Tracked C") { db in
      _ = try Item.insert { Item.Draft(title: "C") }.execute(db)
    }
    #expect(undoManager.undoStack.count == 1)

    try await undoManager.undo()

    let titles = try await db.read { db in
      try String.fetchAll(db, sql: "SELECT title FROM items ORDER BY id")
    }
    #expect(titles == ["A", "B"])
  }

  // 13. Undo/redo round-trips updates containing SQL-sensitive quoting characters.
  @Test func updateUndoRedoQuotedText() async throws {
    let db = try DatabaseQueue.undoDatabase()
    let id = try await db.write { db in
      try db.execute(sql: #"INSERT INTO "items" ("title") VALUES (?)"#, arguments: ["Before"])
      return db.lastInsertedRowID
    }
    let undoManager = try UndoManager(for: db, tableNames: ["items"])
    let updatedTitle = #"O'Reilly "Book""#

    try await undoManager.withGroup("Quoted update") { db in
      try db.execute(
        sql: #"UPDATE "items" SET "title" = ? WHERE "id" = ?"#,
        arguments: [updatedTitle, id]
      )
    }

    let titleAfterUpdate = try await db.read { db in
      try String.fetchOne(db, sql: #"SELECT "title" FROM "items" WHERE "id" = ?"#, arguments: [id])
    }
    #expect(titleAfterUpdate == updatedTitle)

    try await undoManager.undo()
    let titleAfterUndo = try await db.read { db in
      try String.fetchOne(db, sql: #"SELECT "title" FROM "items" WHERE "id" = ?"#, arguments: [id])
    }
    #expect(titleAfterUndo == "Before")

    try await undoManager.redo()
    let titleAfterRedo = try await db.read { db in
      try String.fetchOne(db, sql: #"SELECT "title" FROM "items" WHERE "id" = ?"#, arguments: [id])
    }
    #expect(titleAfterRedo == updatedTitle)
  }

  // 14. Deleting rows with NULL values can be undone/redone correctly.
  @Test func deleteUndoRedoNullColumn() async throws {
    let db = try DatabaseQueue()
    try await db.write { db in
      try db.execute(sql: #"CREATE TABLE "notes" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "body" TEXT)"#)
    }
    let id = try await db.write { db in
      try db.execute(sql: #"INSERT INTO "notes" ("body") VALUES (NULL)"#)
      return db.lastInsertedRowID
    }
    let undoManager = try UndoManager(for: db, tableNames: ["notes"])

    try await undoManager.withGroup("Delete null row") { db in
      try db.execute(sql: #"DELETE FROM "notes" WHERE "id" = ?"#, arguments: [id])
    }

    let countAfterDelete = try await db.read { db in
      try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "notes" WHERE "id" = ?"#, arguments: [id]) ?? 0
    }
    #expect(countAfterDelete == 0)

    try await undoManager.undo()
    let countAfterUndo = try await db.read { db in
      try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "notes" WHERE "id" = ?"#, arguments: [id]) ?? 0
    }
    let restoredIsNull = try await db.read { db in
      try Int.fetchOne(
        db,
        sql: #"SELECT "body" IS NULL FROM "notes" WHERE "id" = ?"#,
        arguments: [id]
      ) ?? 0
    }
    #expect(countAfterUndo == 1)
    #expect(restoredIsNull == 1)

    try await undoManager.redo()
    let countAfterRedo = try await db.read { db in
      try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "notes" WHERE "id" = ?"#, arguments: [id]) ?? 0
    }
    #expect(countAfterRedo == 0)
  }
}
