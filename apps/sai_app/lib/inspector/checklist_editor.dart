import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'commit_field.dart';
import '../widgets/glyph_button.dart';

/// The "add an item" field, for tests.
const checklistAddKey = Key('checklist-add');

/// The keys of an item's box and its remove cross, by position.
Key checklistBoxKey(int index) => ValueKey('checklist-box-$index');
Key checklistRemoveKey(int index) => ValueKey('checklist-remove-$index');

/// The CHECKLIST block as the reference draws it: the label with `n OF m`,
/// a row per item — the small box toggles, the title edits in place, the
/// cross removes — and the `+ Add an item` row. Items have no identity in
/// v0.1, so every change replaces the whole list (`task.checklist`).
class ChecklistEditor extends StatefulWidget {
  const ChecklistEditor({
    super.key,
    required this.items,
    required this.onChanged,
    required this.now,
  });

  final List<ChecklistItem> items;
  final Future<bool> Function(List<ChecklistItem> items) onChanged;
  final DateTime Function() now;

  @override
  State<ChecklistEditor> createState() => _ChecklistEditorState();
}

class _ChecklistEditorState extends State<ChecklistEditor> {
  final _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<bool> _replace(int index, ChecklistItem? item) => widget.onChanged([
    for (final (i, existing) in widget.items.indexed)
      if (i != index) existing else ?item,
  ]);

  Future<void> _submitNew(String line) async {
    final title = line.trim();
    if (title.isEmpty) return;
    _add.clear();
    final ok = await widget.onChanged([
      ...widget.items,
      ChecklistItem(title: title),
    ]);
    if (!ok && mounted && _add.text.isEmpty) _add.text = line;
  }

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final items = widget.items;
    final done = items.where((i) => i.completedAt != null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Text('CHECKLIST', style: text.eyebrowDim),
              const SizedBox(width: 10),
              if (items.isNotEmpty)
                Text('$done OF ${items.length}', style: text.meta),
            ],
          ),
        ),
        for (final (index, item) in items.indexed)
          _ItemRow(
            index: index,
            item: item,
            onToggle: () => _replace(
              index,
              ChecklistItem(
                title: item.title,
                completedAt: item.completedAt == null ? widget.now() : null,
              ),
            ),
            onRename: (title) => title.trim().isEmpty
                ? Future.value(false)
                : _replace(
                    index,
                    ChecklistItem(
                      title: title.trim(),
                      completedAt: item.completedAt,
                    ),
                  ),
            onRemove: () => _replace(index, null),
          ),
        Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: SaiColors.rule)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 27,
                child: Text(
                  '+',
                  textAlign: TextAlign.center,
                  style: text.meta.copyWith(fontSize: 14),
                ),
              ),
              Expanded(
                child: TextField(
                  key: checklistAddKey,
                  controller: _add,
                  style: text.body,
                  onSubmitted: _submitNew,
                  decoration: InputDecoration(
                    hintText: 'Add an item',
                    hintStyle: text.body.copyWith(color: SaiColors.inkFaint),
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.index,
    required this.item,
    required this.onToggle,
    required this.onRename,
    required this.onRemove,
  });

  final int index;
  final ChecklistItem item;
  final VoidCallback onToggle;
  final Future<bool> Function(String) onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final done = item.completedAt != null;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SaiColors.rule)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Semantics(
            label: done ? 'Reopen ${item.title}' : 'Complete ${item.title}',
            checked: done,
            button: true,
            excludeSemantics: true,
            child: GestureDetector(
              key: checklistBoxKey(index),
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Container(
                  width: 15,
                  height: 15,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: done ? SaiColors.ink : null,
                    border: Border.all(
                      color: done ? SaiColors.ink : SaiColors.ruleMid,
                    ),
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                  child: done
                      ? Text(
                          '✓',
                          style: context.saiText.meta.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: SaiColors.onInk,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          Expanded(
            child: CommitField(
              value: item.title,
              onCommit: onRename,
              semanticsLabel: 'Checklist item ${index + 1}',
              style: text.body.copyWith(
                color: done ? SaiColors.inkFaint : SaiColors.ink,
                decoration: done ? TextDecoration.lineThrough : null,
                decorationColor: SaiColors.inkFaint,
              ),
            ),
          ),
          GlyphButton(
            key: checklistRemoveKey(index),
            glyph: '✕',
            label: 'Remove ${item.title}',
            color: SaiColors.inkFaint,
            size: 12,
            minSize: 26,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
