import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../domain/week.dart';

bool phoneLayout(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.android &&
    MediaQuery.sizeOf(context).width < 600;

double pageInset(BuildContext context, {double desktop = 34}) =>
    phoneLayout(context) ? 16 : desktop;

String weekLabel(Week week) {
  final a = week.start, b = week.end;
  return a.month == b.month
      ? '${a.day}-${DateFormat('d MMMM yyyy').format(b)}'
      : '${DateFormat('d MMM').format(a)} - ${DateFormat('d MMM yyyy').format(b)}';
}

void showFailure(BuildContext context, Object error) {
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error is FormatException ? error.message : '$error'),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String action = 'Continue',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
