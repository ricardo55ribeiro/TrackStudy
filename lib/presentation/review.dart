import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_controller.dart';
import '../domain/models.dart';
import 'common.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});
  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  late final String week;
  late final List<TextEditingController> fields;
  late final List<bool> done;
  bool saved = false;
  Timer? _savedTimer;
  @override
  void initState() {
    super.initState();
    final c = ref.read(studyProvider);
    week = c.selected.key;
    final review = c.repository.review(c.selected);
    fields = [
      review.wentWrong,
      review.change,
      review.upcoming,
      ...review.wins,
      review.danger,
      review.countermeasure,
    ].map((t) => TextEditingController(text: t)).toList();
    done = List.of(review.done);
  }

  @override
  void didUpdateWidget(ReviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final c = ref.read(studyProvider);
    final review = c.repository.review(c.selected);
    final values = [
      review.wentWrong,
      review.change,
      review.upcoming,
      ...review.wins,
      review.danger,
      review.countermeasure,
    ];
    // Local drafts are already persisted. Only change controllers when a remote
    // winner actually differs, preserving normal typing/focus during sync.
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].text != values[i]) fields[i].text = values[i];
    }
    for (var i = 0; i < done.length; i++) {
      done[i] = review.done[i];
    }
  }

  @override
  void dispose() {
    _savedTimer?.cancel();
    for (final f in fields) {
      f.dispose();
    }
    super.dispose();
  }

  bool _persist() {
    try {
      ref
          .read(repositoryProvider)
          .saveReview(
            WeeklyReview(
              week: week,
              wentWrong: fields[0].text,
              change: fields[1].text,
              upcoming: fields[2].text,
              wins: fields.sublist(3, 6).map((f) => f.text).toList(),
              done: List.of(done),
              danger: fields[6].text,
              countermeasure: fields[7].text,
            ),
          );
      return true;
    } catch (e) {
      showFailure(context, e);
      return false;
    }
  }

  Widget field(int i, String label, {int lines = 2}) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextField(
      controller: fields[i],
      minLines: lines,
      maxLines: 5,
      onChanged: (_) {
        _persist();
      },
      decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(studyProvider);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        pageInset(context),
        0,
        pageInset(context),
        36,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Weekly review',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            if (!phoneLayout(context))
              Text(
                saved ? 'Saved' : 'Draft saves as you type',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () {
                if (_persist()) {
                  setState(() => saved = true);
                  _savedTimer?.cancel();
                  _savedTimer = Timer(const Duration(seconds: 3), () {
                    if (mounted) {
                      setState(() => saved = false);
                    }
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
        if (phoneLayout(context))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              saved ? 'Saved' : 'Draft saves as you type',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SectionTitle('Score'),
        Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            for (final p in c.progress)
              SizedBox(
                width: 145,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.config.name,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      p.value,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 28),
        field(0, 'What went wrong?'),
        field(1, 'Change for next week'),
        field(2, 'Next 2 weeks'),
        const SectionTitle('Three wins for next week'),
        for (var i = 0; i < 3; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: done[i],
                onChanged: (value) {
                  setState(() => done[i] = value!);
                  _persist();
                },
              ),
              Expanded(child: field(i + 3, 'Win ${i + 1}', lines: 1)),
            ],
          ),
        const SizedBox(height: 8),
        field(6, 'Biggest danger', lines: 1),
        field(7, 'Countermeasure', lines: 1),
      ],
    );
  }
}
