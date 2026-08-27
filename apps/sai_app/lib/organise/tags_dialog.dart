import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/sai_dialog.dart';
import 'organise_commands.dart';

/// The dialog's rows and buttons, for tests.
const newTagKey = Key('new-tag');
Key tagRowKey(TagId tag) => ValueKey('tag-row-$tag');
Key renameTagKey(TagId tag) => ValueKey('rename-tag-$tag');
Key deleteTagKey(TagId tag) => ValueKey('delete-tag-$tag');

/// Opens the tags manager (#74): every live tag with how many open tasks
/// carry it, rename and delete per row, and a new tag. Tags have no
/// order (they sort by title) and no archive — a deleted tag drops off
/// its tasks' chips and undo brings it back.
Future<void> showTagsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => const TagsDialog(),
);

class TagsDialog extends ConsumerWidget {
  const TagsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projection = ref.watch(tasksProvider).value;
    final organise = ref.read(organiseCommandsProvider);
    final text = context.saiText;
    final tags = [
      for (final tag in projection?.tags.values ?? const <Tag>[])
        if (tag.deletedAt == null) tag,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    int count(TagId tag) => projection == null
        ? 0
        : projection.tasks.values
              .where(
                (t) =>
                    t.deletedAt == null &&
                    t.status == TaskStatus.open &&
                    t.tags.contains(tag),
              )
              .length;

    Future<void> rename(Tag tag) async {
      final title = await promptForTitle(
        context,
        eyebrow: 'Tag',
        title: 'Rename “${tag.title}”',
        initial: tag.title,
        confirm: 'Rename',
      );
      if (title != null && title != tag.title) {
        await organise.renameTag(tag.id, title);
      }
    }

    Future<void> delete(Tag tag) async {
      final n = count(tag.id);
      final answer = await confirmAction(
        context,
        eyebrow: 'Tag',
        title: 'Delete “${tag.title}”?',
        body: n == 0
            ? 'No open task carries it. The archive keeps its history.'
            : '$n open task${n == 1 ? '' : 's'} carr${n == 1 ? 'ies' : 'y'} it '
                  'and will lose the chip. The archive keeps its history.',
        confirm: 'Delete',
      );
      if (answer.confirmed) await organise.deleteTag(tag.id);
    }

    Future<void> create() async {
      final title = await promptForTitle(
        context,
        eyebrow: 'Tag',
        title: 'New tag',
        confirm: 'Create',
      );
      if (title != null) await organise.createTag(title);
    }

    return SaiDialog(
      eyebrow: 'Tags',
      title: 'Manage tags',
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: tags.isEmpty
            ? Text('No tags yet.', style: text.bodyDim)
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final tag in tags)
                    Container(
                      key: tagRowKey(tag.id),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: SaiColors.rule),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: Text(tag.title, style: text.body)),
                          Text('${count(tag.id)}', style: text.meta),
                          const SizedBox(width: 8),
                          TextButton(
                            key: renameTagKey(tag.id),
                            onPressed: () => rename(tag),
                            child: const Text('Rename'),
                          ),
                          TextButton(
                            key: deleteTagKey(tag.id),
                            onPressed: () => delete(tag),
                            child: const Text('Delete…'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: newTagKey,
          onPressed: create,
          child: const Text('New tag…'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
