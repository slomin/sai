import 'dart:io';
import 'dart:isolate';

/// The directory holding this package's `pubspec.yaml`, independent of the
/// working directory `dart test` was started from.
Future<Directory> packageRoot() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:sai_core/sai_core.dart'),
  );
  return File.fromUri(lib!).parent.parent;
}
