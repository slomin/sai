import 'package:nocterm/nocterm.dart';
import 'package:sai_core/sai_core.dart';

/// The propose/confirm lane (#35), terminal shape: one row per
/// suggestion under the chat. Tab reaches it while a proposal is
/// shown, ↑↓ move the cursor, `y` (or Enter) accepts, `n` rejects,
/// Esc goes back to the chat; nothing changes until a `y`.
class SuggestionLaneTui extends StatelessComponent {
  const SuggestionLaneTui({
    super.key,
    required this.views,
    required this.note,
    required this.cursor,
    required this.focused,
  });

  final List<SuggestionView> views;
  final String note;
  final int cursor;
  final bool focused;

  @override
  Component build(BuildContext context) {
    return Column(
      children: [
        Text(
          'suggestions${note.isEmpty ? '' : ' · $note'}'
          '${focused ? '' : ' · Tab to review'}',
          style: TextStyle(color: Colors.gray),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        for (final (i, view) in views.indexed) _row(i, view),
      ],
    );
  }

  Component _row(int i, SuggestionView view) {
    final item = view.item;
    final at = focused && i == cursor;
    final status = switch (item.status) {
      SuggestionStatus.pending => view.stale ? ' [stale]' : '',
      SuggestionStatus.accepted => ' ✓ applied',
      SuggestionStatus.rejected => ' ✗ rejected',
      SuggestionStatus.failed => ' ! ${item.failure}',
    };
    final parts = item.kind == SuggestionKind.split
        ? ': ${item.parts.join(' · ')}'
        : '';
    final line =
        '${at ? '›' : ' '} ${i + 1} ${item.headline} — '
        '"${item.targetTitle}"$parts$status · ${item.reason}';
    final color = switch (item.status) {
      SuggestionStatus.rejected => Colors.gray,
      SuggestionStatus.failed => Colors.red,
      SuggestionStatus.pending when view.stale => Colors.yellow,
      _ => null,
    };
    return Text(
      line,
      style: TextStyle(color: color, reverse: at),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
