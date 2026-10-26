import 'dart:math' as math;
import 'package:flutter/material.dart';

class AndroidNavigationBar extends StatelessWidget {
  const AndroidNavigationBar({
    super.key,
    required this.title,
    required this.onOpenDrawer,
    required this.onSettings,
  });

  final String title;
  final VoidCallback onOpenDrawer;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Open navigation menu',
          style: IconButton.styleFrom(minimumSize: const Size.square(48)),
          onPressed: onOpenDrawer,
          icon: const Icon(Icons.menu),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            key: const ValueKey('android-tab-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium!.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Settings',
          style: IconButton.styleFrom(minimumSize: const Size.square(48)),
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined, size: 20),
        ),
      ],
    ),
  );
}

class AndroidTabDrawer extends StatelessWidget {
  const AndroidTabDrawer({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Drawer(
    width: math.min(MediaQuery.sizeOf(context).width * 0.85, 360),
    child: SafeArea(
      child: ListView(padding: const EdgeInsets.all(8), children: children),
    ),
  );
}

class AndroidTabItem extends StatelessWidget {
  const AndroidTabItem({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    selected: selected,
    selectedColor: Theme.of(context).colorScheme.primary,
    selectedTileColor: Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.08),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    minTileHeight: 56,
    minVerticalPadding: 12,
    title: Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
    onTap: onTap,
  );
}
