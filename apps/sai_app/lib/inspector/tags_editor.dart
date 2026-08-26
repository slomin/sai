import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/glyph_button.dart';

/// The tag field, for tests.
const tagFieldKey = Key('tag-field');

/// The key of a tag chip's remove affordance.
Key removeTagKey(TagId tag) => ValueKey('remove-tag-$tag');

/// The TAGS row: the task's tags as chips each with its cross, and a
/// field that completes from the live tags — Enter on a name nobody has
/// creates it. Every change is one `task.edit` of the whole list.
class TagsEditor extends StatefulWidget {
  const TagsEditor({
    super.key,
    required this.task,
    required this.projection,
    required this.onChanged,
    required this.onCreate,
    required this.onManage,
  });

  final Task task;
  final TaskProjection projection;
  final ValueChanged<List<TagId>> onChanged;

  /// Creates a tag and returns its id, or null when the store refused.
  final Future<TagId?> Function(String title) onCreate;
  final VoidCallback onManage;

  @override
  State<TagsEditor> createState() => _TagsEditorState();
}

class _TagsEditorState extends State<TagsEditor> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'tag-field');

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Tag> _candidates(String prefix) {
    final have = widget.task.tags.toSet();
    final needle = prefix.trim().toLowerCase();
    return [
      for (final tag in widget.projection.tags.values)
        if (tag.deletedAt == null &&
            !have.contains(tag.id) &&
            (needle.isEmpty || tag.title.toLowerCase().contains(needle)))
          tag,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  /// The task's tags that still exist: a tag deleted through the manager
  /// keeps its id on the task, and the store refuses a list naming it,
  /// so every patch is built from the live ids.
  List<TagId> get _live => [
    for (final id in widget.task.tags)
      if (widget.projection.tags[id] case final tag? when tag.deletedAt == null)
        id,
  ];

  void _add(TagId tag) {
    _controller.clear();
    if (_live.contains(tag)) return;
    widget.onChanged([..._live, tag]);
  }

  void _remove(TagId tag) => widget.onChanged([
    for (final id in _live)
      if (id != tag) id,
  ]);

  /// One submission path (the field's own Enter never selects): the tag
  /// with exactly this title, else the first suggestion — what the
  /// options list would have highlighted — else a new tag.
  Future<void> _submit(String line) async {
    final title = line.trim();
    if (title.isEmpty) return;
    final exact = widget.projection.tags.values
        .where(
          (t) =>
              t.deletedAt == null &&
              t.title.toLowerCase() == title.toLowerCase(),
        )
        .firstOrNull;
    if (exact != null) {
      _add(exact.id);
      return;
    }
    final candidates = _candidates(title);
    if (candidates.isNotEmpty) {
      _add(candidates.first.id);
      return;
    }
    final created = await widget.onCreate(title);
    if (created != null && mounted) _add(created);
  }

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final tags = [
      for (final id in widget.task.tags)
        if (widget.projection.tags[id] case final tag?
            when tag.deletedAt == null)
          tag,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final tag in tags)
                  _TagChip(tag: tag, onRemove: () => _remove(tag.id)),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: RawAutocomplete<Tag>(
                textEditingController: _controller,
                focusNode: _focus,
                optionsBuilder: (value) => _candidates(value.text),
                displayStringForOption: (tag) => tag.title,
                onSelected: (tag) => _add(tag.id),
                fieldViewBuilder: (context, controller, focus, onSubmit) =>
                    TextField(
                      key: tagFieldKey,
                      controller: controller,
                      focusNode: focus,
                      style: text.small,
                      onSubmitted: _submit,
                      decoration: const InputDecoration(
                        hintText: 'Add a tag',
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    color: SaiColors.bg,
                    elevation: 3,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(SaiRadius.medium),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 200,
                        maxWidth: 240,
                      ),
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: [
                          for (final tag in options)
                            InkWell(
                              onTap: () => onSelected(tag),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Text(tag.title, style: text.small),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: widget.onManage,
              child: const Text('Manage…'),
            ),
          ],
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.onRemove});

  final Tag tag;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2, right: 2),
      decoration: BoxDecoration(
        border: Border.all(color: SaiColors.ruleMid),
        borderRadius: const BorderRadius.all(Radius.circular(SaiRadius.small)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tag.title.toUpperCase(), style: context.saiText.chip),
          GlyphButton(
            key: removeTagKey(tag.id),
            glyph: '✕',
            label: 'Remove tag ${tag.title}',
            color: SaiColors.inkFaint,
            size: 11,
            minSize: 22,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
