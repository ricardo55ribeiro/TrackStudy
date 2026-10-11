import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_controller.dart';
import '../application/sync_controller.dart';
import 'common.dart';
import 'dashboard.dart';
import 'journal.dart';
import 'review.dart';
import 'settings.dart';
import '../domain/planning.dart';
import 'schedule.dart';
import 'monthly.dart';

class TrackStudyApp extends ConsumerWidget {
  const TrackStudyApp({super.key});
  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff397ed9),
      brightness: brightness,
      surface: dark ? const Color(0xff151a22) : const Color(0xfffafbfc),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: defaultTargetPlatform == TargetPlatform.windows
          ? 'Segoe UI'
          : null,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.45),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: dark ? const Color(0xff202733) : const Color(0xfff0f3f7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 450),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.read(syncProvider);
    return MaterialApp(
      title: 'TrackStudy',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ref.watch(studyProvider).theme,
      builder: (context, child) {
        if (Theme.of(context).platform != TargetPlatform.android) {
          return child!;
        }
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: Theme.of(context).brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: child!,
        );
      },
      home: const StudyShell(),
    );
  }
}

class StudyShell extends ConsumerStatefulWidget {
  const StudyShell({super.key});
  @override
  ConsumerState<StudyShell> createState() => _StudyShellState();
}

class _StudyShellState extends ConsumerState<StudyShell> {
  StudyTab page = StudyTab.week;
  bool settingsOpen = false;
  final navigationScroll = ScrollController();
  @override
  void dispose() {
    navigationScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(studyProvider);
    final phone = phoneLayout(context);
    if (!c.tabVisible(page)) {
      page = StudyTab.week;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && navigationScroll.hasClients) navigationScroll.jumpTo(0);
      });
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              children: [
                Padding(
                  padding: phone
                      ? const EdgeInsets.fromLTRB(8, 8, 8, 4)
                      : const EdgeInsets.fromLTRB(28, 18, 20, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          controller: navigationScroll,
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final tab in c.tabOrder)
                                if (c.tabVisible(tab))
                                  TextButton(
                                    key: ValueKey('tab-${tab.name}'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: page == tab
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                    ),
                                    onPressed: () => setState(() => page = tab),
                                    child: Text(
                                      phone ? tab.compactLabel : tab.label,
                                      style: TextStyle(
                                        fontWeight: page == tab
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: () async {
                          setState(() => settingsOpen = true);
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => const SettingsScreen(),
                            ),
                          );
                          if (mounted) setState(() => settingsOpen = false);
                        },
                        icon: const Icon(Icons.settings_outlined, size: 20),
                      ),
                    ],
                  ),
                ),
                if (page == StudyTab.week || page == StudyTab.review)
                  Padding(
                    padding: phone
                        ? const EdgeInsets.fromLTRB(8, 0, 8, 10)
                        : const EdgeInsets.fromLTRB(26, 10, 26, 22),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous week',
                          onPressed: () => c.navigate(c.selected.shift(-1)),
                          icon: const Icon(Icons.chevron_left, size: 20),
                        ),
                        Flexible(
                          child: Text(
                            weekLabel(c.selected),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Next week',
                          onPressed: c.editable
                              ? null
                              : () => c.navigate(c.selected.shift(1)),
                          icon: const Icon(Icons.chevron_right, size: 20),
                        ),
                        if (!c.editable)
                          Flexible(
                            child: TextButton(
                              onPressed: () => c.navigate(c.current),
                              child: const Text('Past week · return to today'),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: c.refresh,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: StudyTab.values.indexOf(page),
                    children: [
                      for (final tab in StudyTab.values)
                        switch (tab) {
                          StudyTab.week => const Dashboard(),
                          StudyTab.journal => const JournalScreen(),
                          StudyTab.review => ReviewScreen(
                            key: ValueKey(
                              '${c.selected.key}-${identityHashCode(c)}',
                            ),
                          ),
                          StudyTab.schedule =>
                            page == StudyTab.schedule
                                ? ScheduleScreen(active: !settingsOpen)
                                : const SizedBox(),
                          StudyTab.month =>
                            page == StudyTab.month
                                ? const MonthlyScreen()
                                : const SizedBox(),
                        },
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
