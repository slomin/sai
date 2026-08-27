import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';

/// One labelled row of the inspector as the reference draws it: the
/// uppercase label in a fixed gutter, the value (or its editor) beside
/// it, a rule above.
class InspectorFieldRow extends StatelessWidget {
  const InspectorFieldRow({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  static const gutter = 78.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SaiColors.rule)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: gutter,
            child: ExcludeSemantics(
              child: Text(
                label.toUpperCase(),
                style: context.saiText.eyebrowDim.copyWith(
                  fontFamily: SaiFonts.sans,
                  fontWeight: FontWeight.w600,
                  fontVariations: const [FontVariation.weight(600)],
                  letterSpacing: 1.4,
                ),
                softWrap: true,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A row's value rendered as a button that opens a menu: the whole value
/// is the target, and assistive tech hears label and value together.
class InspectorValueButton extends StatelessWidget {
  const InspectorValueButton({
    super.key,
    required this.label,
    required this.value,
    required this.onPressed,
    this.style,
  });

  final String label;
  final String value;
  final VoidCallback onPressed;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Semantics(
      button: true,
      label: '$label, $value',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onPressed,
          borderRadius: const BorderRadius.all(
            Radius.circular(SaiRadius.small),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Text(
              value,
              style:
                  style ??
                  text.body.copyWith(
                    fontWeight: FontWeight.w600,
                    fontVariations: const [FontVariation.weight(600)],
                  ),
              softWrap: true,
            ),
          ),
        ),
      ),
    );
  }
}
