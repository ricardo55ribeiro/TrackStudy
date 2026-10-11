import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../application/sync_controller.dart';
import '../platform/json_files.dart';
import 'common.dart';

class SyncSettings extends ConsumerWidget {
  const SyncSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sync.status),
        if (sync.account != null) ...[
          const SizedBox(height: 6),
          Text(sync.account!.email),
          if (sync.lastSync != null)
            Text(
              'Last sync: ${DateFormat('d MMM, HH:mm').format(sync.lastSync!)}',
            ),
          if (sync.pending > 0) Text('${sync.pending} pending changes'),
        ],
        if (sync.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(sync.error!),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (sync.account == null)
              OutlinedButton(
                onPressed: sync.canSignIn
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => const _SignInDialog(),
                      )
                    : null,
                child: const Text('Sign in'),
              )
            else ...[
              OutlinedButton(
                onPressed: sync.syncing || sync.archiving
                    ? null
                    : () => sync.sync(manual: true),
                child: const Text('Sync now'),
              ),
              TextButton(
                onPressed: () => sync.signOut(),
                child: const Text('Sign out'),
              ),
            ],
            if (sync.savedCopies > 0)
              TextButton(
                onPressed: () async {
                  try {
                    final data = sync.store!.exportConflicts();
                    await saveJsonFile(data, 'trackstudy-conflict-copies.json');
                  } catch (e) {
                    if (context.mounted) showFailure(context, e);
                  }
                },
                child: Text(
                  sync.conflicts > 0
                      ? 'Export ${sync.conflicts} saved conflict copies'
                      : 'Export archived conflict evidence',
                ),
              ),
            if (sync.conflicts > 0 && sync.account != null)
              TextButton(
                onPressed: sync.syncing || sync.archiving
                    ? null
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Archive obsolete entry copies?'),
                            content: const Text(
                              'Verify local entries against Supabase and archive only older copies written by this installation. Tracking data stays unchanged. Archived evidence is retained in exports and Supabase.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Verify and archive'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        final count = await sync.archiveVerifiedEntryCopies();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '$count verified entry copies archived.',
                              ),
                            ),
                          );
                        }
                      },
                child: const Text('Verify and archive obsolete entry copies'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          !sync.configured
              ? 'Cloud is not configured in this build. Your data stays on this device.'
              : sync.account == null
              ? 'Sign in to sync this dataset. Local tracking always works offline.'
              : 'Local changes save immediately. Signing out keeps this dataset on this device.',
        ),
      ],
    );
  }
}

class _SignInDialog extends ConsumerStatefulWidget {
  const _SignInDialog();
  @override
  ConsumerState<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends ConsumerState<_SignInDialog> {
  final email = TextEditingController(), password = TextEditingController();
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final sync = ref.read(syncProvider);
    await sync.signIn(email.text, password.text);
    if (mounted && sync.account != null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    return AlertDialog(
      title: const Text('Sign in'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => sync.authenticating ? null : submit(),
            ),
            if (sync.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(sync.error!),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: sync.authenticating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: sync.authenticating ? null : submit,
          child: Text(sync.authenticating ? 'Signing in…' : 'Sign in'),
        ),
      ],
    );
  }
}
