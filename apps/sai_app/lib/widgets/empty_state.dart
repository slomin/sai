import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';
import 'eyebrow.dart';

/// A list with nothing in it: the eyebrow names the list, the title says
/// so plainly, the body says what to do about it (the reference's copy).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.body,
  });

  final String eyebrow;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Eyebrow(eyebrow),
            const SizedBox(height: 10),
            Text(title, style: text.emptyTitle),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(body, style: text.bodyDim),
            ),
          ],
        ),
      ),
    );
  }
}
