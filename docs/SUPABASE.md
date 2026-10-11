# Optional Supabase synchronization

TrackStudy works offline without an account. To synchronize your own Windows and Android installations, configure a Supabase project and sign in with the same email/password account on both devices.

## Database setup

On a new project, run these migrations in order through Supabase's SQL Editor:

1. [001_initial.sql](../supabase/migrations/001_initial.sql)
2. [002_sync.sql](../supabase/migrations/002_sync.sql)
3. [003_causal_sync.sql](../supabase/migrations/003_causal_sync.sql)
4. [004_schedule_and_events.sql](../supabase/migrations/004_schedule_and_events.sql)
5. [005_journal_answers_schedule_description.sql](../supabase/migrations/005_journal_answers_schedule_description.sql)

For an existing project, apply only missing migrations. Do not rerun applied migrations or remove existing tables. The current client requires all five; tab reordering needs no additional SQL migration.

Enable email/password authentication and create your user in Supabase Authentication. For a manually created personal account, confirm the user as part of that setup. TrackStudy has no registration screen; public sign-ups can be disabled for a personal project. See Supabase's [password authentication documentation](https://supabase.com/docs/guides/auth/passwords).

## Client configuration

Copy `.env.example` to `.env.local` at the project root and set:

```dotenv
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_YOUR_PUBLIC_KEY
```

Keep `.env.local` out of Git. The run/build helpers include only these public client values; never use a service-role key, secret key, database password, or authentication token. Rebuild the app after changing configuration. Without these values, the app operates locally.

Open **Settings → Sync → Sign in**. On a new device, sign in before entering independent data to adopt the existing cloud dataset. If both installations already contain edits, review the first-sync choice rather than assuming one dataset can be discarded. TrackStudy writes a local safety backup before the first authenticated merge.

## Privacy and behavior

- All eight private tables enforce per-user RLS. The merge RPC runs with the caller's privileges and authenticated ownership; cross-account references are constrained. Keep these protections enabled even though the publishable client key is public.
- Records save to SQLite immediately. Pending edits survive restarts and retry after network failures. Changes merge by UUID and causal history; genuine concurrent conflicts retain recovery copies. Repeated synchronization does not create a new entry for an existing UUID.
- Local data binds to its account/project. Sign-out removes the saved session but retains local records and pending changes. Use a separate OS profile/device for a separate account.
- Session credentials use platform secure storage. SQLite databases and JSON backups are not encrypted; keep them private. Backups do not contain authentication tokens.
- Tab order, tab visibility, theme, and Windows background/startup preferences remain local. Android can suspend synchronization until the app resumes.
- Restore is not a command to erase cloud history. Cloud records missing from a restored backup can return on a later sync.
- Explicit Windows `--data-dir` test/demo launches disable cloud sign-in and sync, keeping fixtures separate from a saved account.

After setup, compare records on both devices and confirm that pending changes clear. A missing-migration error keeps local work pending: apply the missing SQL and retry **Sync now**.

## Local policy checks

```powershell
npm install --prefix .tools/sql-test --no-audit --no-fund @electric-sql/pglite@0.5.8
node tool/test-supabase.mjs
```

The harness applies all migrations in an isolated PostgreSQL runtime and tests ownership, anonymous access, cross-user writes/references, conflicts, and idempotency. It does not connect to or verify the configuration of a live Supabase project.
