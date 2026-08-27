import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/sai_tokens.dart';

/// The reference's switch: a 46×26 pill, red when on, a white knob that
/// slides. Carries its own name and state for a screen reader.
class SaiToggle extends StatelessWidget {
  const SaiToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// What the switch is for, e.g. `Open the assistant with the app`.
  final String label;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Semantics(
      button: true,
      toggled: value,
      enabled: enabled,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: enabled ? () => onChanged!(!value) : null,
          borderRadius: BorderRadius.circular(13),
          child: AnimatedContainer(
            duration: SaiMotion.resolve(context, SaiDurations.mark),
            width: 46,
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: value ? SaiColors.red : SaiColors.surf3,
              borderRadius: BorderRadius.circular(13),
            ),
            child: AnimatedAlign(
              duration: SaiMotion.resolve(context, SaiDurations.mark),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: SaiColors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
