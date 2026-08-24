import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'sai_app.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: [eventSourceProvider.overrideWithValue(EventSources.app)],
      child: const SaiApp(),
    ),
  );
}
