/// The assistant's composer (#39): a multi-line draft where Enter
/// sends, ⇧⏎ or ⌥⏎ breaks the line, and the platform's paste just
/// works. The draft and its focus live in `commands.dart`, so a
/// half-typed message survives the band being tucked away.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'chat_keys.dart';

class ChatComposer extends ConsumerWidget {
  const ChatComposer({super.key});

  /// Enter sends; everything else stays the field's. A [Focus] above
  /// the field rather than `CallbackShortcuts`, which cannot decline
  /// a key: an Enter carrying ⌘ or ⌃ belongs to the Task chords, and
  /// one confirming an IME composition belongs to the input method.
  KeyEventResult _onKey(
    TextEditingController draft,
    VoidCallback send,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      return KeyEventResult.ignored;
    }
    if (draft.value.composing.isValid) return KeyEventResult.ignored;
    if (keys.isShiftPressed || keys.isAltPressed) {
      _newline(draft);
      return KeyEventResult.handled;
    }
    send();
    return KeyEventResult.handled;
  }

  /// The break is inserted by hand rather than left to the platform:
  /// that is what makes ⌥⏎ work at all — AppKit maps it to a selector
  /// the embedder ignores — and what a test can assert.
  void _newline(TextEditingController draft) {
    final value = draft.value;
    final range = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    draft.value = value
        .replaced(range, '\n')
        .copyWith(
          selection: TextSelection.collapsed(offset: range.start + 1),
          composing: TextRange.empty,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatProvider);
    final commands = AppCommands.of(context);
    final text = context.saiText;
    final draft = ref.watch(chatDraftProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                error,
                style: text.small.copyWith(color: SaiColors.red),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Row(
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: (_, event) =>
                      _onKey(draft, commands.sendChat, event),
                  child: TextField(
                    key: chatFieldKey,
                    controller: draft,
                    focusNode: ref.watch(chatFocusProvider),
                    minLines: 1,
                    // Four lines, then the field scrolls: the band's
                    // height is fixed, and every line the composer
                    // grows is a line the transcript loses.
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: text.body.copyWith(color: SaiColors.sheetText),
                    // A thin, light caret on the dark card (#99); its
                    // blink is a hard on/off, so nothing fades over a
                    // glyph.
                    cursorColor: SaiColors.sheetText,
                    cursorWidth: 1.5,
                    cursorRadius: const Radius.circular(1),
                    cursorOpacityAnimates: false,
                    decoration: InputDecoration(
                      hintText: 'Ask sai…',
                      hintStyle: text.body.copyWith(color: SaiColors.sheetDim),
                      fillColor: SaiColors.sheetCard,
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: SaiColors.sheetRule),
                        borderRadius: BorderRadius.all(
                          Radius.circular(SaiRadius.medium),
                        ),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: SaiColors.sheetRuleMid),
                        borderRadius: BorderRadius.all(
                          Radius.circular(SaiRadius.medium),
                        ),
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(
                          '⏎ SEND',
                          style: context.saiText.chip.copyWith(
                            color: SaiColors.sheetDim,
                          ),
                        ),
                      ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 0),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (state.busy)
                FilledButton(
                  key: chatStopKey,
                  onPressed: commands.cancelChat,
                  style: FilledButton.styleFrom(
                    backgroundColor: SaiColors.sheetCard,
                    foregroundColor: SaiColors.sheetText,
                  ),
                  child: const Text('Stop'),
                )
              else
                FilledButton(
                  key: chatSendKey,
                  onPressed: commands.sendChat,
                  style: FilledButton.styleFrom(
                    backgroundColor: SaiColors.red,
                    foregroundColor: SaiColors.white,
                  ),
                  child: const Text('Send'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
