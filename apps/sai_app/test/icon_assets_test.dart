import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const _sizes = [16, 32, 64, 128, 256, 512, 1024];
const _assets = 'macos/Runner/Assets.xcassets';
const _sources = 'macos/Runner/IconSources';

void main() {
  test('stable and dev ship complete, distinct macOS icon catalogs', () {
    for (final flavor in ['stable', 'dev']) {
      final master = File('$_sources/sai-$flavor-1024.png');
      expect(master.existsSync(), isTrue, reason: master.path);
      expect(_pngSize(master), (width: 1024, height: 1024));

      final catalog = Directory('$_assets/AppIcon-$flavor.appiconset');
      expect(catalog.existsSync(), isTrue, reason: catalog.path);
      expect(
        catalog.listSync().map((entry) => entry.uri.pathSegments.last).toSet(),
        {'Contents.json', for (final size in _sizes) 'app_icon_$size.png'},
      );

      final manifest = jsonDecode(
        File('${catalog.path}/Contents.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final images = manifest['images']! as List<Object?>;
      expect(images, hasLength(10));
      expect(
        images.map((entry) {
          final image = entry! as Map<String, Object?>;
          return (
            size: image['size'],
            scale: image['scale'],
            filename: image['filename'],
            idiom: image['idiom'],
          );
        }).toSet(),
        {
          for (final size in [16, 32, 128, 256, 512])
            for (final scale in [1, 2])
              (
                size: '${size}x$size',
                scale: '${scale}x',
                filename: 'app_icon_${size * scale}.png',
                idiom: 'mac',
              ),
        },
      );

      for (final size in _sizes) {
        final image = File('${catalog.path}/app_icon_$size.png');
        expect(image.existsSync(), isTrue, reason: image.path);
        expect(_pngSize(image), (width: size, height: size));
      }
    }

    expect(Directory('$_assets/AppIcon.appiconset').existsSync(), isFalse);
    expect(
      File('$_sources/sai-stable-1024.png').readAsBytesSync(),
      isNot(equals(File('$_sources/sai-dev-1024.png').readAsBytesSync())),
    );
    for (final size in _sizes) {
      expect(
        File('$_assets/AppIcon-stable.appiconset/app_icon_$size.png')
            .readAsBytesSync(),
        isNot(
          equals(
            File('$_assets/AppIcon-dev.appiconset/app_icon_$size.png')
                .readAsBytesSync(),
          ),
        ),
        reason: 'the $size px icons must remain visibly flavor-specific',
      );
    }
  });

  test('every native build configuration selects its flavor icon', () {
    final stable = File('macos/Runner/Configs/AppInfo-stable.xcconfig')
        .readAsStringSync();
    final dev = File('macos/Runner/Configs/AppInfo-dev.xcconfig')
        .readAsStringSync();
    expect(
      stable,
      contains('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon-stable'),
    );
    expect(dev, contains('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon-dev'));
    for (final config in [stable, dev]) {
      expect(
        config,
        contains('ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO'),
      );
    }

    final project = File('macos/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    expect(
      project,
      isNot(contains('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')),
    );
  });
}

({int width, int height}) _pngSize(File file) {
  final bytes = file.readAsBytesSync();
  expect(bytes.length, greaterThanOrEqualTo(24), reason: file.path);
  expect(bytes.sublist(0, 8), [
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
  ], reason: file.path);
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return (
    width: data.getUint32(16, Endian.big),
    height: data.getUint32(20, Endian.big),
  );
}
