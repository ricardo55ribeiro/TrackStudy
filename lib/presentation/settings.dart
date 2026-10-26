import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_controller.dart';
import '../domain/models.dart';
import '../platform/json_files.dart';
import 'sync_settings.dart';
import 'common.dart';
import '../domain/planning.dart';
import '../platform/windows_background.dart';
import '../application/sync_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(studyProvider);
    final categories = c.repository.categories();
    final active = categories.where((category) => !category.archived).toList();
    final archived = categories.where((category) => category.archived).toList();
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
              if (c.tabVisible(StudyTab.week)) ...[
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: pageInset(context, desktop: 28),
                  ),
                  sliver: SliverList.list(
                    children: const [
                      SectionTitle('Categories'),
                      Text(
                        'Changes apply to this week and future weeks. Past weeks keep their original goals.',
                      ),
                      SizedBox(height: 12),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: pageInset(context, desktop: 28),
                  ),
                  sliver: SliverReorderableList(
                    itemCount: active.length,
                    onReorderItem: c.reorderCategory,
                    proxyDecorator: (child, index, animation) =>
                        _dragProxy(context, child),
                    itemBuilder: (context, index) =>
                        _category(context, ref, active[index], index: index),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: pageInset(context, desktop: 28),
                  ),
                  sliver: SliverList.list(
                    children: [
                      if (archived.isNotEmpty)
                        ArchivedCategories(
                          children: [
                            for (final category in archived)
                              _category(context, ref, category),
                          ],
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _edit(context, null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add category'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
                      'Export includes categories, weeks, undone entries, journal entries, reviews, schedules, academic events and local preferences. Windows startup and background settings stay on this device. Restoring creates a safety backup first.',
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

  Widget _category(
    BuildContext context,
    WidgetRef ref,
    Category category, {
    int? index,
  }) {
    final c = ref.read(studyProvider);
    final label = TextButton(
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: () => _edit(context, category),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            category.config.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            category.archived
                ? 'Archived'
                : '${Amount.format(category.config.floor)} minimum · ${Amount.format(category.config.target)} target ${category.config.unit}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    final controls = <Widget>[
      IconButton(
        key: ValueKey('category-archive-${category.id}'),
        tooltip: category.archived ? 'Restore category' : 'Archive category',
        icon: Icon(
          category.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          size: 20,
        ),
        onPressed: () async {
          if (category.archived ||
              await confirm(
                context,
                'Archive ${category.config.name}?',
                'It will be hidden from the active dashboard. All historical data will be kept.',
                action: 'Archive',
              )) {
            c.perform(
              () => c.repository.setCategoryStatus(
                category.id,
                active: category.archived,
                archived: !category.archived,
              ),
            );
          }
        },
      ),
      if (!category.archived) ...[
        Switch(
          key: ValueKey('category-toggle-${category.id}'),
          value: category.active,
          onChanged: (v) => c.perform(
            () => c.repository.setCategoryStatus(
              category.id,
              active: v,
              archived: false,
            ),
          ),
        ),
        _OrderHandle(id: 'category-drag-${category.id}', index: index!),
      ],
    ];
    return Padding(
      key: ValueKey('category-${category.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: phoneLayout(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: controls,
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: label),
                ...controls,
              ],
            ),
    );
  }

  Future<void> _edit(BuildContext context, Category? category) =>
      showDialog<void>(
        context: context,
        builder: (_) => CategoryEditor(category: category),
      );
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
            'This replaces local data with the selected backup. A safety copy of your current data will be saved beside the database.',
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

class ArchivedCategories extends StatefulWidget {
  final List<Widget> children;
  const ArchivedCategories({super.key, required this.children});

  @override
  State<ArchivedCategories> createState() => _ArchivedCategoriesState();
}

class _ArchivedCategoriesState extends State<ArchivedCategories> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('archived-categories'),
    tilePadding: EdgeInsets.zero,
    dense: true,
    shape: const Border(),
    collapsedShape: const Border(),
    onExpansionChanged: (value) => setState(() => expanded = value),
    leading: AnimatedRotation(
      turns: expanded ? .25 : 0,
      duration: const Duration(milliseconds: 180),
      child: const Icon(Icons.chevron_right, size: 20),
    ),
    trailing: const SizedBox.shrink(),
    title: Text(
      'Archived Categories',
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    children: widget.children,
  );
}

class CategoryEditor extends ConsumerStatefulWidget {
  final Category? category;
  const CategoryEditor({super.key, this.category});
  @override
  ConsumerState<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<CategoryEditor> {
  late Measurement type =
      widget.category?.config.measurement ?? Measurement.continuous;
  late final name = TextEditingController(
        text: widget.category?.config.name ?? '',
      ),
      unit = TextEditingController(text: widget.category?.config.unit ?? 'h'),
      floor = TextEditingController(
        text: Amount.format(widget.category?.config.floor ?? 200),
      ),
      target = TextEditingController(
        text: Amount.format(widget.category?.config.target ?? 400),
      ),
      increment = TextEditingController(
        text: Amount.format(widget.category?.config.increment ?? 100),
      ),
      step = TextEditingController(
        text: Amount.format(widget.category?.config.step ?? 25),
      );
  String? error;
  @override
  void dispose() {
    for (final f in [name, unit, floor, target, increment, step]) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.category == null ? 'Add category' : 'Edit category'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<Measurement>(
              isExpanded: phoneLayout(context),
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Measurement'),
              items: const [
                DropdownMenuItem(
                  value: Measurement.continuous,
                  child: Text('Continuous'),
                ),
                DropdownMenuItem(
                  value: Measurement.discrete,
                  child: Text('Discrete count'),
                ),
              ],
              onChanged: (v) => setState(() {
                type = v!;
                if (type == Measurement.discrete) {
                  step.text = '1';
                  unit.clear();
                } else {
                  step.text = '0.25';
                  unit.text = 'h';
                }
              }),
            ),
            for (final f in [
              (unit, 'Display unit (h, count or custom)'),
              (floor, 'Floor'),
              (target, 'Target'),
              (increment, 'Default addition'),
              (step, 'Arrow-key step / precision'),
            ])
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextField(
                  controller: f.$1,
                  decoration: InputDecoration(labelText: f.$2),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final discrete = type == Measurement.discrete;
            final config = GoalConfig(
              name: name.text,
              measurement: type,
              unit: unit.text,
              floor: Amount.parse(
                floor.text,
                discrete: discrete,
                allowZero: true,
              ),
              target: Amount.parse(target.text, discrete: discrete),
              increment: Amount.parse(increment.text, discrete: discrete),
              step: Amount.parse(step.text, discrete: discrete),
            );
            config.validate();
            final c = ref.read(studyProvider);
            c.checkClock();
            if (c.perform(
              () => c.repository.saveCategory(
                widget.category?.id,
                config,
                c.current,
              ),
            )) {
              Navigator.pop(context);
            } else {
              setState(() => error = c.error);
            }
          } catch (e) {
            setState(() => error = e is FormatException ? e.message : '$e');
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
