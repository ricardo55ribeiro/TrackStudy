import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../application/study_controller.dart';
import '../domain/models.dart';
import 'progress_bar.dart';
import 'common.dart';
import 'category_editor.dart';

class Dashboard extends ConsumerStatefulWidget {
  const Dashboard({super.key});
  @override
  ConsumerState<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<Dashboard> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(studyProvider);
    if (!c.editable && c.progress.isEmpty) {
      return Center(child: Text('No tracking recorded for this week.'));
    }
    final archived = c.repository
        .categories()
        .where((bar) => bar.archived || !bar.active)
        .toList();
    if (!c.editable || archived.isEmpty) expanded = false;
    final progress = [...c.progress];
    final inset = pageInset(context);
    Widget row(int i) => Column(
      key: ValueKey(progress[i].goalId),
      children: [
        CategoryRow(progress: progress[i], index: c.editable ? i : null),
        if (i < progress.length - 1) const Divider(height: 1),
      ],
    );
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            key: const ValueKey('progress-scroll'),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: c.editable
                    ? SliverReorderableList(
                        itemCount: progress.length,
                        itemBuilder: (_, i) => row(i),
                        proxyDecorator: (child, index, animation) => Material(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          elevation: 2,
                          child: child,
                        ),
                        onReorderItem: (oldIndex, newIndex) {
                          final ids = progress
                              .map((p) => p.categoryId)
                              .toList();
                          ids.insert(newIndex, ids.removeAt(oldIndex));
                          c.reorderBars(ids);
                        },
                      )
                    : SliverList.builder(
                        itemCount: progress.length,
                        itemBuilder: (_, i) => row(i),
                      ),
              ),
              if (c.editable && progress.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Add a bar or restore an archived bar to start tracking.',
                    ),
                  ),
                ),
              if (c.editable && archived.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  sliver: SliverList.list(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('archived-bars'),
                          onPressed: () => setState(() => expanded = !expanded),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          icon: AnimatedRotation(
                            turns: expanded ? .25 : 0,
                            duration: const Duration(milliseconds: 160),
                            child: const Icon(Icons.chevron_right, size: 18),
                          ),
                          label: Text(
                            'Archived Bars (${archived.length})',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      if (expanded)
                        for (final bar in archived)
                          Row(
                            key: ValueKey('archived-bar-${bar.id}'),
                            children: [
                              Expanded(
                                child: Text(
                                  bar.config.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              TextButton(
                                key: ValueKey('restore-bar-${bar.id}'),
                                onPressed: () =>
                                    c.archiveBar(bar.id, false, c.current),
                                child: const Text('Restore'),
                              ),
                            ],
                          ),
                    ],
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          ),
        ),
        if (c.editable)
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 10, inset, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const ValueKey('add-bar'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const CategoryEditor(),
                ),
                icon: const Icon(Icons.add, size: 24),
                label: const Text('Add Bar'),
              ),
            ),
          ),
      ],
    );
  }
}

class CategoryRow extends ConsumerStatefulWidget {
  final WeeklyProgress progress;
  final int? index;
  const CategoryRow({super.key, required this.progress, this.index});
  @override
  ConsumerState<CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends ConsumerState<CategoryRow> {
  final input = TextEditingController();
  final focus = FocusNode();
  String? error;
  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    input.text = '';
  }

  @override
  void didUpdateWidget(CategoryRow old) {
    super.didUpdateWidget(old);
    if (old.progress.config.increment != widget.progress.config.increment ||
        old.progress.config.measurement != widget.progress.config.measurement) {
      _reset();
    }
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  void add() {
    final c = ref.read(studyProvider);
    try {
      Amount.parse(
        input.text,
        discrete: widget.progress.config.measurement == Measurement.discrete,
      );
    } catch (e) {
      setState(() => error = e is FormatException ? e.message : '$e');
      focus.requestFocus();
      return;
    }
    if (c.add(widget.progress, input.text)) {
      setState(() => error = null);
      _reset();
      focus.requestFocus();
      input.selection = TextSelection(
        baseOffset: 0,
        extentOffset: input.text.length,
      );
    }
  }

  Widget _controls(bool editable) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 76,
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              input.clear();
              setState(() => error = null);
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                    event.logicalKey == LogicalKeyboardKey.arrowDown)) {
              var value = 0;
              try {
                value = Amount.parse(input.text, allowZero: true);
              } catch (_) {}
              value =
                  (value +
                          (event.logicalKey == LogicalKeyboardKey.arrowUp
                                  ? 1
                                  : -1) *
                              widget.progress.config.step)
                      .clamp(0, Amount.max);
              input.text = Amount.format(value);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Semantics(
            label: 'Add amount for ${widget.progress.config.name}',
            child: TextField(
              key: ValueKey('input-${widget.progress.config.name}'),
              controller: input,
              focusNode: focus,
              enabled: editable,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                // Keep a pasted minus sign so validation rejects it instead of
                // silently turning a negative correction into a positive commit.
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,-]')),
              ],
              decoration: InputDecoration(
                errorText: error == null ? null : 'Invalid',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
              ),
              onTap: () => input.selection = TextSelection(
                baseOffset: 0,
                extentOffset: input.text.length,
              ),
              onSubmitted: (_) => add(),
              onChanged: (_) {
                if (error != null) {
                  setState(() => error = null);
                }
              },
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        key: ValueKey('add-${widget.progress.config.name}'),
        tooltip: 'Add',
        onPressed: editable ? add : null,
        icon: const Icon(Icons.add, size: 19),
      ),
      const SizedBox(width: 3),
      IconButton(
        key: ValueKey('undo-${widget.progress.config.name}'),
        tooltip: 'Undo last entry',
        onPressed: editable && widget.progress.activeEntries > 0
            ? () => ref.read(studyProvider).undo(widget.progress)
            : null,
        icon: const Icon(Icons.undo, size: 19),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(studyProvider);
    final editable = c.editable && widget.progress.week == c.current.key;
    final p = widget.progress;
    Widget name = Text(
      p.config.name,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      overflow: TextOverflow.ellipsis,
    );
    if (editable) {
      final week = c.current;
      name = PopupMenuButton<String>(
        key: ValueKey('bar-name-${p.categoryId}'),
        tooltip: '',
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'archive', child: Text('Archive')),
        ],
        onSelected: (action) async {
          if (action == 'edit') {
            final category = c.repository
                .categories()
                .where(
                  (bar) =>
                      bar.id == p.categoryId && bar.active && !bar.archived,
                )
                .firstOrNull;
            if (category == null || !c.editable) return;
            await showDialog<void>(
              context: context,
              builder: (_) => CategoryEditor(category: category),
            );
          } else if (await confirm(
            context,
            'Archive ${p.config.name}?',
            '${p.config.name} will be hidden from this entire week\'s Progress Bars and Weekly Review score. Your recorded progress and previous weeks will be preserved. You can restore it at any time.',
            action: 'Archive',
          )) {
            c.archiveBar(p.categoryId, true, week);
          }
        },
        child: Container(
          alignment: Alignment.centerLeft,
          constraints: BoxConstraints(
            minHeight: Theme.of(context).platform == TargetPlatform.android
                ? 48
                : 36,
          ),
          padding: const EdgeInsets.only(right: 8),
          child: name,
        ),
      );
      if (widget.index != null) {
        name = Theme.of(context).platform == TargetPlatform.android
            ? ReorderableDelayedDragStartListener(
                index: widget.index!,
                child: name,
              )
            : ReorderableDragStartListener(
                index: widget.index!,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: name,
                ),
              );
      }
    }
    final bar = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        WeeklyProgressBar(progress: p),
        const SizedBox(height: 5),
        Tooltip(
          message: 'View entries',
          child: InkWell(
            borderRadius: BorderRadius.circular(3),
            onTap: () => _history(context, ref, p),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Text(
                p.value,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 17),
      child: LayoutBuilder(
        builder: (context, box) {
          final body = box.maxWidth >= 660
              ? Row(
                  children: [
                    SizedBox(width: 120, child: name),
                    Expanded(child: bar),
                    const SizedBox(width: 24),
                    _controls(editable),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: name),
                        _controls(editable),
                      ],
                    ),
                    const SizedBox(height: 12),
                    bar,
                  ],
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              body,
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

Future<void> _history(
  BuildContext context,
  WidgetRef ref,
  WeeklyProgress p,
) => showDialog<void>(
  context: context,
  builder: (context) => Consumer(
    builder: (context, ref, child) {
      final c = ref.watch(studyProvider),
          entries = ref.watch(repositoryProvider).entries(p.goalId);
      return AlertDialog(
        title: Text('${p.config.name} · entries'),
        content: SizedBox(
          width: 480,
          height: 360,
          child: entries.isEmpty
              ? const Center(child: Text('No entries yet.'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i], undone = e.undoneAt != null;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '+${Amount.format(e.amount)} ${p.config.unit}',
                        style: TextStyle(
                          decoration: undone
                              ? TextDecoration.lineThrough
                              : null,
                          color: undone
                              ? Theme.of(context).disabledColor
                              : null,
                        ),
                      ),
                      subtitle: Text(
                        '${DateFormat('EEE d MMM, HH:mm').format(DateTime.parse(e.createdAt).toLocal())}${undone ? ' · undone' : ''}',
                      ),
                      trailing: c.editable && p.week == c.current.key
                          ? TextButton(
                              onPressed: () {
                                c.checkClock();
                                c.perform(
                                  () => c.repository.setUndone(
                                    e.id,
                                    !undone,
                                    c.current,
                                  ),
                                );
                              },
                              child: Text(undone ? 'Restore' : 'Undo'),
                            )
                          : null,
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    },
  ),
);
