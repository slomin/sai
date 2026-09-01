import 'dart:io';

import 'package:sai_core/src/process/lock.dart';

/// Run in a second Dart VM by `lock_test.dart`: takes the lock on the
/// file named by the first argument, prints `held` or `busy`, then holds
/// it until stdin closes (so the parent can prove exclusion across
/// processes) and releases it.
Future<void> main(List<String> args) async {
  final lock = await ExclusiveLock.tryAcquire(File(args.single));
  if (lock == null) {
    print('busy');
    return;
  }
  print('held');
  await stdin.drain<void>();
  await lock.release();
  print('released');
}
