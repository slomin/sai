import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A text field that edits in place and commits the whole value when it
/// is left — blur, Enter (one line) or ⌘⏎ (many) — never per keystroke,
/// so an edit is one archive event and one undo entry. Escape puts the
/// stored value back and leaves. While the field is not focused an
/// outside change re-seeds it; while it is, the draft wins.
///
/// [onCommit] returns whether the store took the value; a refusal keeps
/// the draft so nothing typed is lost.
class CommitField extends StatefulWidget {
  const CommitField({
    super.key,
    required this.value,
    required this.onCommit,
    this.style,
    this.hint,
    this.multiline = false,
    this.minLines,
    this.semanticsLabel,
    this.decoration,
  });

  final String value;
  final Future<bool> Function(String value) onCommit;
  final TextStyle? style;
  final String? hint;
  final bool multiline;
  final int? minLines;
  final String? semanticsLabel;
  final InputDecoration? decoration;

  @override
  State<CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<CommitField> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'commit-field');

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(CommitField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && !_focus.hasFocus) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _commit();
  }

  Future<void> _commit() async {
    final text = _controller.text;
    if (text == widget.value) return;
    await widget.onCommit(text);
  }

  void _revert() {
    _controller.text = widget.value;
    _focus.unfocus();
  }

  void _done() {
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _revert,
        if (widget.multiline)
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _done,
      },
      child: Semantics(
        label: widget.semanticsLabel,
        textField: true,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          style: widget.style,
          maxLines: widget.multiline ? null : 1,
          minLines: widget.multiline ? widget.minLines : null,
          keyboardType: widget.multiline
              ? TextInputType.multiline
              : TextInputType.text,
          textInputAction: widget.multiline
              ? TextInputAction.newline
              : TextInputAction.done,
          onSubmitted: widget.multiline ? null : (_) => _done(),
          decoration:
              widget.decoration ??
              InputDecoration(
                hintText: widget.hint,
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
        ),
      ),
    );
  }
}
