import 'package:flutter/material.dart';

import 'sai_tokens.dart';

/// Space Grotesk at [weight]: the variable font needs the axis set as
/// well as the weight, or every style renders at the default instance.
TextStyle sans(
  double size, {
  FontWeight weight = FontWeight.w400,
  double height = 1.3,
  double? letterSpacing,
  Color color = SaiColors.ink,
}) => TextStyle(
  fontFamily: SaiFonts.sans,
  fontSize: size,
  fontWeight: weight,
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
  height: height,
  letterSpacing: letterSpacing,
  color: color,
);

/// JetBrains Mono at [weight] (400, 500 or 700 ship).
TextStyle mono(
  double size, {
  FontWeight weight = FontWeight.w500,
  double height = 1.0,
  double? letterSpacing,
  Color color = SaiColors.inkFaint,
}) => TextStyle(
  fontFamily: SaiFonts.mono,
  fontSize: size,
  fontWeight: weight,
  height: height,
  letterSpacing: letterSpacing,
  color: color,
);

/// The named styles the workspace composes from, reachable through
/// `Theme.of(context).extension<SaiText>()`.
class SaiText extends ThemeExtension<SaiText> {
  const SaiText();

  /// Uppercase mono eyebrow above a headline or a group.
  TextStyle get eyebrow => mono(10, letterSpacing: 1.6, color: SaiColors.red);
  TextStyle get eyebrowDim => mono(10, letterSpacing: 1.6);

  /// Mono meta: counts, dates, the archive line.
  TextStyle get meta => mono(11, letterSpacing: 0.9);
  TextStyle get chip => mono(10, letterSpacing: 0.8, color: SaiColors.inkDim);

  TextStyle get title =>
      sans(24, weight: FontWeight.w700, height: 1.1, letterSpacing: -0.5);
  TextStyle get emptyTitle =>
      sans(22, weight: FontWeight.w700, height: 1.15, letterSpacing: -0.4);
  TextStyle get body => sans(14);
  TextStyle get bodyDim => sans(14, color: SaiColors.inkDim);
  TextStyle get note => sans(13, color: SaiColors.inkDim, height: 1.4);
  TextStyle get small => sans(13);
  TextStyle get sidebar => sans(14, weight: FontWeight.w500);
  TextStyle get button => sans(14, weight: FontWeight.w600);
  TextStyle get brand =>
      sans(20, weight: FontWeight.w700, height: 1, letterSpacing: -0.4);

  @override
  SaiText copyWith() => const SaiText();

  @override
  SaiText lerp(SaiText? other, double t) => this;
}

extension SaiTextOf on BuildContext {
  SaiText get saiText => Theme.of(this).extension<SaiText>() ?? const SaiText();
}

/// The one theme (#72): the Sai visual system over Material's widgets.
/// Light only; `ThemeMode.light` is pinned in `sai_app.dart`.
ThemeData saiTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: SaiColors.ink,
    onPrimary: SaiColors.onInk,
    secondary: SaiColors.red,
    onSecondary: SaiColors.white,
    error: SaiColors.redInk,
    onError: SaiColors.white,
    surface: SaiColors.bg,
    onSurface: SaiColors.ink,
    surfaceContainerHighest: SaiColors.surf2,
    outline: SaiColors.ruleMid,
    outlineVariant: SaiColors.rule,
  );
  final body = sans(14);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: SaiColors.bg,
    canvasColor: SaiColors.bg,
    dividerColor: SaiColors.rule,
    splashFactory: NoSplash.splashFactory,
    fontFamily: SaiFonts.sans,
    textTheme: TextTheme(
      bodyLarge: sans(15),
      bodyMedium: body,
      bodySmall: sans(13, color: SaiColors.inkDim),
      titleLarge: sans(24, weight: FontWeight.w700, height: 1.1),
      titleMedium: sans(16, weight: FontWeight.w600),
      labelLarge: sans(14, weight: FontWeight.w600),
      labelSmall: mono(10, letterSpacing: 1.2),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: SaiColors.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(SaiRadius.large)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: SaiColors.white,
      hintStyle: sans(14, color: SaiColors.inkFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: const OutlineInputBorder(
        borderSide: BorderSide(color: SaiColors.ruleMid),
        borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
      ),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: SaiColors.ruleMid),
        borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: SaiColors.ink),
        borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SaiColors.ink,
        textStyle: sans(14, weight: FontWeight.w500),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SaiColors.ink,
        foregroundColor: SaiColors.onInk,
        textStyle: sans(14, weight: FontWeight.w600),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? SaiColors.white
            : SaiColors.inkFaint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? SaiColors.ink
            : SaiColors.surf3,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(SaiColors.bg),
        surfaceTintColor: const WidgetStatePropertyAll(SaiColors.bg),
        elevation: const WidgetStatePropertyAll(4),
        side: const WidgetStatePropertyAll(BorderSide(color: SaiColors.rule)),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: MenuItemButton.styleFrom(
        foregroundColor: SaiColors.ink,
        textStyle: sans(13, weight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    ),
    extensions: const [SaiText()],
  );
}
