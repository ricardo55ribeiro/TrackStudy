import 'package:flutter/material.dart';
import '../domain/planning.dart';

extension ScheduleColourPalette on ScheduleColour {
  Color background(Brightness brightness) => switch ((this, brightness)) {
    (ScheduleColour.black, _) => const Color(0xFF101114),
    (ScheduleColour.blue, Brightness.light) => const Color(0xFFDCE8F5),
    (ScheduleColour.orange, Brightness.light) => const Color(0xFFF4E2CF),
    (ScheduleColour.green, Brightness.light) => const Color(0xFFDDEBDD),
    (ScheduleColour.red, Brightness.light) => const Color(0xFFF2DDDF),
    (ScheduleColour.blue, Brightness.dark) => const Color(0xFF293E56),
    (ScheduleColour.orange, Brightness.dark) => const Color(0xFF513D2B),
    (ScheduleColour.green, Brightness.dark) => const Color(0xFF2D4536),
    (ScheduleColour.red, Brightness.dark) => const Color(0xFF513237),
  };

  Color foreground(Brightness brightness) =>
      this == ScheduleColour.black || brightness == Brightness.dark
      ? const Color(0xFFF4F4F4)
      : const Color(0xFF202830);
}

class PlanningColourSelector extends StatelessWidget {
  final ScheduleColour colour;
  final ValueChanged<ScheduleColour> onChanged;
  final String keyPrefix;
  const PlanningColourSelector({
    super.key,
    required this.colour,
    required this.onChanged,
    required this.keyPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          const Text('Colour'),
          const SizedBox(height: 4),
          SizedBox(
            width: 240,
            child: Row(
              children: [
                for (final option in ScheduleColour.values)
                  Expanded(
                    child: Semantics(
                      label: option.label,
                      button: true,
                      selected: colour == option,
                      child: Tooltip(
                        message: option.label,
                        excludeFromSemantics: true,
                        child: InkResponse(
                          key: ValueKey('$keyPrefix-colour-${option.name}'),
                          onTap: () => onChanged(option),
                          radius: 24,
                          child: SizedBox(
                            height: 48,
                            child: Center(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: option.background(brightness),
                                  border: Border.all(
                                    color: option
                                        .foreground(brightness)
                                        .withValues(
                                          alpha: colour == option ? .75 : .2,
                                        ),
                                    width: colour == option ? 2 : 1,
                                  ),
                                ),
                                child: colour == option
                                    ? Icon(
                                        Icons.check,
                                        size: 18,
                                        color: option.foreground(brightness),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PlanningColourMarker extends StatelessWidget {
  final ScheduleColour colour;
  const PlanningColourMarker({super.key, required this.colour});

  @override
  Widget build(BuildContext context) => Semantics(
    label: colour.label,
    child: Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour.background(Theme.of(context).brightness),
        border: Border.all(
          color: colour
              .foreground(Theme.of(context).brightness)
              .withValues(alpha: .4),
        ),
      ),
    ),
  );
}
