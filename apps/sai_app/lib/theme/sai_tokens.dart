import 'package:flutter/painting.dart';

/// The Sai visual system's constants (`references/gui_design_v1_0/sai app -
/// Sai visual system.dc.html`): near-white ground, ink, one red — and the
/// dark "ink band" the assistant lives in. Light appearance only; a dark
/// variant is a later ticket.
abstract final class SaiColors {
  static const bg = Color(0xFFFBFAF8);
  static const surf = Color(0xFFF4F3EF);
  static const surf2 = Color(0xFFECEAE4);
  static const surf3 = Color(0xFFE3E1DA);
  static const ink = Color(0xFF121110);
  static const inkDim = Color(0xFF55534E);
  static const inkFaint = Color(0xFF6B6862);
  static const rule = Color(0xFFE2E0DA);
  static const ruleMid = Color(0xFFCFCCC4);
  static const red = Color(0xFFE5342A);
  static const redPress = Color(0xFFC8281F);
  static const redTint = Color(0xFFFDE7E4);
  static const redInk = Color(0xFFA3241C);
  static const onInk = Color(0xFFFBFAF8);
  static const white = Color(0xFFFFFFFF);

  /// The assistant header's light (#40): ready, worth a glance, down.
  /// Two colours the reference does not have — its square is the brand
  /// red as decoration; the issue asks for a state light in its place.
  static const green = Color(0xFF3FA66A);
  static const amber = Color(0xFFE0A526);

  /// The ink band (the assistant): a different surface from the list, so
  /// a proposal never looks like a task you already own.
  static const sheetBg = Color(0xFF121110);
  static const sheetCard = Color(0xFF1D1B18);
  static const sheetText = Color(0xFFFBFAF8);
  static const sheetDim = Color(0xFFA8A49C);
  static const sheetRule = Color(0xFF2E2B27);
  static const sheetRuleMid = Color(0xFF4A4640);
  static const sheetStrike = Color(0xFF8A8781);
}

/// The two bundled families (`fonts/`, SIL OFL). Space Grotesk ships as a
/// variable font, so weight goes through [FontVariation] as well as
/// [FontWeight]; JetBrains Mono ships as three static weights.
abstract final class SaiFonts {
  static const sans = 'SpaceGrotesk';
  static const mono = 'JetBrainsMono';
}

abstract final class SaiRadius {
  static const small = 6.0;
  static const medium = 8.0;
  static const large = 10.0;
}

abstract final class SaiSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Base durations of the restrained motion (#72, #77). Non-essential
/// motion goes through [SaiMotion] so Reduce Motion can zero it.
abstract final class SaiDurations {
  static const mark = Duration(milliseconds: 120);
  static const hold = Duration(milliseconds: 600);
  static const collapse = Duration(milliseconds: 180);
  static const enter = Duration(milliseconds: 160);
  static const band = Duration(milliseconds: 200);
}
