import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/sai_dialog.dart';
import '../workspace/dates.dart';
import 'field_row.dart';

/// The WHEN row: Today, Tomorrow, Someday, a picked date, or no plan.
class WhenMenu extends StatelessWidget {
  const WhenMenu({
    super.key,
    required this.when,
    required this.today,
    required this.onChanged,
  });

  final TaskWhen when;
  final CalendarDate today;
  final ValueChanged<TaskWhen> onChanged;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => onChanged(TaskWhen.date(today)),
          child: const Text('Today'),
        ),
        MenuItemButton(
          onPressed: () => onChanged(TaskWhen.date(today.addDays(1))),
          child: const Text('Tomorrow'),
        ),
        MenuItemButton(
          onPressed: () => onChanged(TaskWhen.someday),
          child: const Text('Someday'),
        ),
        MenuItemButton(
          onPressed: () async {
            final picked = await pickDate(
              context,
              eyebrow: 'When',
              title: 'Pick a day',
              initial: when is TaskWhenDate
                  ? (when as TaskWhenDate).date
                  : today,
            );
            if (picked != null) onChanged(TaskWhen.date(picked));
          },
          child: const Text('Pick a date…'),
        ),
        MenuItemButton(
          onPressed: () => onChanged(TaskWhen.none),
          child: const Text('No plan'),
        ),
      ],
      builder: (context, controller, _) => InspectorValueButton(
        label: 'When',
        value: whenLabel(when, today: today),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The DEADLINE row: today, tomorrow, a picked date, or none — red once
/// the day has come.
class DeadlineMenu extends StatelessWidget {
  const DeadlineMenu({
    super.key,
    required this.deadline,
    required this.today,
    required this.onChanged,
  });

  final CalendarDate? deadline;
  final CalendarDate today;
  final ValueChanged<CalendarDate?> onChanged;

  @override
  Widget build(BuildContext context) {
    final due = deadline != null && deadline! <= today;
    final text = context.saiText;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => onChanged(today),
          child: const Text('Today'),
        ),
        MenuItemButton(
          onPressed: () => onChanged(today.addDays(1)),
          child: const Text('Tomorrow'),
        ),
        MenuItemButton(
          onPressed: () async {
            final picked = await pickDate(
              context,
              eyebrow: 'Deadline',
              title: 'Pick a day',
              initial: deadline ?? today,
            );
            if (picked != null) onChanged(picked);
          },
          child: const Text('Pick a date…'),
        ),
        MenuItemButton(
          onPressed: () => onChanged(null),
          child: const Text('None'),
        ),
      ],
      builder: (context, controller, _) => InspectorValueButton(
        label: 'Deadline',
        value: deadline == null ? 'None' : shortDay(deadline!).toUpperCase(),
        style: deadline == null
            ? text.bodyDim
            : text.meta.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: due ? SaiColors.red : SaiColors.ink,
              ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
