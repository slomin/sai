import 'package:flutter/services.dart';
import 'package:sai_core/sai_core.dart';

/// The Runner's flavor channel: the `SaiFlavor` the bundle was built
/// with (ADR 0019), answered by the Swift side from `Info.plist`.
const flavorChannel = MethodChannel('sai/flavor');

/// Which identity this process runs as. The bundle is the authority:
/// `appFlavor` is a dart-define the last `flutter` command wrote into
/// the generated xcconfig, so an Xcode build after a `flutter build
/// --flavor` of the other flavor would carry a Dart half that disagrees
/// with its own plist. The plist wins, and a disagreement is an error,
/// never a quiet mislabel. Without a Runner behind the channel (tests,
/// other hosts) the dart-define decides, and none of it means dev.
Future<SaiIdentity> resolveIdentity({String? dartFlavor = appFlavor}) async {
  String? bundleFlavor;
  try {
    bundleFlavor = await flavorChannel.invokeMethod<String>('flavor');
  } on MissingPluginException {
    bundleFlavor = null;
  }
  if (bundleFlavor == null) return SaiIdentity.fromFlavor(dartFlavor);
  final identity = SaiIdentity.fromFlavor(bundleFlavor);
  if (dartFlavor != null && SaiIdentity.fromFlavor(dartFlavor) != identity) {
    throw StateError(
      'this bundle is the $bundleFlavor flavor but its Dart code was built '
      'for $dartFlavor; build it with flutter (--flavor $bundleFlavor)',
    );
  }
  return identity;
}
