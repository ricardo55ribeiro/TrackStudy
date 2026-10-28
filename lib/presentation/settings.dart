import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_controller.dart';
import '../platform/json_files.dart';
import 'sync_settings.dart';
import 'common.dart';
import '../platform/windows_background.dart';
import '../application/sync_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(studyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  pageInset(context, desktop: 28),
                  0,
                  pageInset(context, desktop: 28),
                  0,
                ),
                sliver: SliverList.list(
                  children: [
                    const SectionTitle('Appearance'),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final mode in ThemeMode.values)
                          ChoiceChip(
                            label: Text(switch (mode) {
                              ThemeMode.system => 'System',
                              ThemeMode.light => 'Light',
                              ThemeMode.dark => 'Dark',
                            }),
                            selected: c.theme == mode,
                            onSelected: (_) => c.setTheme(mode),
                          ),
                      ],
                    ),
                    const SectionTitle('Tabs on this device'),
                    const Text(
                      'Drag the handles to reorder. Hidden tabs keep their position and data. The first enabled tab opens at startup.',
                    ),
                  ],
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: pageInset(context, desktop: 28),
                ),
                sliver: const TabOrderSettings(),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  pageInset(context, desktop: 28),
                  0,
                  pageInset(context, desktop: 28),
                  40,
                ),
                sliver: SliverList.list(
                  children: [
                    if (Theme.of(context).platform ==
                        TargetPlatform.windows) ...[
                      const SectionTitle('Windows'),
                      _backgroundSettings(ref),
                    ],
                    const SectionTitle('Week'),
                    const Text(
                      'Monday at 00:00 · system timezone\nWeeks follow your local calendar, including daylight-saving changes.',
                    ),
                    const SectionTitle('Data'),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        OutlinedButton(
                          onPressed: () => _export(context, ref),
                          child: const Text('Export JSON'),
                        ),
                        OutlinedButton(
                          onPressed: () => _restore(context, ref),
                          child: const Text('Restore backup'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Local database',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      c.repository.location,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Export includes categories, weeks, undone entries, journal entries, reviews, schedules, academic events, to-do topics, tasks and local preferences. Windows startup and background settings stay on this device. Restoring creates a safety backup first.',
                    ),
                    const SectionTitle('Sync'),
                    const SyncSettings(),
                    if (c.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Text(
                          c.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _backgroundSettings(WidgetRef ref) {
    final background = ref.watch(backgroundProvider),
        sync = ref.read(syncProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Run in background'),
          subtitle: const Text(
            'Closing the window keeps TrackStudy in the system tray. Use Quit to exit.',
          ),
          value: background.background,
          onChanged: background.busy
              ? null
              : (value) => background.configure(sync, run: value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Start with Windows'),
          subtitle: const Text(
            'Start at sign-in. Opens quietly in the tray when background mode is on.',
          ),
          value: background.startup,
          onChanged: background.busy
              ? null
              : (value) => background.configure(sync, start: value),
        ),
        if (background.error != null) Text(background.error!),
      ],
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final data = ref.read(repositoryProvider).exportJson();
      final saved = await saveJsonFile(
        data,
        'trackstudy-${DateTime.now().toIso8601String().substring(0, 10)}.json',
      );
      if (saved) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Backup exported.')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        showFailure(context, e);
      }
    }
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'TrackStudy backup',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
        ],
      );
      if (file == null || !context.mounted) {
        return;
      }
      final data = await file.readAsString();
      if (!context.mounted ||
          !await confirm(
            context,
            'Restore this backup?',
            'This replaces local data with the selected backup. Backups containing to-do data also delete topics and tasks absent from that backup on your synced devices. Older backups leave to-do data unchanged. A safety copy of your current data will be saved beside the database.',
            action: 'Restore',
          )) {
        return;
      }
      final c = ref.read(studyProvider);
      final backup =
          '${c.repository.location}.before-restore-${DateTime.now().millisecondsSinceEpoch}.json';
      await File(backup).writeAsString(c.repository.exportJson(), flush: true);
      if (c.perform(() => c.repository.restoreJson(data)) && context.mounted) {
        // Recreate screen state so open review drafts cannot overwrite restored data.
        ref.invalidate(studyProvider);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup restored. Safety copy: $backup')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showFailure(context, e);
      }
    }
  }
}

class TabOrderSettings extends ConsumerWidget {
  const TabOrderSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(studyProvider);
    final tabs = c.tabOrder;
    return SliverReorderableList(
      itemCount: tabs.length,
      proxyDecorator: (child, index, animation) => _dragProxy(context, child),
      onReorderItem: c.reorderTab,
      itemBuilder: (context, i) => Row(
        key: ValueKey('tab-order-${tabs[i].name}'),
        children: [
          Expanded(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tabs[i].label),
              value: c.tabVisible(tabs[i]),
              onChanged: (value) {
                if (!c.setTabVisible(tabs[i], value)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        c.error ?? 'Keep at least one tab enabled.',
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          _OrderHandle(id: 'tab-drag-${tabs[i].name}', index: i),
        ],
      ),
    );
  }
}

Widget _dragProxy(BuildContext context, Widget child) => Material(
  elevation: 6,
  color: Theme.of(context).colorScheme.surfaceContainer,
  child: child,
);

class _OrderHandle extends StatelessWidget {
  final String id;
  final int index;
  const _OrderHandle({required this.id, required this.index});

  @override
  Widget build(BuildContext context) {
    final touch = Theme.of(context).platform == TargetPlatform.android;
    const handle = SizedBox(
      width: 48,
      height: 48,
      child: Icon(Icons.drag_handle, size: 22),
    );
    return Tooltip(
      message: touch ? 'Hold and drag to reorder' : 'Drag to reorder',
      child: touch
          ? ReorderableDelayedDragStartListener(
              key: ValueKey(id),
              index: index,
              child: handle,
            )
          : ReorderableDragStartListener(
              key: ValueKey(id),
              index: index,
              child: const MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: handle,
              ),
            ),
    );
  }
}
