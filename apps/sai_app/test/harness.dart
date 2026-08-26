import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/platform/reduce_motion.dart';
import 'package:sai_app/sai_app.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/workspace/task_list_pane.dart';
import 'package:sai_core/sai_core.dart';

/// Stands in for the platform's menu: records what the app would have
/// sent over the `flutter/menu` channel. Required under `flutter test`,
/// where the default delegate has no plugin to talk to and the provided
/// items assert a macOS target — both would fail every pump.
class TestMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;

  @override
  void clearMenus() => menus = const [];

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

/// The delegate installed by the latest [pumpApp].
late TestMenuDelegate menuDelegate;

/// The item at [path] (top-level label, then submenu labels) in [menus],
/// looking through groups.
PlatformMenuItem menuItem(List<PlatformMenuItem> menus, List<String> path) {
  Iterable<PlatformMenuItem> flatten(Iterable<PlatformMenuItem> items) =>
      items.expand(
        (item) =>
            item is PlatformMenuItemGroup ? flatten(item.members) : [item],
      );
  var level = menus;
  PlatformMenuItem? found;
  for (final label in path) {
    found = flatten(level).firstWhere(
      (item) => item.label == label,
      orElse: () => throw StateError('no menu item "$label" in $path'),
    );
    if (found is PlatformMenu) level = found.menus;
  }
  return found!;
}

/// Pumps [SaiApp] over a per-test temp archive root. Client tests must
/// never touch the real archive under Application Support, so every
/// test goes through here (or overrides [tasksProvider] outright).
///
/// With [settled], the task store is opened (real file I/O, hence
/// [WidgetTester.runAsync]) before the first frame, so the tree renders
/// data immediately — no polling.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  List<Override> overrides = const [],
  List<LlmProvider Function()> builtins = const [FakeLlmProvider.new],
  bool settled = true,
  bool reduceMotion = true,
}) async {
  // Archive and settings both go under one temp dir: no test touches the
  // real data directory, whatever the developer's environment says.
  final tmp = Directory.systemTemp.createTempSync('sai_app_test');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final root = Directory('${tmp.path}/archive');
  final container = ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(root),
      settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
      eventSourceProvider.overrideWithValue(EventSources.app),
      // Never the login keychain from a test.
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      // The fake alone, nothing selected: a test never reaches LM Studio
      // or the LAN box unless it asks for them.
      builtinLlmsProvider.overrideWithValue(builtins),
      defaultLlmIdProvider.overrideWithValue(null),
      // Widget tests must finish with no pending timers. Core exercises the
      // real midnight scheduler with fake_async; app tests pin the same read
      // contract without creating a day-long timer in Flutter's fake clock.
      todayProvider.overrideWithBuild(
        (ref, notifier) => CalendarDate.fromLocal(ref.watch(clockProvider)()),
      ),
      // Reduced by default, so lists settle in one frame and a test never
      // waits out a confirmation hold; the motion tests turn it back on.
      reduceMotionProvider.overrideWithBuild((ref, notifier) => reduceMotion),
      ...overrides,
    ],
  );
  if (settled) {
    await tester.runAsync(() => container.read(tasksProvider.future));
  }
  // A window the size a person would use, not the 800×600 default: the
  // band takes its share of the column and the list must still show rows.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final binding = WidgetsBinding.instance;
  final platformMenus = binding.platformMenuDelegate;
  addTearDown(() => binding.platformMenuDelegate = platformMenus);
  binding.platformMenuDelegate = menuDelegate = TestMenuDelegate();
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SaiApp()),
  );
  await tester.pump();
  return container;
}

/// Types [line] into the capture field and submits it, waiting (under
/// real async) until the store has committed the resulting event — or
/// confirmed it committed nothing, for a blank line.
Future<void> capture(
  WidgetTester tester,
  ProviderContainer container,
  String line,
) async {
  final store = container.read(tasksProvider.notifier).store;
  final expected =
      store.projection.eventCount +
      (parseQuickCapture(line, today: container.read(todayProvider)) == null
          ? 0
          : 1);
  await tester.enterText(find.byKey(captureFieldKey), line);
  await tester.runAsync(() async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    while (store.projection.eventCount < expected) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  });
  await tester.pump();
}

/// Points the shell at [section] and renders it.
Future<void> selectSection(
  WidgetTester tester,
  ProviderContainer container,
  SidebarSection section,
) async {
  container.read(selectedSectionProvider.notifier).select(section);
  await tester.pump();
}

/// Runs [act] (a tap or key chord that triggers an undo) under real
/// async and waits until the store's undo stack has shrunk to [depth].
Future<void> settleUndo(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function() act, {
  required int depth,
}) async {
  final store = container.read(tasksProvider.notifier).store;
  await tester.runAsync(() async {
    await act();
    while (store.undoDepth > depth) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  });
  await tester.pump();
}

/// Every event line under [root], oldest first.
List<String> archiveLines(Directory root) {
  final dir = Directory('${root.path}/events');
  if (!dir.existsSync()) return const [];
  final lines = <String>[];
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    lines.addAll(
      file.readAsStringSync().split('\n').where((l) => l.isNotEmpty),
    );
  }
  return lines;
}

/// The sidebar row of [section].
Finder sidebarRow(SidebarSection section) => find.byKey(sidebarRowKey(section));

/// The count the sidebar shows for [section].
int sidebarCount(WidgetTester tester, SidebarSection section) {
  final texts = find.descendant(
    of: sidebarRow(section),
    matching: find.byType(Text),
  );
  return int.parse(tester.widget<Text>(texts.last).data!);
}

/// The title of the list the pane is showing.
String paneTitle(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(paneTitleKey)).data!;
