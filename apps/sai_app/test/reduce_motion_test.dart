import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/platform/reduce_motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reads the Runner\'s flag and follows its changes', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(reduceMotionChannel, (call) async {
      if (call.method == 'reduceMotion') return true;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(reduceMotionChannel, null),
    );
    final container = ProviderContainer.test();
    final seen = <bool>[];
    container.listen(reduceMotionProvider, (_, v) => seen.add(v));
    expect(container.read(reduceMotionProvider), isFalse);
    await tester.pump();
    expect(container.read(reduceMotionProvider), isTrue);

    await messenger.handlePlatformMessage(
      reduceMotionChannel.name,
      reduceMotionChannel.codec.encodeMethodCall(
        const MethodCall('reduceMotionChanged', false),
      ),
      (_) {},
    );
    expect(container.read(reduceMotionProvider), isFalse);
    expect(seen, [true, false]);
  });

  testWidgets('stays off without a Runner behind the channel', (tester) async {
    final container = ProviderContainer.test();
    expect(container.read(reduceMotionProvider), isFalse);
    await tester.pump();
    expect(container.read(reduceMotionProvider), isFalse);
  });
}
