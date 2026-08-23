import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveArchiveRoot', () {
    test('SAI_ARCHIVE_ROOT wins everywhere', () {
      final root = resolveArchiveRoot(
        environment: {'SAI_ARCHIVE_ROOT': '/tmp/somewhere', 'HOME': '/Users/x'},
        operatingSystem: 'macos',
      );
      expect(root.path, '/tmp/somewhere');
    });

    test('macOS defaults to Application Support, outside any repo', () {
      final root = resolveArchiveRoot(
        environment: {'HOME': '/Users/x'},
        operatingSystem: 'macos',
      );
      expect(root.path, '/Users/x/Library/Application Support/sai/archive');
    });

    test('Linux honours XDG_DATA_HOME, then ~/.local/share', () {
      expect(
        resolveArchiveRoot(
          environment: {'HOME': '/home/x', 'XDG_DATA_HOME': '/data'},
          operatingSystem: 'linux',
        ).path,
        '/data/sai/archive',
      );
      expect(
        resolveArchiveRoot(
          environment: {'HOME': '/home/x'},
          operatingSystem: 'linux',
        ).path,
        '/home/x/.local/share/sai/archive',
      );
    });

    test('no HOME and no override is an error', () {
      expect(
        () => resolveArchiveRoot(environment: {}, operatingSystem: 'macos'),
        throwsStateError,
      );
    });
  });

  group('providers', () {
    test(
      'archiveProvider opens the archive at the (overridden) root',
      () async {
        final tmp = Directory.systemTemp.createTempSync('sai_root_test');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final container = ProviderContainer.test(
          overrides: [archiveRootProvider.overrideWithValue(tmp)],
        );
        final archive = await container.read(archiveProvider.future);
        await archive.append(
          EventDraft(
            type: EventTypes.chatMessage,
            actor: Actor.user,
            source: 'sai/test',
            payload: {'text': 'hi'},
          ),
        );
        expect((await archive.verify()).count, 1);
        expect(
          Directory('${tmp.path}/events').listSync().single.path,
          endsWith('.jsonl'),
        );
      },
    );
  });
}
