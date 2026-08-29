import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'sai_app.dart';

void main() {
  // The Xcode scheme is the flavor (ADR 0019): `stable` is the daily-use
  // copy, `dev` — or no flavor at all — the isolated development one.
  final identity = SaiIdentity.fromFlavor(appFlavor);
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
