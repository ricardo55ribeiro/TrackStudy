# TrackStudy data and backups

## Back up or restore your data

In **Settings > Data**, check the database path, export your data as JSON or restore a backup. The app saves a safety copy beside the database before restore and validates the incoming backup before replacing local data.

SQLite databases and JSON backups are plaintext. Keep them private. Use **Export JSON** for a backup while the app is open. If you need to copy the SQLite database directly, quit the app first. [Sync and restore behaviour](SUPABASE.md#privacy-and-behavior)

TrackStudy 1.8.1 uses SQLite schema 10 and writes JSON backup format 8. It can also import formats 2 through 7. Formats 2 through 4 leave existing to-do records intact. Restoring a backup that includes to-do data can remove topics and tasks from synced devices if they are absent from the backup. Formats 2 through 5 preserve archive decisions for categories they restore. Format 8 requires an updated app for restore. Upgrading to schema 10 preserves existing schedule colours and sets existing academic events to Blue. [To-do backup and upgrade details](TODO_LIST_RELEASE.md#persistence-and-synchronization)

## Weekly goal history

Weeks start on Monday in your local calendar. Changes to category defaults apply to the current and future weeks. Earlier goals keep their saved settings.

Manage bars from **Progress Bars**. Select a bar's name to edit or archive it. Drag the name on Windows or hold and drag it on Android to reorder bars. Click or tap the total under a bar to see individual entries. **Undo** reverses the latest active entry.

Archive a bar to leave it out of the entire current week in Progress Bars and the generated Weekly Review score. The app keeps all entries and undo records. Restore a bar from **Archived Bars** to include the entire restoration week. Earlier excluded weeks stay excluded. If you archive and restore a bar in the same week, the final choice applies to that whole week.

On upgrade from a version with only global category flags, disabled categories become archived. The upgrade records a baseline for the current week. Older weeks keep their historical snapshots because the old flags have no per-week history. Later archive and restore decisions carry forward across skipped or offline weeks and sync when you connect. [Cloud migration instructions](SUPABASE.md#database-setup)

## Tab visibility

Use **Settings > Tabs on this device** to show, hide or reorder tabs. Hiding a tab preserves its position and records. Keep at least one tab visible. The app opens the first visible tab on startup. These settings stay on the device.
