import 'package:flutter/material.dart';

abstract final class OverlayColors {
  static const background = Color(0xFF1B2028);
  static const header = Color(0xFF151920);
  static const text = Color(0xFFE6E9EE);
  static const dim = Color(0xFF8C95A3);
  static const track = Color(0xFF2E3542);
  static const accent = Color(0xFF78C8FF);
  static const running = Color(0xFF3DDC84);
  static const stale = Color(0xFFFFA726);
  static const finished = Color(0xFF42A5F5);
  static const failed = Color(0xFFEF5350);
}

ThemeData buildTheme() => ThemeData(
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(seedColor: OverlayColors.accent, brightness: Brightness.dark),
  scaffoldBackgroundColor: OverlayColors.background,
  splashFactory: NoSplash.splashFactory,
  visualDensity: VisualDensity.compact,
  tooltipTheme: const TooltipThemeData(
    textStyle: TextStyle(fontSize: 11, color: OverlayColors.text),
    decoration: BoxDecoration(color: Color(0xF0101318), borderRadius: BorderRadius.all(Radius.circular(4))),
    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
  ),
);
