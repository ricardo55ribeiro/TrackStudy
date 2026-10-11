import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../application/study_controller.dart';
import '../domain/planning.dart';
import 'common.dart';
import 'schedule.dart' show weekdays;

class MonthlyScreen extends ConsumerStatefulWidget {
  const MonthlyScreen({super.key});
  @override
  ConsumerState<MonthlyScreen> createState() => _MonthlyScreenState();
}

class _MonthlyScreenState extends ConsumerState<MonthlyScreen> {
  DateTime month = LocalDate.month(DateTime.now(), 0),
      selected = DateTime.now();
  void move(int offset) => setState(() {
    month = LocalDate.month(month, offset);
    selected = month;
  });
  Future<void> edit({AcademicEvent? event, DateTime? date}) => showDialog<void>(
    context: context,
    builder: (_) => AcademicEditor(event: event, date: date ?? selected),
  );
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(studyProvider), scheme = Theme.of(context).colorScheme;
    final events = c.repository.academicEvents(month),
        cells = LocalDate.monthCells(month);
    final today = LocalDate.key(DateTime.now());
    final phone = phoneLayout(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        pageInset(context, desktop: 28),
        4,
        pageInset(context, desktop: 28),
        0,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Monthly View',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              TextButton(
                onPressed: () => edit(),
                child: const Text('Add event'),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous month',
                onPressed: month.year > 1900 || month.month > 1
                    ? () => move(-1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  DateFormat.yMMMM().format(month),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Next month',
                onPressed: month.year < 9999 || month.month < 12
                    ? () => move(1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
              TextButton(
                onPressed: () => setState(() {
                  selected = DateTime.now();
                  month = LocalDate.month(selected, 0);
                }),
                child: const Text('Today'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final day in weekdays)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(phone ? 2 : 8),
                    child: Text(
                      day.substring(0, 3),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: Column(
                  children: [
                    for (var row = 0; row < cells.length ~/ 7; row++)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final date in cells.skip(row * 7).take(7))
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final key = LocalDate.key(date),
                                      dayEvents = events
                                          .where((e) => e.date == key)
                                          .toList(),
                                      inMonth = date.month == month.month;
                                  return Container(
                                    height: phone ? 70 : 128,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: scheme.outlineVariant.withValues(
                                          alpha: .45,
                                        ),
                                        width: .5,
                                      ),
                                      color: key == LocalDate.key(selected)
                                          ? scheme.primaryContainer.withValues(
                                              alpha: .2,
                                            )
                                          : null,
                                    ),
                                    child: InkWell(
                                      key: ValueKey('date-$key'),
                                      onTap: () =>
                                          setState(() => selected = date),
                                      onDoubleTap: inMonth
                                          ? () => edit(date: date)
                                          : null,
                                      child: Padding(
                                        padding: EdgeInsets.all(phone ? 3 : 6),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Container(
                                              padding: EdgeInsets.symmetric(
                                                horizontal: phone ? 4 : 6,
                                                vertical: phone ? 1 : 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: key == today
                                                    ? scheme.primary
                                                    : null,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Text(
                                                '${date.day}',
                                                maxLines: 1,
                                                style: TextStyle(
                                                  fontSize: phone ? 12 : 14,
                                                  color: key == today
                                                      ? scheme.onPrimary
                                                      : inMonth
                                                      ? scheme.onSurface
                                                      : scheme.outline,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            if (phone && dayEvents.isNotEmpty)
                                              Container(
                                                margin: const EdgeInsets.only(
                                                  top: 3,
                                                ),
                                                height: 4,
                                                width: double.infinity,
                                                decoration: BoxDecoration(
                                                  color: scheme.primary,
                                                  borderRadius:
                                                      BorderRadius.circular(2),
                                                ),
                                              ),
                                            if (phone && dayEvents.isNotEmpty)
                                              Text(
                                                '${dayEvents.length}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: scheme.primary,
                                                ),
                                              ),
                                            for (final event in dayEvents.take(
                                              phone ? 0 : 2,
                                            ))
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 3,
                                                ),
                                                child: Tooltip(
                                                  message:
                                                      '${event.title} · ${event.type.label}',
                                                  child: InkWell(
                                                    onTap: () =>
                                                        edit(event: event),
                                                    child: Container(
                                                      width: double.infinity,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 5,
                                                            vertical: 3,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: scheme
                                                            .secondaryContainer,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              4,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        event.title,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          color: scheme
                                                              .onSecondaryContainer,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            if (!phone && dayEvents.length > 2)
                                              Text(
                                                '+${dayEvents.length - 2} more',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodySmall,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            DateFormat.MMMMEEEEd().format(selected),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: () => edit(),
                          child: const Text('Add event'),
                        ),
                      ],
                    ),
                    for (final event
                        in c.repository
                            .academicEvents(selected)
                            .where((e) => e.date == LocalDate.key(selected)))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(event.title),
                        subtitle: Text(
                          '${event.type.label}${event.note.isEmpty ? '' : ' · ${event.note}'}',
                        ),
                        onTap: () => edit(event: event),
                      ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AcademicEditor extends ConsumerStatefulWidget {
  final AcademicEvent? event;
  final DateTime date;
  const AcademicEditor({super.key, this.event, required this.date});
  @override
  ConsumerState<AcademicEditor> createState() => _AcademicEditorState();
}

class _AcademicEditorState extends ConsumerState<AcademicEditor> {
  late final title = TextEditingController(text: widget.event?.title ?? ''),
      note = TextEditingController(text: widget.event?.note ?? ''),
      date = TextEditingController(
        text: widget.event?.date ?? LocalDate.key(widget.date),
      );
  late AcademicType type = widget.event?.type ?? AcademicType.other;
  String? error;
  @override
  void dispose() {
    title.dispose();
    note.dispose();
    date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.event == null ? 'Add academic event' : 'Edit academic event',
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: date,
              keyboardType: TextInputType.datetime,
              decoration: InputDecoration(
                labelText: 'Date · YYYY-MM-DD',
                suffixIcon: IconButton(
                  tooltip: 'Choose date',
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  onPressed: () async {
                    var initialDate = widget.date;
                    try {
                      initialDate = LocalDate.parse(date.text);
                    } on FormatException {
                      // An unfinished or invalid typed date must not break the picker.
                    }
                    final chosen = await showDatePicker(
                      context: context,
                      initialDate: initialDate,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(9999, 12, 31),
                    );
                    if (chosen != null) date.text = LocalDate.key(chosen);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<AcademicType>(
              initialValue: type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final value in AcademicType.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: (v) => setState(() => type = v!),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: note,
              maxLength: 2000,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.event != null)
        TextButton(
          onPressed: () async {
            if (await confirm(
                  context,
                  'Delete this event?',
                  'It will be removed from your month.',
                  action: 'Delete',
                ) &&
                context.mounted) {
              if (ref
                  .read(studyProvider)
                  .perform(
                    () => ref
                        .read(repositoryProvider)
                        .deleteAcademicEvent(widget.event!.id),
                  )) {
                Navigator.pop(context);
              }
            }
          },
          child: const Text('Delete'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final event = AcademicEvent(
              id: widget.event?.id ?? const Uuid().v4(),
              title: title.text,
              date: date.text.trim(),
              type: type,
              note: note.text,
            );
            event.validate();
            final c = ref.read(studyProvider);
            if (c.perform(() => c.repository.saveAcademicEvent(event))) {
              Navigator.pop(context);
            } else {
              setState(() => error = c.error);
            }
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
