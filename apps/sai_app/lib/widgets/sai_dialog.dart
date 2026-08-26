import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'eyebrow.dart';

/// The dialog's field, primary action and the optional check, for tests.
const dialogFieldKey = Key('dialog-field');
const dialogPrimaryKey = Key('dialog-primary');
const dialogOptionKey = Key('dialog-option');

/// The one dialog frame (#74): an eyebrow, a title, a body, and the
/// actions — the primary red only when it is destructive, ink otherwise.
/// Dialogs are anonymous routes closed with `Navigator.pop`.
class SaiDialog extends StatelessWidget {
  const SaiDialog({
    super.key,
    required this.eyebrow,
    required this.title,
    this.body,
    required this.actions,
  });

  final String eyebrow;
  final String title;
  final Widget? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Eyebrow(eyebrow, dim: true),
              const SizedBox(height: 8),
              Semantics(
                header: true,
                child: Text(title, style: text.emptyTitle),
              ),
              if (body case final body?) ...[const SizedBox(height: 14), body],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (i, action) in actions.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    action,
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The red button that carries a destructive or primary action.
class SaiPrimaryButton extends StatelessWidget {
  const SaiPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      key: key == null ? dialogPrimaryKey : null,
      style: destructive
          ? FilledButton.styleFrom(
              backgroundColor: SaiColors.red,
              foregroundColor: SaiColors.white,
            )
          : null,
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// Asks for one line — a name — and returns it trimmed, or null when the
/// dialog is dismissed or the line is blank.
Future<String?> promptForTitle(
  BuildContext context, {
  required String eyebrow,
  required String title,
  String initial = '',
  String confirm = 'Save',
}) => showDialog<String>(
  context: context,
  builder: (context) => _Prompt(
    eyebrow: eyebrow,
    title: title,
    initial: initial,
    confirm: confirm,
  ),
);

class _Prompt extends StatefulWidget {
  const _Prompt({
    required this.eyebrow,
    required this.title,
    required this.initial,
    required this.confirm,
  });

  final String eyebrow;
  final String title;
  final String initial;
  final String confirm;

  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final line = _controller.text.trim();
    Navigator.of(context).pop(line.isEmpty ? null : line);
  }

  @override
  Widget build(BuildContext context) {
    return SaiDialog(
      eyebrow: widget.eyebrow,
      title: widget.title,
      body: TextField(
        key: dialogFieldKey,
        controller: _controller,
        autofocus: true,
        onSubmitted: (_) => _submit(),
        style: context.saiText.body,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder(
          valueListenable: _controller,
          builder: (context, value, _) => SaiPrimaryButton(
            label: widget.confirm,
            onPressed: value.text.trim().isEmpty ? null : _submit,
          ),
        ),
      ],
    );
  }
}

/// What a confirmation came back with: whether it was confirmed, and
/// whether its optional check was on.
typedef Confirmation = ({bool confirmed, bool option});

/// A destructive confirmation: [body] says what happens, [option] (when
/// given) is a check the person can leave on or turn off — the safe
/// task-move path before a container goes.
Future<Confirmation> confirmAction(
  BuildContext context, {
  required String eyebrow,
  required String title,
  required String body,
  required String confirm,
  String? option,
  bool optionDefault = true,
}) async {
  final result = await showDialog<Confirmation>(
    context: context,
    builder: (context) => _Confirm(
      eyebrow: eyebrow,
      title: title,
      body: body,
      confirm: confirm,
      option: option,
      optionDefault: optionDefault,
    ),
  );
  return result ?? (confirmed: false, option: false);
}

class _Confirm extends StatefulWidget {
  const _Confirm({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.confirm,
    required this.option,
    required this.optionDefault,
  });

  final String eyebrow;
  final String title;
  final String body;
  final String confirm;
  final String? option;
  final bool optionDefault;

  @override
  State<_Confirm> createState() => _ConfirmState();
}

class _ConfirmState extends State<_Confirm> {
  late var _option = widget.optionDefault;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return SaiDialog(
      eyebrow: widget.eyebrow,
      title: widget.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.body, style: text.bodyDim),
          if (widget.option case final option?)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: CheckboxListTile(
                key: dialogOptionKey,
                value: _option,
                onChanged: (v) => setState(() => _option = v ?? false),
                title: Text(option, style: text.body),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep'),
        ),
        SaiPrimaryButton(
          label: widget.confirm,
          destructive: true,
          onPressed: () =>
              Navigator.of(context).pop((confirmed: true, option: _option)),
        ),
      ],
    );
  }
}

/// Picks a calendar day, or returns null when dismissed.
Future<CalendarDate?> pickDate(
  BuildContext context, {
  required String eyebrow,
  required String title,
  required CalendarDate initial,
}) async {
  final picked = await showDialog<DateTime>(
    context: context,
    builder: (context) => SaiDialog(
      eyebrow: eyebrow,
      title: title,
      body: SizedBox(
        width: 360,
        child: CalendarDatePicker(
          initialDate: DateTime(initial.year, initial.month, initial.day),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
          onDateChanged: (date) => Navigator.of(context).pop(date),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  return picked == null ? null : CalendarDate.fromLocal(picked);
}
