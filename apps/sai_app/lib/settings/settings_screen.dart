import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sidebar.dart';
import '../theme/motion.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../top_bar.dart';
import 'archive_page.dart';
import 'general_page.dart';
import 'providers_page.dart';
import 'shortcuts_page.dart';

/// The sections, in the rail's order.
enum SettingsSection {
  general('General'),
  providers('Providers'),
  archive('Archive'),
  shortcuts('Shortcuts');

  const SettingsSection(this.label);

  final String label;
}

/// The screen, its rail rows and its close, for tests.
const settingsScreenKey = Key('settings');
Key settingsNavKey(SettingsSection section) => ValueKey(('settings', section));

/// The one Settings that may be open (#40): ⌘, and the menu item share
/// the command, and Help ▸ Keyboard Shortcuts asks for a section — while
/// the screen is open that switches the section instead of stacking a
/// second screen.
final settingsGateProvider = Provider<SettingsGate>((ref) => SettingsGate());

class SettingsGate {
  void Function(SettingsSection)? _select;
}

/// Opens Settings on [initial] — inside the main window, sized like the
/// reference (760×580), as a route above the chrome so the chrome's
/// chords and typing trigger are inert while it is up.
Future<void> openSettings(
  BuildContext context, {
  SettingsSection initial = SettingsSection.general,
}) {
  final gate = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(settingsGateProvider);
  if (gate._select case final select?) {
    select(initial);
    return Future.value();
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close Settings',
    barrierColor: Colors.black38,
    // One frame under Reduce Motion, a short fade otherwise.
    transitionDuration: SaiMotion.resolve(context, SaiDurations.enter),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, _, _) => SettingsScreen(initial: initial),
  );
}

/// The rail on the left, the page on the right, the mark up top.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, required this.initial});

  final SettingsSection initial;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late var _section = widget.initial;
  final _rail = FocusNode(debugLabel: 'settings-rail');

  // Held from initState: a ref is not usable from dispose.
  late final SettingsGate _gate;

  @override
  void initState() {
    super.initState();
    _gate = ref.read(settingsGateProvider).._select = _select;
  }

  @override
  void dispose() {
    if (_gate._select == _select) _gate._select = null;
    _rail.dispose();
    super.dispose();
  }

  void _select(SettingsSection section) {
    if (!mounted) return;
    setState(() => _section = section);
  }

  void _move(int by) {
    final values = SettingsSection.values;
    final next = (_section.index + by).clamp(0, values.length - 1);
    _select(values[next]);
  }

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        },
        child: FocusScope(
          autofocus: true,
          child: Semantics(
            key: settingsScreenKey,
            container: true,
            label: 'Settings',
            child: SizedBox(
              width: 760,
              height: 580,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: SaiColors.rule)),
                    ),
                    child: Row(
                      children: [
                        const SaiMark(size: 22),
                        const SizedBox(width: 12),
                        Semantics(
                          header: true,
                          child: Text(
                            'Settings',
                            style: text.body.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Focus(
                          focusNode: _rail,
                          autofocus: true,
                          child: Container(
                            width: 196,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: const BoxDecoration(
                              border: Border(
                                right: BorderSide(color: SaiColors.rule),
                              ),
                            ),
                            child: Column(
                              children: [
                                for (final section in SettingsSection.values)
                                  SizedBox(
                                    height: 42,
                                    child: SidebarRow(
                                      key: settingsNavKey(section),
                                      title: section.label,
                                      count: null,
                                      selected: section == _section,
                                      onTap: () => _select(section),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                            child: switch (_section) {
                              SettingsSection.general => const GeneralPage(),
                              SettingsSection.providers =>
                                const ProvidersPage(),
                              SettingsSection.archive => const ArchivePage(),
                              SettingsSection.shortcuts =>
                                const ShortcutsPage(),
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
