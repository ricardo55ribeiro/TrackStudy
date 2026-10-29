import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_controller.dart';
import '../domain/todo.dart';
import 'common.dart';

class _TopicDrag {
  final String id;
  final List<String> order;
  final List<String> preview;
  _TopicDrag(this.id, this.order) : preview = [...order];
}

class TodoScreen extends ConsumerStatefulWidget {
  const TodoScreen({super.key});
  @override
  ConsumerState<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends ConsumerState<TodoScreen> {
  final pending = <String, ({String completedAt, Timer timer})>{};
  final expanded = <String>{};
  final scroll = ScrollController();
  EdgeDraggingAutoScroller? topicAutoScroller;
  _TopicDrag? topicDrag;
  Offset? topicPointer;
  final groupKeys = <String, GlobalKey>{};
  final groupHeights = <String, double>{};
  final groupOffsets = <String, double>{};

  @override
  void dispose() {
    topicAutoScroller?.stopAutoScroll();
    for (final value in pending.values) {
      value.timer.cancel();
    }
    scroll.dispose();
    super.dispose();
  }

  void measureGroups() {
    for (final entry in groupKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        groupHeights[entry.key] = box.size.height;
      }
    }
  }

  void previewOrder(List<String> order) {
    final drag = topicDrag;
    if (drag == null) return;
    measureGroups();
    final oldTops = <String, double>{};
    var top = 0.0;
    for (final id in drag.preview) {
      oldTops[id] = top;
      top += groupHeights[id] ?? 0;
    }
    top = 0;
    for (final id in order) {
      groupOffsets[id] = (groupOffsets[id] ?? 0) + top - oldTops[id]!;
      top += groupHeights[id] ?? 0;
    }
    setState(() => drag.preview.replaceRange(0, drag.preview.length, order));
  }

  void endTopicDrag({bool accepted = false}) {
    topicAutoScroller?.stopAutoScroll();
    topicAutoScroller = null;
    topicPointer = null;
    if (!mounted || topicDrag == null) return;
    if (!accepted) previewOrder(topicDrag!.order);
    setState(() => topicDrag = null);
  }

  void hoverTopics(Offset pointer) {
    final drag = topicDrag;
    if (drag == null) return;
    for (final id in drag.preview) {
      if (id == drag.id) continue;
      final box = groupKeys[id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(pointer);
      if (!(Offset.zero & box.size).contains(local)) continue;
      final after = local.dy >= box.size.height / 2;
      final from = drag.preview.indexOf(drag.id);
      var to = drag.preview.indexOf(id) + (after ? 1 : 0);
      if (from < to) to--;
      if (from == to) return;
      final order = [...drag.preview];
      order.insert(to, order.removeAt(from));
      previewOrder(order);
      return;
    }
  }

  void scrollTopicDrag(Offset pointer) {
    topicAutoScroller?.startAutoScrollIfNecessary(
      Rect.fromCenter(center: pointer, width: 40, height: 40),
    );
  }

  void acceptTopic(_TopicDrag drag) {
    final c = ref.read(studyProvider);
    final accepted = c.perform(
      () => c.repository.reorderTodoTopics(drag.preview),
    );
    endTopicDrag(accepted: accepted);
  }

  Widget topicTitle(TodoTopic topic, List<String> order, Widget child) =>
      Builder(
        builder: (titleContext) {
          final feedback = Material(
            key: const ValueKey('topic-drag-preview'),
            color: Theme.of(context).colorScheme.surfaceContainer,
            elevation: 2,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: MediaQuery.sizeOf(context).width - 2 * pageInset(context),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  topic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          );
          Offset anchor(
            Draggable<Object> draggable,
            BuildContext context,
            Offset position,
          ) {
            final box = context.findRenderObject()! as RenderBox;
            final local = box.globalToLocal(position);
            return Offset(local.dx, local.dy.clamp(0, 24));
          }

          final data = _TopicDrag(topic.id, order);
          void start() {
            measureGroups();
            topicAutoScroller = EdgeDraggingAutoScroller(
              Scrollable.of(titleContext),
              velocityScalar: 30,
              onScrollViewScrolled: () {
                if (mounted && topicPointer != null) {
                  hoverTopics(topicPointer!);
                  scrollTopicDrag(topicPointer!);
                }
              },
            );
            setState(() => topicDrag = data);
          }

          void update(DragUpdateDetails details) {
            topicPointer = details.globalPosition;
            hoverTopics(details.globalPosition);
            scrollTopicDrag(details.globalPosition);
          }

          return Theme.of(context).platform == TargetPlatform.android
              ? LongPressDraggable<_TopicDrag>(
                  data: data,
                  axis: Axis.vertical,
                  dragAnchorStrategy: anchor,
                  feedback: feedback,
                  onDragStarted: start,
                  onDragUpdate: update,
                  onDragCompleted: () => endTopicDrag(accepted: true),
                  onDraggableCanceled: (_, _) => endTopicDrag(),
                  child: child,
                )
              : Draggable<_TopicDrag>(
                  data: data,
                  axis: Axis.vertical,
                  dragAnchorStrategy: anchor,
                  feedback: feedback,
                  onDragStarted: start,
                  onDragUpdate: update,
                  onDragCompleted: () => endTopicDrag(accepted: true),
                  onDraggableCanceled: (_, _) => endTopicDrag(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: child,
                  ),
                );
        },
      );

  void toggle(TodoTask task) {
    final c = ref.read(studyProvider);
    if (task.completed) {
      final grace = pending[task.id];
      if (c.perform(
        () => c.repository.restoreTodoTask(
          task.id,
          undoCompletion: grace?.completedAt,
        ),
      )) {
        pending.remove(task.id)?.timer.cancel();
        setState(() {});
      }
      return;
    }
    if (!c.perform(() => c.repository.completeTodoTask(task.id))) return;
    final completed = c.repository
        .todoTasks(task.topicId)
        .firstWhere((t) => t.id == task.id);
    pending.remove(task.id)?.timer.cancel();
    pending[task.id] = (
      completedAt: completed.completedAt!,
      timer: Timer(const Duration(seconds: 5), () {
        // Placement only: expiry never writes over a newer remote edit
        if (mounted) setState(() => pending.remove(task.id));
      }),
    );
    setState(() {});
  }

  Future<void> editor({
    TodoTopic? topic,
    TodoTask? task,
    String? parent,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TodoEditor(topic: topic, task: task, parent: parent),
    );
    if (saved == true &&
        topic == null &&
        task == null &&
        parent == null &&
        mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> deleteTopic(TodoTopic topic) async {
    if (await confirm(
          context,
          'Delete topic?',
          'Delete "${topic.title}" and all of its active and finished tasks? This deletion will sync to your other devices.',
          action: 'Delete topic',
        ) &&
        mounted) {
      final c = ref.read(studyProvider);
      c.perform(() => c.repository.deleteTodoTopic(topic.id));
    }
  }

  Future<void> deleteTask(TodoTask task) async {
    if (await confirm(
          context,
          'Delete task?',
          'Delete "${task.text}"?',
          action: 'Delete task',
        ) &&
        mounted) {
      final c = ref.read(studyProvider);
      c.perform(() => c.repository.deleteTodoTask(task.id));
    }
  }

  Widget row(TodoTask task, {int? index, bool finished = false}) {
    final scheme = Theme.of(context).colorScheme;
    final android = Theme.of(context).platform == TargetPlatform.android;
    final rowHeight = finished
        ? (android ? 48.0 : 40.0)
        : (android ? 52.0 : 48.0);
    Widget body = Container(
      color: Colors.transparent,
      key: ValueKey('task-body-${task.id}'),
      constraints: BoxConstraints(minHeight: rowHeight),
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.symmetric(vertical: finished ? 6 : 10, horizontal: 4),
      child: Text(
        task.text,
        style: TextStyle(
          fontSize: finished ? 13 : 14,
          decoration: task.completed ? TextDecoration.lineThrough : null,
          color: task.completed ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
    );
    body = PopupMenuButton<String>(
      key: ValueKey('task-menu-${task.id}'),
      // Leave long presses to the active task's reorder listener
      tooltip: '',
      onSelected: (action) =>
          action == 'edit' ? editor(task: task) : deleteTask(task),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit task')),
        PopupMenuItem(value: 'delete', child: Text('Delete task')),
      ],
      child: body,
    );
    if (index != null && !task.completed) {
      body = Theme.of(context).platform == TargetPlatform.android
          ? ReorderableDelayedDragStartListener(index: index, child: body)
          : ReorderableDragStartListener(
              index: index,
              child: MouseRegion(cursor: SystemMouseCursors.grab, child: body),
            );
    }
    return Material(
      key: ValueKey('task-${task.id}'),
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            height: rowHeight,
            child: Checkbox(
              key: ValueKey('task-check-${task.id}'),
              semanticLabel: task.completed
                  ? 'Restore ${task.text}'
                  : 'Complete ${task.text}',
              value: task.completed,
              onChanged: (_) => toggle(task),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(studyProvider), scheme = Theme.of(context).colorScheme;
    final topics = c.repository.todoTopics();
    final tasks = {
      for (final topic in topics) topic.id: c.repository.todoTasks(topic.id),
    };
    final all = {
      for (final list in tasks.values)
        for (final task in list) task.id: task,
    };
    for (final id in pending.keys.toList()) {
      if (all[id]?.completedAt != pending[id]!.completedAt) {
        pending.remove(id)?.timer.cancel();
      }
    }
    expanded.retainAll(topics.map((t) => t.id));
    if (topicDrag != null && !topics.any((t) => t.id == topicDrag!.id)) {
      topicAutoScroller?.stopAutoScroll();
      topicDrag = null;
    }
    final byId = {for (final topic in topics) topic.id: topic};
    groupKeys.removeWhere((id, _) => !byId.containsKey(id));
    groupHeights.removeWhere((id, _) => !byId.containsKey(id));
    groupOffsets.removeWhere((id, _) => !byId.containsKey(id));
    final order = topicDrag == null
        ? topics.map((t) => t.id).toList()
        : [
            ...topicDrag!.preview.where(byId.containsKey),
            ...topics
                .map((t) => t.id)
                .where((id) => !topicDrag!.preview.contains(id)),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DragTarget<_TopicDrag>(
            onWillAcceptWithDetails: (_) => true,
            onAcceptWithDetails: (details) => acceptTopic(details.data),
            builder: (_, candidates, rejected) => CustomScrollView(
              key: const ValueKey('todo-scroll'),
              controller: scroll,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    pageInset(context),
                    12,
                    pageInset(context),
                    12,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      'To-Do List',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ),
                if (topics.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.checklist_rounded,
                            color: scheme.primary,
                            size: 36,
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'No topics yet. Add a topic to get started.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final id = order[index];
                      return _TopicMotion(
                        key: ValueKey('topic-group-$id'),
                        slot: groupOffsets[id] ?? 0,
                        keepAlive: topicDrag?.id == id,
                        boundsKey: groupKeys.putIfAbsent(id, GlobalKey.new),
                        child: Opacity(
                          opacity: topicDrag?.id == id ? 0 : 1,
                          child: IgnorePointer(
                            ignoring: topicDrag != null,
                            child: ShrinkWrappingViewport(
                              axisDirection: AxisDirection.down,
                              offset: ViewportOffset.zero(),
                              slivers: topicSlivers(
                                byId[id]!,
                                tasks[id]!,
                                order,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: order.length,
                    findChildIndexCallback: (key) {
                      final index = order.indexWhere(
                        (id) => key == ValueKey('topic-group-$id'),
                      );
                      return index < 0 ? null : index;
                    },
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            pageInset(context),
            10,
            pageInset(context),
            16,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('add-topic'),
              onPressed: () => editor(),
              icon: const Icon(Icons.add, size: 24),
              label: const Text('Add Topic'),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> topicSlivers(
    TodoTopic topic,
    List<TodoTask> tasks,
    List<String> order,
  ) {
    final active = tasks
        .where((t) => !t.completed || pending.containsKey(t.id))
        .toList();
    final finished =
        tasks.where((t) => t.completed && !pending.containsKey(t.id)).toList()
          ..sort((a, b) {
            final date = DateTime.parse(
              b.completedAt!,
            ).compareTo(DateTime.parse(a.completedAt!));
            return date != 0 ? date : a.id.compareTo(b.id);
          });
    final inset = pageInset(context);
    final isExpanded = expanded.contains(topic.id);
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
        sliver: SliverToBoxAdapter(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: topicTitle(
                  topic,
                  order,
                  PopupMenuButton<String>(
                    key: ValueKey('topic-menu-${topic.id}'),
                    tooltip: '',
                    onSelected: (action) => action == 'rename'
                        ? editor(topic: topic)
                        : deleteTopic(topic),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename topic'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete topic'),
                      ),
                    ],
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        topic.title,
                        key: ValueKey('topic-${topic.id}'),
                        style: Theme.of(context).textTheme.titleMedium!
                            .copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: TextButton.icon(
                  key: ValueKey('add-task-${topic.id}'),
                  onPressed: () => editor(parent: topic.id),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Task'),
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        sliver: SliverReorderableList(
          key: ValueKey('active-${topic.id}'),
          itemCount: active.length,
          itemBuilder: (_, index) => row(active[index], index: index),
          proxyDecorator: (child, index, animation) => Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            elevation: 2,
            borderRadius: BorderRadius.circular(6),
            child: child,
          ),
          onReorderItem: (oldIndex, newIndex) {
            final reordered = [...active];
            reordered.insert(newIndex, reordered.removeAt(oldIndex));
            final c = ref.read(studyProvider);
            c.perform(
              () => c.repository.reorderTodoTasks(
                topic.id,
                reordered.where((t) => !t.completed).map((t) => t.id).toList(),
              ),
            );
          },
        ),
      ),
      if (finished.isNotEmpty) ...[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('finished-${topic.id}'),
                onPressed: () => setState(() {
                  if (isExpanded) {
                    expanded.remove(topic.id);
                  } else {
                    expanded.add(topic.id);
                  }
                }),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                ),
                icon: AnimatedRotation(
                  turns: isExpanded ? .25 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: const Icon(Icons.chevron_right, size: 18),
                ),
                label: Text(
                  'Finished Tasks (${finished.length})',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ),
        if (isExpanded)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverList.builder(
              itemCount: finished.length,
              itemBuilder: (_, i) => row(finished[i], finished: true),
            ),
          ),
      ],
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
        sliver: const SliverToBoxAdapter(child: Divider(height: 1)),
      ),
    ];
  }
}

// Animate whole groups between list slots while keeping the drag preview compact
class _TopicMotion extends StatefulWidget {
  final double slot;
  final GlobalKey boundsKey;
  final bool keepAlive;
  final Widget child;
  const _TopicMotion({
    super.key,
    required this.slot,
    required this.boundsKey,
    required this.keepAlive,
    required this.child,
  });

  @override
  State<_TopicMotion> createState() => _TopicMotionState();
}

class _TopicMotionState extends State<_TopicMotion>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  double displacement = 0;

  double get offset =>
      displacement * (1 - Curves.easeOutCubic.transform(animation.value));

  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(_TopicMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateKeepAlive();
    if (widget.slot != oldWidget.slot) {
      displacement = offset + oldWidget.slot - widget.slot;
      animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SizedBox(
      key: widget.boundsKey,
      child: AnimatedBuilder(
        animation: animation,
        child: widget.child,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, offset),
          transformHitTests: false,
          child: child,
        ),
      ),
    );
  }
}

class _TodoEditor extends ConsumerStatefulWidget {
  final TodoTopic? topic;
  final TodoTask? task;
  final String? parent;
  const _TodoEditor({this.topic, this.task, this.parent});
  @override
  ConsumerState<_TodoEditor> createState() => _TodoEditorState();
}

class _TodoEditorState extends ConsumerState<_TodoEditor> {
  late final input = TextEditingController(
    text: widget.topic?.title ?? widget.task?.text ?? '',
  );
  String? error;
  bool get isTask => widget.task != null || widget.parent != null;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void save() {
    try {
      todoText(input.text);
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
    final c = ref.read(studyProvider);
    if (c.perform(() {
      if (widget.task != null) {
        c.repository.editTodoTask(widget.task!.id, input.text);
      } else if (widget.parent != null) {
        c.repository.addTodoTask(widget.parent!, input.text);
      } else if (widget.topic != null) {
        c.repository.renameTodoTopic(widget.topic!.id, input.text);
      } else {
        c.repository.addTodoTopic(input.text);
      }
    })) {
      Navigator.pop(context, true);
    } else {
      setState(() => error = c.error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.task != null
          ? 'Edit task'
          : widget.topic != null
          ? 'Rename topic'
          : isTask
          ? 'Add Task'
          : 'Add Topic',
    ),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: TextField(
          key: const ValueKey('todo-name'),
          controller: input,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => save(),
          decoration: InputDecoration(
            labelText: isTask ? 'Task' : 'Topic name',
            errorText: error,
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: save, child: const Text('Save')),
    ],
  );
}
