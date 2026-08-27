import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';

/// The Quick Find field and its rows, for tests.
const quickFindFieldKey = Key('quick-find-field');
Key quickFindResultKey(int index) => ValueKey(('quick-find', index));

/// Opens Quick Find (#76) with [seed] already typed — the character that
/// summoned it, or nothing for ⌘K. An anonymous route above the chrome:
/// while it is up the chrome's chords and the typing trigger are inert,
/// so the dialog binds its own keys.
Future<void> showQuickFind(BuildContext context, {String seed = ''}) =>
    showDialog<void>(
      context: context,
      builder: (context) => QuickFindDialog(seed: seed),
    );

/// Type, see the matches, ↑↓ to choose, ⏎ to open, Esc to leave. The raw
/// text lives in the field; every keystroke re-runs the pure matcher over
/// the projection, so results are never stale and nothing debounces.
class QuickFindDialog extends ConsumerStatefulWidget {
  const QuickFindDialog({super.key, this.seed = ''});

  final String seed;

  @override
  ConsumerState<QuickFindDialog> createState() => _QuickFindDialogState();
}

class _QuickFindDialogState extends ConsumerState<QuickFindDialog> {
  late final _controller = TextEditingController(text: widget.seed)
    ..selection = TextSelection.collapsed(offset: widget.seed.length);
  var _index = 0;
  var _rowKeys = <GlobalKey>[];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTyped);
    _controller.dispose();
    super.dispose();
  }

  void _onTyped() => setState(() => _index = 0);

  void _move(int by, int count) {
    if (count == 0) return;
    setState(() => _index = (_index + by).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _rowKeys.elementAtOrNull(_index)?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(context, alignment: 0.5);
      }
    });
  }

  void _open(FindResult result) {
    final commands = AppCommands.of(context);
    Navigator.of(context).pop();
    commands.open(result);
  }

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final projection = ref.watch(tasksProvider).value;
    final today = ref.watch(todayProvider);
    final results = projection == null
        ? const <FindResult>[]
        : findInTasks(projection, _controller.text, today: today);
    if (_rowKeys.length != results.length) {
      _rowKeys = [for (var i = 0; i < results.length; i++) GlobalKey()];
    }
    final index = results.isEmpty ? -1 : _index.clamp(0, results.length - 1);
    return Dialog(
      alignment: const Alignment(0, -0.6),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _move(1, results.length),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _move(-1, results.length),
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (index >= 0) _open(results[index]);
          },
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Quick Find', dim: true),
                const SizedBox(height: 8),
                TextField(
                  key: quickFindFieldKey,
                  controller: _controller,
                  autofocus: true,
                  style: text.body,
                  decoration: const InputDecoration(
                    hintText: 'Lists, areas, projects, headings, tags, tasks',
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text('Nothing matches.', style: text.bodyDim),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final (i, result) in results.indexed) ...[
                              if (i == 0 || results[i - 1].kind != result.kind)
                                Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    8,
                                    i == 0 ? 0 : 12,
                                    8,
                                    4,
                                  ),
                                  child: Eyebrow(_kindTitle(result.kind)),
                                ),
                              _ResultRow(
                                key: _rowKeys[i],
                                index: i,
                                result: result,
                                highlighted: i == index,
                                onOpen: () => _open(result),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _kindTitle(FindResultKind kind) => switch (kind) {
  FindResultKind.list || FindResultKind.trash => 'Lists',
  FindResultKind.area => 'Areas',
  FindResultKind.project => 'Projects',
  FindResultKind.heading => 'Headings',
  FindResultKind.tag => 'Tags',
  FindResultKind.task => 'Tasks',
};

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    super.key,
    required this.index,
    required this.result,
    required this.highlighted,
    required this.onOpen,
  });

  final int index;
  final FindResult result;
  final bool highlighted;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final detail = result.detail;
    return Semantics(
      button: true,
      selected: highlighted,
      label: detail == null ? result.title : '${result.title}, $detail',
      child: ExcludeSemantics(
        child: InkWell(
          key: quickFindResultKey(index),
          onTap: onOpen,
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: highlighted ? SaiColors.ink : null,
              borderRadius: const BorderRadius.all(
                Radius.circular(SaiRadius.small),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    result.title,
                    style: text.body.copyWith(
                      color: highlighted ? SaiColors.onInk : SaiColors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    detail.toUpperCase(),
                    style: text.chip.copyWith(
                      color: highlighted ? SaiColors.onInk : SaiColors.inkDim,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
