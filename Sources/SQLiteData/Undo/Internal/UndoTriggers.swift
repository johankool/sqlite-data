import Foundation
import GRDB

// MARK: - Column info

/// Reads writable column names for `tableName`.
///
/// Prefer `pragma_table_xinfo` so hidden/generated columns can be filtered with `hidden = 0`.
/// Fall back to `pragma_table_info` on older SQLite builds where `table_xinfo` is unavailable.
package func undoColumnNames(for tableName: String, in db: Database) throws -> [String] {
  // Use pragma table-valued functions.  The table name is embedded as a quoted
  // SQL identifier, not as a bound parameter, because some SQLite versions do not support bound
  // parameters in table-valued-function arguments.
  let tableLiteral = "'" + tableName.replacingOccurrences(of: "'", with: "''") + "'"
  do {
    return try String.fetchAll(
      db,
      sql: """
        SELECT name FROM pragma_table_xinfo(\(tableLiteral))
        WHERE hidden = 0
        ORDER BY cid
        """
    )
  } catch {
    return try String.fetchAll(
      db,
      sql: """
        SELECT name FROM pragma_table_info(\(tableLiteral))
        ORDER BY cid
        """
    )
  }
}

// MARK: - Undo log table

/// The DDL that creates the per-connection temporary undo log table.
package let undoLogTableSQL = """
  CREATE TEMP TABLE IF NOT EXISTS "sqlitedata_undo_log" (
    "seq" INTEGER PRIMARY KEY AUTOINCREMENT,
    "sql" TEXT NOT NULL
  )
  """

// MARK: - Trigger SQL

/// Generates the three undo triggers for a single table.
///
/// - Parameters:
///   - tableName: The name of the user table to observe.
///   - columns: The writable column names obtained from `undoColumnNames(for:in:)`.
/// - Returns: Three `CREATE TEMP TRIGGER` statements (insert, update, delete).
package func undoTriggerSQL(for tableName: String, columns: [String]) -> [String] {
  let qt: String = undoDoubleQuotedIdentifier(tableName)
  let logTable = "\"sqlitedata_undo_log\""
  let whenClause = "WHEN sqlitedata_undo_shouldRecord()"
  let triggerPrefix = "_sqlitedata_undo_"

  // INSERT → log a DELETE that removes the new row
  let insertTrigger = """
    CREATE TEMP TRIGGER \(undoDoubleQuotedIdentifier("\(triggerPrefix)insert_\(tableName)"))
    AFTER INSERT ON \(qt)
    \(whenClause)
    BEGIN
      INSERT INTO \(logTable) VALUES(
        NULL,
        'DELETE FROM \(qt) WHERE rowid='||NEW.rowid
      );
    END
    """

  // UPDATE → log an UPDATE that restores all old column values
  // Only fire when at least one column actually changed.
  let changedCondition: String = columns
    .map { col -> String in
      let qc: String = undoDoubleQuotedIdentifier(col)
      return "OLD.\(qc) IS NOT NEW.\(qc)"
    }
    .joined(separator: " OR ")
  let setClause: String = columns
    .map { col -> String in
      let qc: String = undoDoubleQuotedIdentifier(col)
      return "\(qc)='||quote(OLD.\(qc))||'"
    }
    .joined(separator: ",")
  let updateTrigger = """
    CREATE TEMP TRIGGER \(undoDoubleQuotedIdentifier("\(triggerPrefix)update_\(tableName)"))
    AFTER UPDATE ON \(qt)
    WHEN \(whenClause.dropFirst("WHEN ".count)) AND (\(changedCondition))
    BEGIN
      INSERT INTO \(logTable) VALUES(
        NULL,
        'UPDATE \(qt) SET \(setClause) WHERE rowid='||OLD.rowid
      );
    END
    """

  // DELETE → log an INSERT that restores the deleted row
  let colList: String = columns.map { undoDoubleQuotedIdentifier($0) }.joined(separator: ",")
  let valList: String = columns
    .map { col -> String in "'||quote(OLD.\(undoDoubleQuotedIdentifier(col)))||'" }
    .joined(separator: ",")
  let deleteTrigger = """
    CREATE TEMP TRIGGER \(undoDoubleQuotedIdentifier("\(triggerPrefix)delete_\(tableName)"))
    BEFORE DELETE ON \(qt)
    \(whenClause)
    BEGIN
      INSERT INTO \(logTable) VALUES(
        NULL,
        'INSERT INTO \(qt)(rowid,\(colList)) VALUES('||OLD.rowid||',\(valList))'
      );
    END
    """

  return [insertTrigger, updateTrigger, deleteTrigger]
}

/// Drop SQL for the three undo triggers of a table.
package func undoTriggerDropSQL(for tableName: String) -> [String] {
  let prefix = "_sqlitedata_undo_"
  return ["insert", "update", "delete"].map { kind in
    "DROP TEMP TRIGGER IF EXISTS \(undoDoubleQuotedIdentifier("\(prefix)\(kind)_\(tableName)"))"
  }
}

// MARK: - Helpers

private func undoDoubleQuotedIdentifier(_ identifier: String) -> String {
  "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
