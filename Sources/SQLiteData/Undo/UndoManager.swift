import ConcurrencyExtras
import Foundation
import GRDB
import Perception
#if canImport(Observation)
  import Observation
#endif
import StructuredQueriesCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Tracks changes made to a SQLite database and lets you undo and redo them.
///
/// Create an `UndoManager` after the database is open, supplying the table names whose changes
/// you want to track.  The manager installs lightweight SQLite triggers that record inverse SQL
/// statements into a temporary log table.
///
/// ```swift
/// let undoManager = try UndoManager(
///   for: database,
///   tableNames: ["reminders", "remindersTags"],
///   deviceID: UIDevice.current.identifierForVendor?.uuidString ?? ""
/// )
///
/// // Record a named group of changes
/// try await undoManager.withGroup("Add reminder") { db in
///   try Reminder.insert { Reminder.Draft(title: "Buy milk") }.execute(db)
/// }
///
/// // Undo the most-recent group
/// try await undoManager.undo()
/// ```
///
/// ## CloudKit sync compatibility
///
/// Changes written by a `SyncEngine` can be recorded as undo groups, including synced-origin
/// metadata.
public final class UndoManager: Perceptible, @unchecked Sendable {
  private final class WeakUndoManager: @unchecked Sendable {
    weak var value: UndoManager?
    init(_ value: UndoManager) {
      self.value = value
    }
  }

  private static let _managersByID = LockIsolated([ObjectIdentifier: WeakUndoManager]())
  package static let syncDeviceID = "sqlitedata-sync"

  // MARK: - Internal state

  private struct State {
    var undoEntries: [UndoEntry] = []
    var redoEntries: [UndoEntry] = []
    /// The next `seq` value that will begin a new undo group.
    var firstLog: Int = 1
    /// The first log sequence captured by the outermost freeze.
    var freezePoint: Int = -1
    /// Nesting count for `freeze()`/`unfreeze()`.
    var freezeDepth: Int = 0
  }

  private let _state = LockIsolated(State())
  private let database: any DatabaseWriter
  private let databaseID: ObjectIdentifier
  private let deviceID: String
  private let userRecordName: @Sendable () -> String?
  private let delegate: (any UndoManagerDelegate)?

  // MARK: - Observable conformance (Perception)

  private let _$perceptionRegistrar = PerceptionRegistrar()

  nonisolated public func access<Member>(
    keyPath: KeyPath<UndoManager, Member>
  ) {
    _$perceptionRegistrar.access(self, keyPath: keyPath)
  }

  nonisolated public func withMutation<Member, T>(
    keyPath: KeyPath<UndoManager, Member>,
    _ mutation: () throws -> T
  ) rethrows -> T {
    try _$perceptionRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
  }

  // MARK: - Observable state

  /// The groups that can be undone, most-recent-first.
  public var undoStack: [UndoGroup] {
    _$perceptionRegistrar.access(self, keyPath: \.undoStack)
    return _state.value.undoEntries.reversed().map(\.group)
  }

  /// The groups that can be redone, most-recent-first.
  public var redoStack: [UndoGroup] {
    _$perceptionRegistrar.access(self, keyPath: \.redoStack)
    return _state.value.redoEntries.reversed().map(\.group)
  }

  /// Whether there is at least one group that can be undone.
  public var canUndo: Bool { !undoStack.isEmpty }

  /// Whether there is at least one group that can be redone.
  public var canRedo: Bool { !redoStack.isEmpty }

  // MARK: - Init

  /// Creates an undo manager and installs undo triggers on the database.
  ///
  /// The triggers and the temporary log table are created immediately on the writer connection.
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - tableNames: The names of the tables whose changes should be undoable.
  ///   - deviceID: An identifier for this device shown in ``UndoGroup/deviceID``.
  ///     Defaults to the system device identifier.
  ///   - userRecordName: A closure returning the current user's iCloud record name, or `nil`.
  ///   - delegate: An optional delegate that can intercept and confirm undo/redo operations.
  public init(
    for database: any DatabaseWriter,
    tableNames: [String],
    deviceID: String = UndoManager.defaultDeviceID,
    userRecordName: @Sendable @escaping () -> String? = { nil },
    delegate: (any UndoManagerDelegate)? = nil
  ) throws {
    self.database = database
    self.databaseID = ObjectIdentifier(database as AnyObject)
    self.deviceID = deviceID
    self.userRecordName = userRecordName
    self.delegate = delegate

    // One-time setup on the writer connection: register the custom function,
    // create the temp log table, and install triggers for each observed table.
    try database.write { db in
      db.add(function: $_shouldRecord)

      try db.execute(sql: undoLogTableSQL)

      for tableName in tableNames {
        let columns = try undoColumnNames(for: tableName, in: db)
        guard !columns.isEmpty else { continue }
        for sql in undoTriggerSQL(for: tableName, columns: columns) {
          try db.execute(sql: sql)
        }
      }
    }

    Self._managersByID.withValue {
      $0[self.databaseID] = WeakUndoManager(self)
    }
  }

  deinit {
    Self._managersByID.withValue {
      if $0[self.databaseID]?.value === self {
        $0.removeValue(forKey: self.databaseID)
      }
    }
  }

  package static func manager(for database: any DatabaseWriter) -> UndoManager? {
    _managersByID.withValue {
      $0 = $0.filter { $0.value.value != nil }
      return $0[ObjectIdentifier(database as AnyObject)]?.value
    }
  }

  // MARK: - Static helpers

  /// A device identifier suitable for use with ``init(for:tableNames:deviceID:userRecordName:delegate:)``.
  ///
  /// On iOS this is `UIDevice.identifierForVendor`; on macOS it is the machine's host name.
  public static var defaultDeviceID: String {
    #if canImport(UIKit)
      return UIDevice.current.identifierForVendor?.uuidString ?? ProcessInfo.processInfo.hostName
    #else
      return ProcessInfo.processInfo.hostName
    #endif
  }

  // MARK: - Group recording

  /// Performs `body` inside a database write transaction and records all changes as a named
  /// undo group.
  ///
  /// If `body` makes no changes (or triggers are suppressed because recording is frozen), no
  /// undo entry is added.
  ///
  /// Calling this method clears the redo stack.
  ///
  /// - Parameters:
  ///   - description: A human-readable label for the change, e.g. `"Delete reminder"`.
  ///   - body: A closure that performs database writes.  Receives a `Database` connection.
  /// - Returns: The value returned by `body`.
  @discardableResult
  public func withGroup<T: Sendable>(
    _ description: String,
    deviceID: String? = nil,
    userRecordName: String? = nil,
    _ body: @Sendable (Database) throws -> T
  ) async throws -> T {
    let firstLog = _state.value.firstLog

    let result = try await database.write { db in
      try body(db)
    }

    // Determine whether any new rows were inserted into the log.
    let maxSeq = try await database.write { db in
      try UndoLog.order { $0.seq.desc() }.fetchOne(db)?.seq ?? 0
    }

    guard maxSeq >= firstLog else {
      // No new entries; the write was a no-op or recording is suppressed.
      return result
    }

    let group = UndoGroup(
      description: description,
      deviceID: deviceID ?? self.deviceID,
      userRecordName: userRecordName ?? self.userRecordName(),
      date: Date()
    )
    let entry = UndoEntry(begin: firstLog, end: maxSeq, group: group)

    _$perceptionRegistrar.withMutation(of: self, keyPath: \.undoStack) {
      _$perceptionRegistrar.withMutation(of: self, keyPath: \.redoStack) {
        _state.withValue {
          guard $0.freezePoint < 0 else { return }
          $0.undoEntries.append(entry)
          $0.redoEntries = []
          $0.firstLog = maxSeq + 1
        }
      }
    }

    return result
  }

  /// Synchronous variant of ``withGroup(_:deviceID:userRecordName:_:)``.
  @discardableResult
  public func withGroup<T>(
    _ description: String,
    deviceID: String? = nil,
    userRecordName: String? = nil,
    _ body: (Database) throws -> T
  ) throws -> T {
    let firstLog = _state.value.firstLog

    let result = try database.write { db in
      try body(db)
    }

    let maxSeq = try database.write { db in
      try UndoLog.order { $0.seq.desc() }.fetchOne(db)?.seq ?? 0
    }

    guard maxSeq >= firstLog else {
      return result
    }

    let group = UndoGroup(
      description: description,
      deviceID: deviceID ?? self.deviceID,
      userRecordName: userRecordName ?? self.userRecordName(),
      date: Date()
    )
    let entry = UndoEntry(begin: firstLog, end: maxSeq, group: group)

    _$perceptionRegistrar.withMutation(of: self, keyPath: \.undoStack) {
      _$perceptionRegistrar.withMutation(of: self, keyPath: \.redoStack) {
        _state.withValue {
          guard $0.freezePoint < 0 else { return }
          $0.undoEntries.append(entry)
          $0.redoEntries = []
          $0.firstLog = maxSeq + 1
        }
      }
    }

    return result
  }

  // MARK: - Undo / Redo

  /// Reverts the most-recently-recorded undo group.
  ///
  /// The delegate (if any) is called before the operation is performed so that you can present a
  /// confirmation prompt.
  public func undo() async throws {
    try await perform(.undo)
  }

  /// Re-applies the most-recently-undone group.
  ///
  /// The delegate (if any) is called before the operation is performed so that you can present a
  /// confirmation prompt.
  public func redo() async throws {
    try await perform(.redo)
  }

  // MARK: - Freeze / Unfreeze

  /// Suspends undo recording.
  ///
  /// Changes made while recording is frozen are not added to the undo stack.  Call ``unfreeze()``
  /// to resume recording.  Calls to ``freeze()`` and ``unfreeze()`` may be nested.
  public func freeze() async throws {
    try await database.write { _ in
      self._state.withValue { state in
        if state.freezeDepth == 0 {
          state.freezePoint = state.firstLog
        }
        state.freezeDepth += 1
      }
    }
  }

  /// Resumes undo recording after a call to ``freeze()``.
  ///
  /// Any log entries written while frozen are discarded, and ``firstLog`` is advanced past them.
  public func unfreeze() async throws {
    let shouldFinalizeFreeze = _state.withValue { state in
      guard state.freezeDepth > 0 else { return false }
      state.freezeDepth -= 1
      return state.freezeDepth == 0
    }
    guard shouldFinalizeFreeze else { return }

    let maxSeq = try await database.write { db in
      try UndoLog.order { $0.seq.desc() }.fetchOne(db)?.seq ?? 0
    }
    _state.withValue { state in
      guard state.freezeDepth == 0, state.freezePoint >= 0 else { return }
      state.firstLog = maxSeq + 1
      state.freezePoint = -1
    }
  }

  // MARK: - Private helpers

  private func perform(_ action: UndoAction) async throws {
    // Peek at the entry to pass to the delegate.
    let entry: UndoEntry? = _state.withValue { state in
      switch action {
      case .undo: return state.undoEntries.last
      case .redo: return state.redoEntries.last
      }
    }
    guard let entry else { return }

    let performAction: @Sendable () async throws -> Void = { [weak self] in
      guard let self else { return }
      try await self.applyInverse(of: entry, action: action)
    }

    if let delegate {
      try await delegate.undoManager(self, willPerform: action, for: entry.group, performAction: performAction)
    } else {
      try await performAction()
    }
  }

  private func applyInverse(of entry: UndoEntry, action: UndoAction) async throws {
    let firstLog = _state.value.firstLog

    // Execute inverse SQL inside a write transaction.
    // Triggers must run so that inverse-of-inverse statements are recorded for the opposite stack.
    try await database.write { db in
      // Fetch inverse SQL rows in reverse order (highest seq first = undo in LIFO order).
      let rows = try UndoLog
        .where { $0.seq >= entry.begin && $0.seq <= entry.end }
        .order { $0.seq.desc() }
        .fetchAll(db)

      // Remove these rows from the log before executing so re-entrant calls don't see them.
      try UndoLog
        .where { $0.seq >= entry.begin && $0.seq <= entry.end }
        .delete()
        .execute(db)

      // Execute each inverse SQL statement in order.
      for row in rows {
        try db.execute(sql: row.sql)
      }
    }

    // The triggers fired during `applyInverse` will have added new rows to the log.
    let newEnd = try await database.write { db in
      try UndoLog.order { $0.seq.desc() }.fetchOne(db)?.seq ?? 0
    }

    let newEntry = UndoEntry(begin: firstLog, end: newEnd, group: entry.group)

    _$perceptionRegistrar.withMutation(of: self, keyPath: \.undoStack) {
      _$perceptionRegistrar.withMutation(of: self, keyPath: \.redoStack) {
        _state.withValue { state in
          switch action {
          case .undo:
            state.undoEntries.removeLast()
            if newEnd >= firstLog {
              state.redoEntries.append(newEntry)
            }
          case .redo:
            state.redoEntries.removeLast()
            if newEnd >= firstLog {
              state.undoEntries.append(newEntry)
            }
          }
          state.firstLog = newEnd + 1
        }
      }
    }
  }
}

#if canImport(Observation)
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension UndoManager: Observable {}
#endif
