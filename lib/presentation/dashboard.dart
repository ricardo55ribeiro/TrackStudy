import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../application/study_controller.dart';
import '../domain/models.dart';
import 'progress_bar.dart';
import 'common.dart';

class Dashboard extends ConsumerWidget {
  const Dashboard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(studyProvider);
    if (c.progress.isEmpty) {
      return Center(
        child: Text(
          c.editable
              ? 'Add or enable a category in Settings.'
              : 'No tracking recorded for this week.',
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        pageInset(context),
        0,
        pageInset(context),
        32,
      ),
      itemCount: c.progress.length,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (_, i) => CategoryRow(
        key: ValueKey(c.progress[i].goalId),
        progress: c.progress[i],
      ),
    );
  }
}

class CategoryRow extends ConsumerStatefulWidget {
  final WeeklyProgress progress;
  const CategoryRow({super.key, required this.progress});
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
    final editable = ref.watch(studyProvider).editable;
    final p = widget.progress;
    final name = Text(
      p.config.name,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      overflow: TextOverflow.ellipsis,
    );
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
