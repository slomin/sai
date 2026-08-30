import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../organise/organise_commands.dart';
import '../organise/tags_dialog.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';
import '../widgets/sai_dialog.dart';
import '../workspace/dates.dart';
import '../workspace/move_sheet.dart';
import '../workspace/task_commands.dart';
import '../workspace/task_menu.dart';
import 'checklist_editor.dart';
import 'commit_field.dart';
import 'field_row.dart';
import 'tags_editor.dart';
import 'when_menu.dart';
import 'where_menu.dart';
import '../widgets/glyph_button.dart';

/// The inspector's parts, for tests.
const inspectorKey = Key('inspector');
const inspectorCloseKey = Key('inspector-close');
const inspectorTitleKey = Key('inspector-title');
const inspectorNotesKey = Key('inspector-notes');
const inspectorPrimaryKey = Key('inspector-primary');
const inspectorCancelKey = Key('inspector-cancel');
const inspectorDeleteKey = Key('inspector-delete');
const inspectorMoveKey = Key('inspector-move');

/// The reference's pane is 400 px beside the list; a narrower main column
/// gives the list 320 px and the pane the rest, down to 300. Below a
/// 620 px column there is no room for both: the pane stays hidden and
/// the selection waits.
double? inspectorWidth(double columnWidth) {
  if (columnWidth < 620) return null;
  return (columnWidth - 320).clamp(300.0, 400.0);
}

/// The task detail (#74): the selected task, edited in place. Opens when
/// a row is selected and closes with the selection; every field commits
/// whole, through [TaskCommands], and the store's own emission redraws
/// it — nothing here caches a task. Reads the task from the projection,
/// not the list's view, so an edit that moves the task out of the list
/// being shown leaves the inspector open on it.
class TaskInspector extends ConsumerWidget {
  const TaskInspector({super.key, required this.projection});

  final TaskProjection projection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedTaskProvider);
    final task = selected == null ? null : projection.task(selected);
    if (task == null) return const SizedBox.shrink();
    final today = ref.watch(todayProvider);
    final commands = ref.read(taskCommandsProvider);
    final organise = ref.read(organiseCommandsProvider);
    final text = context.saiText;
    final deleted = task.deletedAt != null;
    final open = task.status == TaskStatus.open;

    Future<void> delete() async {
      if (await confirmDeleteTask(context, task)) {
        await commands.delete(task.id);
      }
    }

    return Container(
      key: inspectorKey,
      decoration: const BoxDecoration(
        color: SaiColors.bg,
        border: Border(left: BorderSide(color: SaiColors.ink)),
      ),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              task: task,
              onClose: ref.read(selectedTaskProvider.notifier).clear,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                children: [
                  CommitField(
                    key: inspectorTitleKey,
                    value: task.title,
                    semanticsLabel: 'Title',
                    style: text.taskTitle,
                    onCommit: (v) => commands.edit(task.id, title: Patch(v)),
                  ),
                  const SizedBox(height: 12),
                  CommitField(
                    key: inspectorNotesKey,
                    value: task.notes,
                    semanticsLabel: 'Notes',
                    multiline: true,
                    minLines: 2,
                    hint: 'No notes yet. Markdown is fine here.',
                    style: text.body.copyWith(
                      color: SaiColors.inkDim,
                      height: 1.6,
                    ),
                    onCommit: (v) => commands.edit(task.id, notes: Patch(v)),
                  ),
                  const SizedBox(height: 22),
                  InspectorFieldRow(
                    label: 'When',
                    child: WhenMenu(
                      when: task.when,
                      today: today,
                      onChanged: (when) =>
                          commands.edit(task.id, when: Patch(when)),
                    ),
                  ),
                  InspectorFieldRow(
                    label: 'Deadline',
                    child: DeadlineMenu(
                      deadline: task.deadline,
                      today: today,
                      onChanged: (day) =>
                          commands.edit(task.id, deadline: Patch(day)),
                    ),
                  ),
                  InspectorFieldRow(
                    label: 'Where',
                    child: WhereMenu(
                      task: task,
                      projection: projection,
                      onMove: (to) => commands.move(
                        task.id,
                        project: to.project,
                        area: to.area,
                        heading: to.heading,
                      ),
                    ),
                  ),
                  InspectorFieldRow(
                    label: 'Tags',
                    child: TagsEditor(
                      task: task,
                      projection: projection,
                      onChanged: (tags) =>
                          commands.edit(task.id, tags: Patch(tags)),
                      onCreate: organise.createTag,
                      onManage: () => showTagsDialog(context),
                    ),
                  ),
                  if (!deleted)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: inspectorMoveKey,
                        onPressed: () => showMoveSheet(context, task.id),
                        child: const Text('Move / Schedule…'),
                      ),
                    ),
                  const SizedBox(height: 24),
                  ChecklistEditor(
                    items: task.checklist,
                    now: ref.read(clockProvider),
                    onChanged: (items) => commands.setChecklist(task.id, items),
                  ),
                  const SizedBox(height: 26),
                  _Evidence(task: task),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: SaiColors.rule)),
              ),
              child: Row(
                children: [
                  if (deleted)
                    SaiPrimaryButton(
                      key: inspectorPrimaryKey,
                      label: 'Restore',
                      onPressed: () => commands.restore(task.id),
                    )
                  else
                    SaiPrimaryButton(
                      key: inspectorPrimaryKey,
                      label: open ? 'Complete' : 'Reopen',
                      destructive: true,
                      onPressed: () => open
                          ? commands.complete(task.id)
                          : commands.reopen(task.id),
                    ),
                  if (open && !deleted) ...[
                    const SizedBox(width: 6),
                    TextButton(
                      key: inspectorCancelKey,
                      onPressed: () => commands.cancel(task.id),
                      child: const Text('Cancel'),
                    ),
                  ],
                  if (!deleted) ...[
                    const SizedBox(width: 2),
                    TextButton(
                      key: inspectorDeleteKey,
                      onPressed: delete,
                      child: const Text('Delete…'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The first six hex digits of an id, upper-cased — enough to tell rows
/// apart by eye.
String shortId(BlobRef id) {
  final hex = id.toString().split('-').last;
  return hex.substring(0, hex.length < 6 ? hex.length : 6).toUpperCase();
}

class _Header extends StatelessWidget {
  const _Header({required this.task, required this.onClose});

  final Task task;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 12, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SaiColors.rule)),
      ),
      child: Row(
        children: [
          Semantics(
            header: true,
            child: Eyebrow(
              task.deletedAt != null ? 'Task · in the trash' : 'Task',
              dim: true,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'HASHED · ${shortId(task.id)}',
              style: text.meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GlyphButton(
            key: inspectorCloseKey,
            glyph: '✕',
            label: 'Close inspector',
            color: SaiColors.inkDim,
            size: 16,
            minSize: 34,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The reference's evidence card: what the archive knows, in mono.
class _Evidence extends StatelessWidget {
  const _Evidence({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final line = text.meta.copyWith(height: 1.7, color: SaiColors.inkDim);
    final checklist = task.checklist.length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SaiColors.surf,
        border: Border.all(color: SaiColors.rule),
        borderRadius: const BorderRadius.all(Radius.circular(SaiRadius.large)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Text('EVIDENCE', style: text.eyebrowDim),
          ),
          Text('created ${shortStamp(task.createdAt)}', style: line),
          Text('last change ${shortStamp(task.modifiedAt)}', style: line),
          Text(
            '${task.deadline == null ? 'no deadline recorded' : 'deadline set ${shortDay(task.deadline!).toLowerCase()}'}'
            ' · ${checklist == 0 ? 'no checklist' : '$checklist checklist item${checklist == 1 ? '' : 's'}'}',
            style: line,
          ),
          if (task.completedAt case final at?)
            Text('completed ${shortStamp(at)}', style: line),
          if (task.cancelledAt case final at?)
            Text('cancelled ${shortStamp(at)}', style: line),
        ],
      ),
    );
  }
}
