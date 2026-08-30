import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/platform/reduce_motion.dart';
import 'package:sai_app/sai_app.dart';
import 'package:sai_app/setup/first_run.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/widgets/check_mark.dart';
import 'package:sai_app/workspace/task_list_pane.dart';
import 'package:sai_app/reorder/drag_handle.dart';
import 'package:sai_app/reorder/reorder.dart';
import 'package:sai_app/workspace/task_row.dart';
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
/// A fresh directory for one test's archive and settings, removed after.
Directory tempDir() {
  final tmp = Directory.systemTemp.createTempSync('sai_app_test');
  addTearDown(() => tmp.deleteSync(recursive: true));
  return tmp;
}

Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  List<Override> overrides = const [],
  List<LlmProvider Function()> builtins = const [FakeLlmProvider.new],
  bool settled = true,
  bool reduceMotion = true,
  DateTime Function()? clock,
  Directory? tmp,
  Map<String, String> environment = const {},
  bool firstRun = false,
  SaiIdentity identity = SaiIdentity.stable,
  FinishedTaskVisibility? finishedTasks = FinishedTaskVisibility.endOfDay,
}) async {
  // Archive and settings both go under one temp dir: no test touches the
  // real data directory, whatever the developer's environment says. A
  // test that seeds either before launch passes the [tempDir] it used.
  tmp ??= tempDir();
  final container = ProviderContainer.test(
    overrides: [
      ...appOverrides(
        tmp: tmp,
        builtins: builtins,
        reduceMotion: reduceMotion,
        clock: clock,
        environment: environment,
        firstRun: firstRun,
        identity: identity,
        finishedTasks: finishedTasks,
      ),
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

/// The overrides every app test runs under, with or without widgets:
/// [pumpApp] builds its container from them, and a provider-level test
/// (`organise_commands_test`) uses them on a bare [ProviderContainer].
List<Override> appOverrides({
  required Directory tmp,
  List<LlmProvider Function()> builtins = const [FakeLlmProvider.new],
  bool reduceMotion = true,
  DateTime Function()? clock,
  Map<String, String> environment = const {},
  bool firstRun = false,
  SaiIdentity identity = SaiIdentity.stable,
  FinishedTaskVisibility? finishedTasks = FinishedTaskVisibility.endOfDay,
}) => [
  // Stable unless a test asks for dev: the goldens show the plain
  // header, and `appFlavor` is unset under `flutter test` anyway.
  identityProvider.overrideWithValue(identity),
  archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
  settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
  // A home of its own (#40): nothing that resolves a path from the
  // environment — the Things locator above all — may wander into the
  // developer's real directories from a test.
  environmentProvider.overrideWithValue({'HOME': tmp.path, ...environment}),
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
  // A pinned day, advancing with real time so event timestamps keep
  // their order: the goldens carry dates, and a golden that only
  // matches on the day it was recorded is not a golden.
  clockProvider.overrideWithValue(clock ?? _pinnedClock()),
  // Reduced by default, so lists settle in one frame and a test never
  // waits out a confirmation hold; the motion tests turn it back on.
  reduceMotionProvider.overrideWithBuild((ref, notifier) => reduceMotion),
  // The product default (#97) unless a test is about the collapse: a
  // finished row stays, greyed, until midnight. Pinned here rather than
  // written to the file; a test about the switch itself passes null and
  // reads the setting through.
  if (finishedTasks != null)
    finishedTaskVisibilityProvider.overrideWithValue(finishedTasks),
  // Past the welcome (#40) unless a test is about it: an empty archive
  // and no file is what every test starts from.
  setupSeenProvider.overrideWithBuild((ref, notifier) => !firstRun),
  // The light probes on selection and on demand, never on a timer
  // here: a periodic timer would outlive the test.
  connectionProbeEveryProvider.overrideWithValue(null),
];

/// Pumps and lets real async run until [ready] — for a dialog that
/// answers a refused commit in place, where no event count moves.
Future<void> settleUntil(
  WidgetTester tester,
  bool Function() ready,
  String Function() describe,
) => _settle(tester, ready, describe);

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

/// How long a settle helper waits for the store before failing the test
/// — a missing event should read as a failure, not a hung run.
const settleLimit = Duration(seconds: 5);

/// Runs [act] (a tap or key chord that triggers an undo) under real
/// async and waits until the store's undo stack has shrunk to [depth].
Future<void> settleUndo(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function() act, {
  required int depth,
}) async {
  final store = container.read(tasksProvider.notifier).store;
  await tester.runAsync(act);
  await _settle(
    tester,
    () => store.undoDepth <= depth,
    () => 'undo depth still ${store.undoDepth}',
  );
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

/// Runs [act] (a tap, a drag) under real async and waits until the store
/// has committed [count] more events, then pumps a frame.
Future<void> settleEvents(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function() act, {
  int count = 1,
}) async {
  final store = container.read(tasksProvider.notifier).store;
  final expected = store.projection.eventCount + count;
  await tester.runAsync(act);
  await _settle(
    tester,
    () => store.projection.eventCount >= expected,
    () =>
        'only ${store.projection.eventCount - expected + count} of $count '
        'events',
  );
}

/// Pumps a frame on the test clock (zero time, so animations stay put)
/// and lets real async run for a moment, until [ready] — a popped dialog
/// hands its result on over two frames, a menu item fires its handler
/// after one, and the store's append is real file I/O.
Future<void> _settle(
  WidgetTester tester,
  bool Function() ready,
  String Function() describe,
) async {
  final started = DateTime.now();
  while (!ready()) {
    if (DateTime.now().difference(started) > settleLimit) {
      fail('${describe()} after $settleLimit');
    }
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
  await tester.pump();
}

/// Taps the menu item labelled [label]; a [MenuItemButton] fires its
/// handler on the frame after the menu closes, which the settle helpers
/// pump.
Future<void> tapMenuItem(WidgetTester tester, String label) =>
    tester.tap(find.widgetWithText(MenuItemButton, label));

/// The row showing [task].
Finder row(TaskId task) => find.byKey(taskRowKey(task));

/// The check at the head of [task]'s row.
Finder check(TaskId task) =>
    find.descendant(of: row(task), matching: find.byType(CheckMark));

/// The drag handle of [task]'s row (#98).
Finder handle(TaskId task) => find.byKey(dragHandleKey(task));

/// The slot a live drag has opened, if any.
Finder openGap() => find.byWidgetPredicate((w) => w is DropGap && w.visible);

/// Drags [source]'s row by [handle] until the proxy's middle is in the
/// lower ([below]) or upper half of [target], and releases it there. The
/// proxy lifts from the source row's own corner, so the pointer is moved
/// by where the row's centre must go. Run it under [settleEvents] when
/// the drop is expected to write; with [release] off the gesture comes
/// back still held.
Future<TestGesture> dragRow(
  WidgetTester tester, {
  required Finder handle,
  required Finder source,
  required Finder target,
  bool below = true,
  bool release = true,
}) async {
  final start = tester.getCenter(handle);
  final toCentre = tester.getCenter(source) - start;
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 24));
  await tester.pump();
  final rect = tester.getRect(target);
  final aim = Offset(rect.center.dx, below ? rect.bottom - 6 : rect.top + 6);
  await gesture.moveTo(aim - toCentre);
  await tester.pump();
  if (release) {
    await gesture.up();
    await tester.pump();
  }
  return gesture;
}

/// The titles on screen, top to bottom, of the rows in the list.
List<String> rowTitles(WidgetTester tester) {
  final rows = find.byType(TaskRow).evaluate().toList()
    ..sort(
      (a, b) => (a.renderObject as RenderBox)
          .localToGlobal(Offset.zero)
          .dy
          .compareTo(
            (b.renderObject as RenderBox).localToGlobal(Offset.zero).dy,
          ),
    );
  return [for (final e in rows) (e.widget as TaskRow).task.title];
}

/// Pumps frames of [step] until [ready], or fails after [limit] of fake
/// time — for motion whose exact frame count is not the point.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration step = const Duration(milliseconds: 50),
  Duration limit = const Duration(seconds: 3),
}) async {
  var elapsed = Duration.zero;
  while (!ready()) {
    if (elapsed > limit) fail('not ready after $limit');
    await tester.pump(step);
    elapsed += step;
  }
}

/// Wednesday 26 August 2026, noon local, then the wall clock's progress.
DateTime Function() _pinnedClock() {
  final start = DateTime(2026, 8, 26, 12);
  final elapsed = Stopwatch()..start();
  return () => start.add(elapsed.elapsed);
}
