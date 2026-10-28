import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import '../domain/repository.dart';
import '../domain/week.dart';
import '../domain/planning.dart';

final repositoryProvider = Provider<StudyRepository>(
  (ref) => throw UnimplementedError('Repository must be supplied at startup'),
);
final studyProvider = ChangeNotifierProvider<StudyController>(
  (ref) => StudyController(ref.watch(repositoryProvider)),
);

class StudyController extends ChangeNotifier with WidgetsBindingObserver {
  final StudyRepository repository;
  final DateTime Function() clock;
  late Week current, selected;
  List<WeeklyProgress> progress = [];
  String? error;
  Timer? _timer;
  StudyController(
    this.repository, {
    DateTime Function()? clock,
    bool watchClock = true,
  }) : clock = clock ?? DateTime.now {
    current = Week.containing(this.clock());
    selected = current;
    refresh();
    if (watchClock) {
      WidgetsBinding.instance.addObserver(this);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => checkClock());
    }
  }
  bool get editable => selected == current;
  List<StudyTab> get tabOrder =>
      StudyTabOrder.decode(repository.preference('tab.order', ''));
  void reorderTab(int oldIndex, int newIndex) {
    final tabs = tabOrder.toList();
    if (oldIndex < 0 ||
        oldIndex >= tabs.length ||
        newIndex < 0 ||
        newIndex >= tabs.length) {
      return;
    }
    tabs.insert(newIndex, tabs.removeAt(oldIndex));
    perform(
      () => repository.setPreference(
        'tab.order',
        jsonEncode(tabs.map((tab) => tab.name).toList()),
      ),
    );
  }

  List<StudyTab> get enabledTabs {
    final order = tabOrder;
    final enabled = order
        .where(
          (tab) => repository.preference('tab.${tab.name}', 'true') != 'false',
        )
        .toList();
    // Keep malformed or restored preferences navigable without changing data
    return enabled.isEmpty ? [order.first] : enabled;
  }

  bool tabVisible(StudyTab tab) => enabledTabs.contains(tab);
  bool setTabVisible(StudyTab tab, bool visible) {
    if (!visible && tabVisible(tab) && enabledTabs.length == 1) return false;
    return perform(
      () => repository.setPreference('tab.${tab.name}', '$visible'),
    );
  }

  void reorderCategory(int oldIndex, int newIndex) {
    checkClock();
    if (!editable) return;
    final categories = repository.categories();
    final active = categories
        .where((category) => category.active && !category.archived)
        .toList();
    if (oldIndex < 0 ||
        oldIndex >= active.length ||
        newIndex < 0 ||
        newIndex >= active.length) {
      return;
    }
    active.insert(newIndex, active.removeAt(oldIndex));
    reorderBars(active.map((category) => category.id).toList());
  }

  void reorderBars(List<String> activeIds) {
    checkClock();
    if (!editable) return;
    final categories = repository.categories();
    final active = categories
        .where((c) => c.active && !c.archived)
        .map((c) => c.id)
        .toSet();
    if (activeIds.length != active.length ||
        activeIds.toSet().length != activeIds.length ||
        !active.containsAll(activeIds)) {
      error = 'Bars changed. Try dragging again.';
      notifyListeners();
      return;
    }
    var index = 0;
    // Keep archived slots so restoration retains a sensible existing position
    final ids = [
      for (final category in categories)
        active.contains(category.id) ? activeIds[index++] : category.id,
    ];
    perform(() => repository.reorder(ids));
  }

  void archiveBar(String id, bool archived, Week expectedWeek) {
    checkClock();
    if (!editable || current != expectedWeek) {
      error = 'The selected week changed. Return to this week and try again.';
      notifyListeners();
      return;
    }
    perform(
      () => repository.setCategoryStatus(
        id,
        current: current,
        active: !archived,
        archived: archived,
      ),
    );
  }

  ThemeMode get theme => ThemeMode.values.firstWhere(
    (v) => v.name == repository.preference('theme', 'system'),
    orElse: () => ThemeMode.system,
  );
  void setTheme(ThemeMode value) =>
      perform(() => repository.setPreference('theme', value.name));
  void refresh() {
    try {
      progress = repository.loadWeek(selected, current: current);
      error = null;
    } catch (e) {
      error = 'Could not load your data. $e';
    }
    notifyListeners();
  }

  bool perform(void Function() operation) {
    try {
      operation();
      refresh();
      return error == null;
    } catch (e) {
      error = e is FormatException
          ? e.message
          : 'Changes could not be saved. $e';
      notifyListeners();
      return false;
    }
  }

  void checkClock() {
    final next = Week.containing(clock());
    if (next != current) {
      final following = selected == current;
      current = next;
      if (following || selected.compareTo(current) > 0) {
        selected = current;
      }
      refresh();
    }
  }

  void navigate(Week week) {
    checkClock();
    if (week.compareTo(current) <= 0) {
      selected = week;
      refresh();
    }
  }

  bool add(WeeklyProgress p, String input) {
    checkClock();
    return perform(
      () => repository.commit(
        p.goalId,
        Amount.parse(
          input,
          discrete: p.config.measurement == Measurement.discrete,
        ),
        current,
      ),
    );
  }

  void undo(WeeklyProgress p) {
    checkClock();
    perform(() => repository.undo(p.goalId, current));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkClock();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_timer != null) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
