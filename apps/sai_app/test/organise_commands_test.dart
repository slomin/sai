import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/organise/organise_commands.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

/// `OrganiseCommands.tryCreateHeading` at the provider level (#96): no
/// widgets, a real archive in a temp dir — what the store accepts, what it
/// refuses, and what a refusal leaves in the notice.
void main() {
  late ProviderContainer container;
  late TaskStore store;
  late OrganiseCommands organise;

  setUp(() async {
    container = ProviderContainer.test(overrides: appOverrides(tmp: tempDir()));
    await container.read(tasksProvider.future);
    store = container.read(tasksProvider.notifier).store;
    organise = container.read(organiseCommandsProvider);
  });

  String notice() => container.read(noticeProvider);

  test('creates a heading in an empty and in a populated project', () async {
    final empty = await store.createProject(title: 'Empty');
    final full = await store.createProject(title: 'Full');
    await store.createTask(title: 'Tiles', project: full);
    final before = store.projection.eventCount;

    expect(await organise.tryCreateHeading(empty, 'Prep'), isNull);
    expect(await organise.tryCreateHeading(full, ' Build '), isNull);

    expect(store.projection.headingsOf(empty).map((h) => h.title), ['Prep']);
    expect(store.projection.headingsOf(full).map((h) => h.title), ['Build']);
    expect(store.projection.eventCount, before + 2);
    expect(notice(), isEmpty);
  });

  test('a blank title is refused before the store sees it', () async {
    final project = await store.createProject(title: 'P');
    final before = store.projection.eventCount;

    expect(await organise.tryCreateHeading(project, ''), contains('empty'));
    expect(await organise.tryCreateHeading(project, ' \t'), contains('empty'));

    expect(store.projection.eventCount, before);
    expect(notice(), 'new heading failed: title must not be empty');
  });

  test('a duplicate title is a second heading, not a refusal', () async {
    final project = await store.createProject(title: 'P');
    expect(await organise.tryCreateHeading(project, 'Prep'), isNull);
    expect(await organise.tryCreateHeading(project, 'Prep'), isNull);
    final headings = store.projection.headingsOf(project).toList();
    expect(headings.map((h) => h.title), ['Prep', 'Prep']);
    expect(headings.first.id, isNot(headings.last.id));
  });

  test('an archived project refuses and the reason says so', () async {
    final project = await store.createProject(title: 'P');
    await store.archiveProject(project);
    final before = store.projection.eventCount;

    final reason = await organise.tryCreateHeading(project, 'Prep');
    expect(reason, contains('archived'));
    expect(store.projection.eventCount, before);
    expect(notice(), 'new heading failed: $reason');
  });

  test('a deleted project refuses and the reason says so', () async {
    final project = await store.createProject(title: 'P');
    await store.deleteProject(project);
    final before = store.projection.eventCount;

    expect(
      await organise.tryCreateHeading(project, 'Prep'),
      contains('deleted'),
    );
    expect(store.projection.eventCount, before);
    expect(notice(), contains('deleted'));
  });

  test('a success clears the notice a refusal left', () async {
    final project = await store.createProject(title: 'P');
    await organise.tryCreateHeading(project, '');
    expect(notice(), isNotEmpty);
    await organise.tryCreateHeading(project, 'Prep');
    expect(notice(), isEmpty);
  });

  test('a project archived by another writer refuses once reloaded', () async {
    final project = await store.createProject(title: 'P');

    // Another process on the same log — the terminal client, say.
    final root = container.read(archiveRootProvider);
    final other = await Archive.open(root);
    final theirs = await TaskStore.open(other, source: EventSources.tui);
    await theirs.archiveProject(project);
    theirs.dispose();
    await other.close();

    await store.reload();
    expect(store.projection.projects[project]!.archivedAt, isNotNull);
    final before = store.projection.eventCount;

    expect(
      await organise.tryCreateHeading(project, 'Prep'),
      contains('archived'),
    );
    expect(store.projection.eventCount, before);
  });
}
