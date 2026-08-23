import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// The macOS shell. Empty on purpose: #37 lays out the real one.
class SaiApp extends StatelessWidget {
  const SaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sai',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      home: const ShellScreen(),
    );
  }
}

class ShellScreen extends ConsumerWidget {
  const ShellScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final greeting = ref.watch(shellGreetingProvider);
    return Scaffold(body: Center(child: Text(greeting)));
  }
}
