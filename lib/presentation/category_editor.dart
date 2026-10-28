import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_controller.dart';
import '../domain/models.dart';
import 'common.dart';

class CategoryEditor extends ConsumerStatefulWidget {
  final Category? category;
  const CategoryEditor({super.key, this.category});
  @override
  ConsumerState<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<CategoryEditor> {
  late Measurement type =
      widget.category?.config.measurement ?? Measurement.continuous;
  late final name = TextEditingController(
        text: widget.category?.config.name ?? '',
      ),
      unit = TextEditingController(text: widget.category?.config.unit ?? 'h'),
      floor = TextEditingController(
        text: Amount.format(widget.category?.config.floor ?? 200),
      ),
      target = TextEditingController(
        text: Amount.format(widget.category?.config.target ?? 400),
      ),
      increment = TextEditingController(
        text: Amount.format(widget.category?.config.increment ?? 100),
      ),
      step = TextEditingController(
        text: Amount.format(widget.category?.config.step ?? 25),
      );
  String? error;
  @override
  void dispose() {
    for (final f in [name, unit, floor, target, increment, step]) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.category == null ? 'Add category' : 'Edit category'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<Measurement>(
              isExpanded: phoneLayout(context),
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Measurement'),
              items: const [
                DropdownMenuItem(
                  value: Measurement.continuous,
                  child: Text('Continuous'),
                ),
                DropdownMenuItem(
                  value: Measurement.discrete,
                  child: Text('Discrete count'),
                ),
              ],
              onChanged: (v) => setState(() {
                type = v!;
                if (type == Measurement.discrete) {
                  step.text = '1';
                  unit.clear();
                } else {
                  step.text = '0.25';
                  unit.text = 'h';
                }
              }),
            ),
            for (final f in [
              (unit, 'Display unit (h, count or custom)'),
              (floor, 'Floor'),
              (target, 'Target'),
              (increment, 'Default addition'),
              (step, 'Arrow-key step / precision'),
            ])
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextField(
                  controller: f.$1,
                  decoration: InputDecoration(labelText: f.$2),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
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
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final discrete = type == Measurement.discrete;
            final config = GoalConfig(
              name: name.text,
              measurement: type,
              unit: unit.text,
              floor: Amount.parse(
                floor.text,
                discrete: discrete,
                allowZero: true,
              ),
              target: Amount.parse(target.text, discrete: discrete),
              increment: Amount.parse(increment.text, discrete: discrete),
              step: Amount.parse(step.text, discrete: discrete),
            );
            config.validate();
            final c = ref.read(studyProvider);
            c.checkClock();
            if (c.perform(
              () => c.repository.saveCategory(
                widget.category?.id,
                config,
                c.current,
              ),
            )) {
              Navigator.pop(context);
            } else {
              setState(() => error = c.error);
            }
          } catch (e) {
            setState(() => error = e is FormatException ? e.message : '$e');
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
