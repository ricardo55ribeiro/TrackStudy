import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../application/study_controller.dart';
import '../domain/models.dart';
import 'common.dart';

class JournalScreen extends ConsumerStatefulWidget {
  const JournalScreen({super.key});
  @override
  ConsumerState<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends ConsumerState<JournalScreen> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    ref.watch(studyProvider);
    final repository = ref.watch(repositoryProvider),
        all = repository.journal(''),
        entries = repository.journal(search);
    final latest = all.where((e) => e.next.trim().isNotEmpty).firstOrNull;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        pageInset(context),
        16,
        pageInset(context),
        32,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Research journal',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            FilledButton(
              onPressed: () => _edit(context),
              child: const Text('New entry'),
            ),
          ],
        ),
        if (latest != null)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PICK UP HERE',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.3,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  latest.next,
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search journal',
            prefixIcon: Icon(Icons.search, size: 18),
          ),
          onChanged: (s) => setState(() => search = s),
        ),
        const SizedBox(height: 20),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Text(
              'A thought, a question, a next step. Start with a new entry.',
            ),
          ),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        DateFormat(
                          'EEE, d MMM yyyy · HH:mm',
                        ).format(DateTime.parse(entry.createdAt).toLocal()),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _edit(context, entry),
                      child: const Text('Edit'),
                    ),
                  ],
                ),
                if (entry.learned.trim().isNotEmpty)
                  JournalSection(title: 'Learned', text: entry.learned),
                if (entry.question.trim().isNotEmpty)
                  JournalSection(
                    title: 'Question',
                    text: entry.question,
                    action: TextButton(
                      key: ValueKey('answer-${entry.id}'),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => JournalAnswerEditor(entry: entry),
                      ),
                      child: Text(
                        entry.answer == null ? 'Answer' : 'Edit answer',
                      ),
                    ),
                    answer: entry.answer,
                  ),
                if (entry.next.trim().isNotEmpty)
                  JournalSection(title: 'Next', text: entry.next),
                if (entry.experiment.values.any((v) => v.isNotEmpty))
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Experiment notes'),
                    children: [
                      for (final field in entry.experiment.entries)
                        if (field.value.isNotEmpty)
                          ListTile(
                            title: Text(field.key),
                            subtitle: SelectableText(field.value),
                          ),
                    ],
                  ),
                const Divider(),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, [JournalEntry? entry]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => JournalEditor(entry: entry),
    );
    if (mounted) {
      setState(() {});
    }
  }
}

class JournalSection extends StatelessWidget {
  final String title, text;
  final String? answer;
  final Widget? action;
  const JournalSection({
    super.key,
    required this.title,
    required this.text,
    this.answer,
    this.action,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Divider(
                  thickness: .7,
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
              if (action != null) ...[const SizedBox(width: 8), action!],
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(text),
          if (answer != null && answer!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'ANSWER',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(answer!),
          ],
        ],
      ),
    );
  }
}

class JournalAnswerEditor extends ConsumerStatefulWidget {
  final JournalEntry entry;
  const JournalAnswerEditor({super.key, required this.entry});
  @override
  ConsumerState<JournalAnswerEditor> createState() =>
      _JournalAnswerEditorState();
}

class _JournalAnswerEditorState extends ConsumerState<JournalAnswerEditor> {
  late final answer = TextEditingController(text: widget.entry.answer ?? '');
  String? error;
  @override
  void dispose() {
    answer.dispose();
    super.dispose();
  }

  void save(String? value) {
    final c = ref.read(studyProvider);
    if (c.perform(
      () => c.repository.answerJournal(
        widget.entry.id,
        value,
        question: widget.entry.question,
      ),
    )) {
      Navigator.pop(context);
    } else {
      setState(() => error = c.error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.entry.answer == null ? 'Answer question' : 'Edit answer',
    ),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('QUESTION', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            SelectableText(widget.entry.question),
            const SizedBox(height: 20),
            TextField(
              controller: answer,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Answer',
                alignLabelWithHint: true,
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
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
      if (widget.entry.answer != null)
        TextButton(
          onPressed: () => save(null),
          child: const Text('Clear answer'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => save(answer.text),
        child: const Text('Save'),
      ),
    ],
  );
}

class JournalEditor extends ConsumerStatefulWidget {
  final JournalEntry? entry;
  const JournalEditor({super.key, this.entry});
  @override
  ConsumerState<JournalEditor> createState() => _JournalEditorState();
}

class _JournalEditorState extends ConsumerState<JournalEditor> {
  late final learned = TextEditingController(text: widget.entry?.learned),
      question = TextEditingController(text: widget.entry?.question),
      next = TextEditingController(text: widget.entry?.next);
  late final experiment = {
    for (final name in [
      'Hypothesis',
      'What I tried',
      'Result',
      'Interpretation',
      'Next experiment',
    ])
      name: TextEditingController(text: widget.entry?.experiment[name]),
  };
  @override
  void dispose() {
    for (final c in [learned, question, next, ...experiment.values]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.entry == null ? 'New research entry' : 'Edit research entry',
    ),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in [
              (learned, 'Learned', 'What changed in my understanding?'),
              (
                question,
                'Question',
                'What am I still confused about / curious about?',
              ),
              (next, 'Next', 'What exactly should I do when I return?'),
            ])
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: TextField(
                  controller: f.$1,
                  autofocus: f.$1 == learned,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: f.$2,
                    hintText: f.$3,
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Experiment notes (optional)'),
              children: [
                for (final f in experiment.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: f.value,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(labelText: f.key),
                    ),
                  ),
              ],
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
            final current = ref
                .read(repositoryProvider)
                .journal('')
                .where((e) => e.id == widget.entry?.id)
                .firstOrNull;
            ref
                .read(repositoryProvider)
                .saveJournal(
                  JournalEntry(
                    id: widget.entry?.id ?? const Uuid().v4(),
                    createdAt:
                        widget.entry?.createdAt ??
                        DateTime.now().toUtc().toIso8601String(),
                    learned: learned.text,
                    question: question.text,
                    next: next.text,
                    answer: current?.answer,
                    answeredAt: current?.answeredAt,
                    experiment: experiment.map((k, v) => MapEntry(k, v.text)),
                  ),
                );
            Navigator.pop(context);
          } catch (e) {
            showFailure(context, e);
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
