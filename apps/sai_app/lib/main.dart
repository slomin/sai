import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'platform/flavor.dart';
import 'sai_app.dart';

Future<void> main() async {
  // The Xcode scheme is the flavor (ADR 0019): `stable` is the daily-use
  // copy, `dev` — or no flavor at all — the isolated development one.
  // The bundle's own plist says which; see resolveIdentity.
  WidgetsFlutterBinding.ensureInitialized();
  final identity = await resolveIdentity();
  runApp(
    ProviderScope(
      overrides: [
        identityProvider.overrideWithValue(identity),
        eventSourceProvider.overrideWithValue(EventSources.app),
      ],
      child: const SaiApp(),
    ),
  );
}
