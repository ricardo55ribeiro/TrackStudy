import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../application/study_controller.dart';
import '../domain/planning.dart';
import '../platform/schedule_png_file.dart';
import 'common.dart';
import 'planning_colours.dart';
import 'schedule_export.dart';
import 'schedule_layout.dart';

class ScheduleScreen extends ConsumerStatefulWidget {
  final bool active;
  final DateTime Function()? clock;
  const ScheduleScreen({super.key, required this.active, this.clock});
  @override
  ConsumerState<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends ConsumerState<ScheduleScreen>
    with WidgetsBindingObserver {
  final scroll = ScrollController();
  Timer? timer;
  late DateTime now;
  late int day;
  bool foreground = true;
  bool exporting = false;
  DateTime readClock() => (widget.clock ?? DateTime.now)();
  @override
  void initState() {
    super.initState();
    now = readClock();
    day = now.weekday;
    WidgetsBinding.instance.addObserver(this);
    updateTimer();
    if (widget.active) reveal();
  }

  void updateTimer() {
    timer?.cancel();
    if (widget.active && foreground) {
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        final next = readClock();
        setState(() {
          if (day == now.weekday && LocalDate.key(now) != LocalDate.key(next)) {
            day = next.weekday;
          }
          now = next;
        });
      });
    }
  }

  @override
  void didUpdateWidget(ScheduleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        now = readClock();
        day = now.weekday;
        reveal();
      }
      updateTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      setState(() {
        final next = readClock();
        if (day == now.weekday && LocalDate.key(now) != LocalDate.key(next)) {
          day = next.weekday;
        }
        now = next;
      });
    }
    updateTimer();
  }

  int startMinute(List<ScheduleBlock> blocks) => math.min(
    day == now.weekday ? now.hour * 60 : 360,
    blocks.fold(360, (n, b) => math.min(n, (b.startMinute ~/ 60) * 60)),
  );
  void reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !scroll.hasClients) return;
    final blocks = ref.read(repositoryProvider).schedule(day);
    final focus = day == now.weekday
        ? WallTime.minutes(now)
        : (blocks.firstOrNull?.startMinute ?? 480).toDouble();
    scroll.jumpTo(
      ((focus - startMinute(blocks)) * scheduleMinuteHeight - 120).clamp(
        0,
        scroll.position.maxScrollExtent,
      ),
    );
  });
  @override
  void dispose() {
    timer?.cancel();
    scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> exportSchedule() async {
    final options = await showDialog<ScheduleExportOptions>(
      context: context,
      builder: (_) => const ScheduleExportDialog(),
    );
    if (options == null || !mounted) return;

    setState(() => exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    final stamp = DateFormat('yyyy-MM-dd-HHmmss', 'en_US').format(readClock());
    try {
      final repository = ref.read(repositoryProvider);
      final png = await renderSchedulePng(
        options: options,
        blocksByDay: {
          for (final weekday in options.days)
            weekday: repository.schedule(weekday),
        },
        brightness: Theme.of(context).brightness,
      );
      final location = await saveSchedulePng(
        png,
        'trackstudy-daily-schedule-$stamp.png',
      );
      if (messenger.mounted && location != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $location')));
      }
    } catch (_) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not save the schedule PNG.')),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Widget scheduleBlock(
    ScheduleBlock block,
    Brightness brightness,
    double textScale,
  ) {
    final ink = block.colour.foreground(brightness);
    final smallText = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: ink);
    return Tooltip(
      message:
          '${block.title}\n${scheduleBlockTime(block)}${block.description == null ? '' : '\n${block.description}'}',
      child: Material(
        color: block.colour.background(brightness),
        borderRadius: const BorderRadius.all(scheduleBlockRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => ScheduleEditor(weekday: day, block: block),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final content = scheduleBlockContent(
                block,
                box.maxHeight,
                textScale: textScale,
              );
              final title = content.title;
              if (title == null) return const SizedBox();
              return Padding(
                padding: EdgeInsets.all(content.padding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: ink),
                    ),
                    if (content.time case final time?)
                      Text(
                        time,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: smallText,
                      ),
                    if (content.description case final description?)
                      Text(
                        description,
                        key: ValueKey('description-${block.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: smallText,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final study = ref.watch(studyProvider),
        blocks = study.repository.schedule(day);
    final start = startMinute(blocks), scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final onExport = exporting ? null : exportSchedule;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final placements = layoutSchedule(blocks);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        pageInset(context, desktop: 28),
        4,
        pageInset(context, desktop: 28),
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(
                  'Daily Schedule',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => ScheduleEditor(weekday: day),
                        ),
                        child: const Text('Add block'),
                      ),
                    ),
                    if (Theme.of(context).platform == TargetPlatform.android)
                      IconButton(
                        tooltip: 'Export Daily Schedule',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: onExport,
                      )
                    else
                      TextButton.icon(
                        icon: const Icon(Icons.download_outlined),
                        onPressed: onExport,
                        label: const Text('Export'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text('Your repeating week'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var d = 1; d <= 7; d++)
                ChoiceChip(
                  key: ValueKey('weekday-$d'),
                  label: Text(weekdays[d - 1].substring(0, 3)),
                  selected: day == d,
                  onSelected: (_) {
                    setState(() => day = d);
                    reveal();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (blocks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('No schedule blocks for ${weekdays[day - 1]}.'),
            ),
          Expanded(
            child: SingleChildScrollView(
              controller: scroll,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gutter = 58.0;
                  final laneCount = placements.fold(
                    1,
                    (n, p) => math.max(n, p.lanes),
                  );
                  final timelineWidth = math.max(
                    constraints.maxWidth,
                    gutter + laneCount * 120.0,
                  );
                  final width = timelineWidth - gutter;
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: timelineWidth,
                      height: (1440 - start) * scheduleMinuteHeight + 30,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (var minute = start; minute <= 1440; minute += 60)
                            Positioned(
                              top: (minute - start) * scheduleMinuteHeight,
                              left: 0,
                              right: 0,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: gutter,
                                    child: Text(
                                      WallTime.label(minute),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                  Expanded(
                                    child: Divider(
                                      height: 1,
                                      color: scheme.outlineVariant.withValues(
                                        alpha: .55,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          for (final placement in placements)
                            Positioned.fromRect(
                              key: ValueKey('block-${placement.block.id}'),
                              rect: scheduleBlockBounds(
                                placement,
                                firstMinute: start,
                                width: width,
                                left: gutter,
                              ),
                              child: scheduleBlock(
                                placement.block,
                                brightness,
                                textScale,
                              ),
                            ),
                          if (day == now.weekday)
                            AnimatedPositioned(
                              key: const ValueKey('current-time-line'),
                              duration: const Duration(milliseconds: 900),
                              curve: Curves.linear,
                              top:
                                  (WallTime.minutes(now) - start) *
                                  scheduleMinuteHeight,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: SizedBox(
                                  height: 0,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        top: -10,
                                        left: 0,
                                        width: gutter,
                                        height: 20,
                                        child: Container(
                                          width: gutter,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 3,
                                          ),
                                          color: scheme.onSurface,
                                          child: Text(
                                            WallTime.label(
                                              now.hour * 60 + now.minute,
                                            ),
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: scheme.surface,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        top: -1,
                                        left: gutter,
                                        right: 0,
                                        height: 2,
                                        child: Container(
                                          height: 2,
                                          color: scheme.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleEditor extends ConsumerStatefulWidget {
  final int weekday;
  final ScheduleBlock? block;
  const ScheduleEditor({super.key, required this.weekday, this.block});
  @override
  ConsumerState<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<ScheduleEditor> {
  late final title = TextEditingController(text: widget.block?.title ?? ''),
      description = TextEditingController(
        text: widget.block?.description ?? '',
      ),
      start = TextEditingController(
        text: WallTime.label(widget.block?.startMinute ?? 540),
      ),
      end = TextEditingController(
        text: WallTime.label(widget.block?.endMinute ?? 600),
      );
  late int weekday = widget.block?.weekday ?? widget.weekday;
  late ScheduleColour colour = widget.block?.colour ?? ScheduleColour.blue;
  String? error;
  @override
  void dispose() {
    title.dispose();
    description.dispose();
    start.dispose();
    end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(
      widget.block == null ? 'Add schedule block' : 'Edit schedule block',
    ),
    content: SizedBox(
      width: 380,
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
          DropdownButtonFormField<int>(
            initialValue: weekday,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Weekday'),
            items: [
              for (var d = 1; d <= 7; d++)
                DropdownMenuItem(value: d, child: Text(weekdays[d - 1])),
            ],
            onChanged: (v) => setState(() => weekday = v!),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: start,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'Start · HH:MM'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: end,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'End · HH:MM'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: description,
            minLines: 1,
            maxLines: 3,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
          ),
          PlanningColourSelector(
            colour: colour,
            keyPrefix: 'schedule',
            onChanged: (value) => setState(() => colour = value),
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
    actions: [
      if (widget.block != null)
        TextButton(
          onPressed: () async {
            if (await confirm(
                  context,
                  'Delete this block?',
                  'It will be removed from your repeating week.',
                  action: 'Delete',
                ) &&
                context.mounted) {
              if (ref
                  .read(studyProvider)
                  .perform(
                    () => ref
                        .read(repositoryProvider)
                        .deleteSchedule(widget.block!.id),
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
            final block = ScheduleBlock(
              id: widget.block?.id ?? const Uuid().v4(),
              title: title.text,
              weekday: weekday,
              startMinute: WallTime.parse(start.text),
              endMinute: WallTime.parse(end.text),
              description: description.text,
              colour: colour,
            );
            block.validate();
            final c = ref.read(studyProvider);
            if (c.perform(() => c.repository.saveSchedule(block))) {
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
