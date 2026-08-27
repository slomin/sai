import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';

/// One settings row (#40): a label over a helper line on the left, the
/// control on the right, a rule above. The text column wraps, so the
/// row survives 1.3× text without clipping the control.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.helper,
    required this.control,
  });

  final String label;
  final String helper;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SaiColors.rule)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: text.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  helper,
                  style: text.small.copyWith(color: SaiColors.inkFaint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          control,
        ],
      ),
    );
  }
}

/// The page's red eyebrow and its title, as every settings page opens.
class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.trailing,
  });

  final String eyebrow;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow.toUpperCase(),
                  style: sans(
                    10,
                    weight: FontWeight.w600,
                    letterSpacing: 1.6,
                    color: SaiColors.red,
                  ),
                ),
                const SizedBox(height: 8),
                Semantics(header: true, child: Text(title, style: text.title)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
