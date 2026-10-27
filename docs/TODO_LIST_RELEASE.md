# TrackStudy 1.4.0+7

## To-Do List

The sixth configurable tab appears immediately after Progress Bars by default. Upgrades insert it after Progress Bars in the saved full order without changing other tabs' visibility or relative order. Order and visibility remain device-local. Hiding To-Do List leaves all topics and tasks intact.

Windows keeps horizontal navigation and Android keeps the drawer. Both use the existing themes with bold topic titles, clear checkboxes, wrapping text and compact action menus. Add Topic stays at the bottom outside the scrolling content. Each topic has an Add Task action at the right of its header and an independently collapsible Finished Tasks section.

Clicking or tapping a topic title opens its existing rename and delete menu. Clicking or tapping active or finished task text opens its edit and delete menu. Delete actions retain their confirmation dialogs. There are no three-dot buttons. Active task text is draggable without a handle: immediate mouse dragging on Windows and long-press dragging on Android. Checkbox and task-text hit areas are separate. Reordering stays within the task's topic. Finished tasks cannot be dragged.

Checking a task immediately saves its UTC completion timestamp. An independent five-second UI timer keeps it checked in its current active position. Unchecking during that period reverses completion without changing its position. Timer expiry only changes placement and never writes to the database. Remote state changes and deletion cancel obsolete timers. Leaving the screen or restarting retains the durable completion, with finished sections collapsed when the screen opens.

Finished tasks show checked boxes, smaller muted text and strikethrough. They sort by completion timestamp descending with ID as a deterministic tie-breaker. Unchecking restores the same task immediately at the end of its topic's active order. Completing it again assigns a fresh timestamp.

## Persistence and synchronization

SQLite schema 7 adds `todo_topics` and `todo_tasks` transactionally. Existing tables, sessions, preferences and sync metadata are preserved. UUIDs identify records and explicit integer positions determine topic and active task order, with IDs breaking ties. Completion derives from nullable `completed_at`.

The existing SQLite triggers, dirty queue, sync controller and causal merge RPC handle both new tables. Edits and ordering use the existing causal history and deterministic version/writer conflict resolution. Conflicting losing content is retained in conflict copies. Deletion is permanent for a given to-do UUID and wins over concurrent edits. A deleted topic hides its children and causes late offline children to be tombstoned, preventing resurrection.

Backup format 5 includes topics, tasks, ordering, completion and deletion timestamps. Formats 2, 3 and 4 remain importable and preserve existing to-do data. Restore validates a candidate database before changing the current one and the UI saves a safety backup. Restoring previously deleted to-do data assigns new IDs to the recovered records while retaining the original tombstones. Restoring a format 5 backup removes to-do records absent from that snapshot through synchronized tombstones.

## Apply the cloud migration manually

No live Supabase schema changes are made by the application or release tooling.

Migration file: `supabase/migrations/006_todo_list.sql`

1. Open the intended Supabase project and choose **SQL Editor**.
2. Confirm migrations 001 through 005 have already been applied. For a new project, apply them in numerical order first.
3. Create a new query. Copy the complete contents of `006_todo_list.sql`, including `begin;` and `commit;`, into the editor.
4. Run the query once. Do not remove existing tables or rerun already applied migrations.
5. Run the verification queries below in a new query.
6. Open Settings > Sync in each updated app and select **Sync now**, or allow automatic synchronization to retry.

Apply the migration **before installing the updated apps when possible**. It is not required to install or use the feature locally. If the apps are updated first, the missing cloud schema pauses synchronization, shows an error in Settings > Sync and retains all local changes for retry. Existing older clients remain compatible with the additive cloud migration.

```sql
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('todo_topics', 'todo_tasks');

select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('todo_topics', 'todo_tasks')
order by tablename, policyname;

select conrelid::regclass as table_name, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid in ('public.todo_topics'::regclass, 'public.todo_tasks'::regclass)
  and contype = 'f';

select to_regprocedure('public.trackstudy_merge(text,jsonb)') as merge_function,
       to_regprocedure('public.trackstudy_todo_guard()') as deletion_guard;
```

Expect two tables with RLS enabled, three authenticated policies per table (`own_select`, `own_insert` and `own_update`), ownership foreign keys and a composite task-to-topic foreign key covering `topic_id` and `user_id`. Both function names should be non-null. No DELETE policy is created.

## Install the update

Windows: export a JSON backup, quit TrackStudy through the tray if background mode is enabled and extract the entire portable ZIP into the application folder. Run `trackstudy.exe`. Keep the DLLs and `data` directory alongside it. The user database is stored separately. Do not replace the application while it is running.

Android: export a JSON backup, copy the signed APK to the phone and open it to install an update. Do not uninstall the existing app or clear its storage. The package remains `dev.trackstudy.trackstudy` and the original release signing key is reused.

## Validation

Validated on 27 October 2026:

| Check | Result |
| --- | --- |
| Dart formatting | Clean, 55 files checked |
| Flutter analyzer | No issues |
| Full Flutter suite | 131 tests passed |
| Theme and layout captures | Windows and Android light/dark views inspected |
| Local PostgreSQL | All six migrations and 224 merge, ownership, RLS and deletion checks passed |
| SQLite | Schema 6 to 7 preservation, file restart and backup compatibility passed |
| Windows native integration | Passed, including task interactions, persistence, tray restore, close and startup mode |
| Android native integration | Both tests passed on the dedicated emulator, including secure storage, native SQLite, task interactions and simulated cross-device synchronization |
| Windows release | 1.4.0+7 executable and portable ZIP built; isolated release startup, schema 7 creation and clean quit passed |
| Android signed release | 1.4.0+7 APK built; original package ID and signing certificate verified |
| Android upgrade | Final APK installed over 1.3.1+6 without uninstalling; the existing Research progress entry remained 1.5 / 8 h |

Release artifacts in this workspace:

- Windows executable: `dist/TrackStudy-Release/trackstudy.exe`
- Windows portable ZIP: `dist/TrackStudy-windows-x64.zip`
- Android signed APK: `dist/TrackStudy-android-release.apk`
- SHA-256 artifact checksums: `dist/TrackStudy-1.4.0-SHA256.txt`

The updated Windows bundle is in `dist/TrackStudy-Release`. Its executable, DLLs, shortcut helpers and data folder retain the existing portable layout. Quit the running app through its tray menu before opening the new executable or replacing the old bundle.

Android package ID: `dev.trackstudy.trackstudy`. The original keystore is unchanged. The old and new APKs have the same signing certificate SHA-256:

```text
ee5921a52d25b2afa8815a6a8ed64391d15d17c6d1a5507608e45b2dc22ff6a7
```

Live Supabase synchronization and physical Android hardware were not tested. Local PostgreSQL tests and simulated clients do not constitute a live cloud test. Apply the migration manually and complete the Windows-to-Android acceptance scenario with your account. No live schema changes, commits or pushes were made.
