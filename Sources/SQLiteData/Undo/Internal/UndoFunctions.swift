import StructuredQueriesCore

/// A task-local flag set to `true` while the undo manager is executing inverse SQL so that
/// the undo triggers do not record the inverse operations as new undo entries.
@TaskLocal package var _isUndoingOrRedoing = false

/// A SQLite scalar function registered on every database connection managed by ``UndoManager``.
///
/// Triggers use `WHEN sqlitedata_undo_shouldRecord()` to decide whether to record an inverse
/// SQL statement.  Returns `false` during undo/redo replay.
@DatabaseFunction("sqlitedata_undo_shouldRecord")
package func _shouldRecord() -> Bool {
  if _isUndoingOrRedoing { return false }
  return true
}
