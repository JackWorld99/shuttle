// Shuttle design theme ("warm"): warm off-white background + white cards + sans-serif type; the app icon's warm colors
// (gold → vermilion → deep red) are used only for primary buttons, "my devices" avatars and a few accents.
// No Material You dynamic color: the warm palette is the identity.
import 'package:flutter/material.dart';

/// Semantic colors. Every color outside the ColorScheme (online, warning, accent, card shadow, etc.) comes from here:
/// `Theme.of(context).extension<ShareMeColors>()!` or `context.sm`.
@immutable
class ShareMeColors extends ThemeExtension<ShareMeColors> {
  final Color bg;

  /// Background of cards, grouped lists and sheets (pure white in light mode)
  final Color group;
  final Color tonal;
  final Color tonalStrong;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color line;
  final Color onInk;

  /// Color of the pairing verification pattern (the pairing seal)
  final Color seal;
  final Color onSeal;
  final Color ok;
  final Color warn;
  final Color warnContainer;

  /// Legacy "film strip" colors: only still used in a few places such as the history details
  final Color strip;
  final Color stripInk;
  final Color stripMark;
  final Color scrim;
  final Color camera;

  /// Accent color (selected navigation item, switches, link-style buttons)
  final Color accent;

  /// Light accent background (navigation selection indicator)
  final Color accentSoft;

  /// Small tags such as "Original": light green background + dark green text
  final Color okSoft;
  final Color okInk;

  /// Snackbar background
  final Color snack;

  /// Soft card shadow (barely visible in dark mode, which relies on tonal layering instead)
  final List<BoxShadow> cardShadow;

  const ShareMeColors({
    required this.bg,
    required this.group,
    required this.tonal,
    required this.tonalStrong,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.onInk,
    required this.seal,
    required this.onSeal,
    required this.ok,
    required this.warn,
    required this.warnContainer,
    required this.strip,
    required this.stripInk,
    required this.stripMark,
    required this.scrim,
    required this.camera,
    required this.accent,
    required this.accentSoft,
    required this.okSoft,
    required this.okInk,
    required this.snack,
    required this.cardShadow,
  });

  static const light = ShareMeColors(
    bg: Color(0xFFF5F4F1),
    group: Color(0xFFFFFFFF),
    tonal: Color(0xFFEFEDE8),
    tonalStrong: Color(0xFFE1DED7),
    ink: Color(0xFF16171A),
    ink2: Color(0xFF5B5E62),
    ink3: Color(0xFF8E9195),
    line: Color(0xFFECEAE5),
    onInk: Color(0xFFF7F6F3),
    seal: Color(0xFFD44A27),
    onSeal: Color(0xFFFFFFFF),
    ok: Color(0xFF1E8E52),
    warn: Color(0xFF9C5900),
    warnContainer: Color(0xFFFBEBD2),
    strip: Color(0xFF1A1D1B),
    stripInk: Color(0xFFB9BFBA),
    stripMark: Color(0xFFE2584A),
    scrim: Color(0xFF101113),
    camera: Color(0xFF0B0C0C),
    accent: Color(0xFFD44A27),
    accentSoft: Color(0xFFFBE3D6),
    okSoft: Color(0xFFE2F2E8),
    okInk: Color(0xFF17703F),
    snack: Color(0xFF1E1F22),
    cardShadow: [
      BoxShadow(color: Color(0x0D16171A), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x3316171A), blurRadius: 28, spreadRadius: -16, offset: Offset(0, 12)),
    ],
  );

  static const dark = ShareMeColors(
    bg: Color(0xFF0F1012),
    group: Color(0xFF1B1C1F),
    tonal: Color(0xFF26282C),
    tonalStrong: Color(0xFF34363B),
    ink: Color(0xFFEDEEF0),
    ink2: Color(0xFFA6A9AE),
    ink3: Color(0xFF767A80),
    line: Color(0xFF2A2C30),
    onInk: Color(0xFF0F1012),
    seal: Color(0xFFE0572F),
    onSeal: Color(0xFFFFFFFF),
    ok: Color(0xFF4BC385),
    warn: Color(0xFFE9A54C),
    warnContainer: Color(0xFF3A2A12),
    strip: Color(0xFF050606),
    stripInk: Color(0xFF9DA49F),
    stripMark: Color(0xFFE8604F),
    scrim: Color(0xFF000000),
    camera: Color(0xFF0B0C0C),
    accent: Color(0xFFF28A4B),
    accentSoft: Color(0xFF382820),
    okSoft: Color(0xFF22332D),
    okInk: Color(0xFF6FD49E),
    snack: Color(0xFF2B2D31),
    cardShadow: [
      BoxShadow(color: Color(0xB3000000), blurRadius: 30, spreadRadius: -20, offset: Offset(0, 16)),
    ],
  );

  @override
  ShareMeColors copyWith() => this;

  @override
  ShareMeColors lerp(ThemeExtension<ShareMeColors>? other, double t) {
    if (other is! ShareMeColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ShareMeColors(
      bg: l(bg, other.bg),
      group: l(group, other.group),
      tonal: l(tonal, other.tonal),
      tonalStrong: l(tonalStrong, other.tonalStrong),
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      line: l(line, other.line),
      onInk: l(onInk, other.onInk),
      seal: l(seal, other.seal),
      onSeal: l(onSeal, other.onSeal),
      ok: l(ok, other.ok),
      warn: l(warn, other.warn),
      warnContainer: l(warnContainer, other.warnContainer),
      strip: l(strip, other.strip),
      stripInk: l(stripInk, other.stripInk),
      stripMark: l(stripMark, other.stripMark),
      scrim: l(scrim, other.scrim),
      camera: l(camera, other.camera),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      okSoft: l(okSoft, other.okSoft),
      okInk: l(okInk, other.okInk),
      snack: l(snack, other.snack),
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t) ?? other.cardShadow,
    );
  }
}

/// The app icon's warm colors. Used in only three places in the UI: primary buttons, "my devices" avatars and the check
/// circle on the done page.
class ShareMeGradients {
  /// Avatars and the check circle: gold → vermilion → deep red. White icons sit over the darker middle, so contrast is sufficient.
  static const brand = LinearGradient(
    begin: Alignment(-0.8, -1),
    end: Alignment(0.8, 1),
    colors: [Color(0xFFF4A23F), Color(0xFFE2582B), Color(0xFFC0301F)],
    stops: [0, 0.45, 1],
  );

  /// Primary button: slightly darker than the avatar; white text on the middle color has a contrast ratio of about 4.8:1.
  static const button = LinearGradient(colors: [Color(0xFFDE5329), Color(0xFFBF2E1E)]);

  /// Warm drop shadow under primary buttons and avatars
  static const glow = Color(0xFFBF2E1E);
}

/// Card: white background (dark gray in dark mode) + rounded corners + soft shadow. Used for grouped lists on the home page,
/// in settings and in sheets.
BoxDecoration smCardDecoration(ShareMeColors c, {double radius = ShareMeSize.radiusGroup}) =>
    BoxDecoration(color: c.group, borderRadius: BorderRadius.circular(radius), boxShadow: c.cardShadow);

/// Colors for the Material ColorScheme, so built-in Material widgets (and LocalSend's original pages) use the same warm palette.
class ShareMeScheme {
  static const light = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFFC9411F),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFFBE3D6),
    onPrimaryContainer: Color(0xFF5A1A08),
    secondary: Color(0xFF5B5E62),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFEFEDE8),
    onSecondaryContainer: Color(0xFF16171A),
    tertiary: Color(0xFFD44A27),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFF9C5900),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFBEBD2),
    onErrorContainer: Color(0xFF3A2600),
    surface: Color(0xFFF5F4F1),
    onSurface: Color(0xFF16171A),
    onSurfaceVariant: Color(0xFF5B5E62),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFFFFFF),
    surfaceContainer: Color(0xFFFFFFFF),
    surfaceContainerHigh: Color(0xFFFFFFFF),
    surfaceContainerHighest: Color(0xFFEFEDE8),
    outline: Color(0xFF8E9195),
    outlineVariant: Color(0xFFECEAE5),
    inverseSurface: Color(0xFF1E1F22),
    onInverseSurface: Color(0xFFF3F3F1),
    inversePrimary: Color(0xFFF28A4B),
    scrim: Color(0xFF101113),
    shadow: Color(0xFF000000),
    surfaceTint: Color(0x00000000),
  );

  static const dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFF28A4B),
    onPrimary: Color(0xFF2A1306),
    primaryContainer: Color(0xFF382820),
    onPrimaryContainer: Color(0xFFFFD9C4),
    secondary: Color(0xFFA6A9AE),
    onSecondary: Color(0xFF0F1012),
    secondaryContainer: Color(0xFF26282C),
    onSecondaryContainer: Color(0xFFEDEEF0),
    tertiary: Color(0xFFE0572F),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFE9A54C),
    onError: Color(0xFF2A1C00),
    errorContainer: Color(0xFF3A2A12),
    onErrorContainer: Color(0xFFFBEBD2),
    surface: Color(0xFF0F1012),
    onSurface: Color(0xFFEDEEF0),
    onSurfaceVariant: Color(0xFFA6A9AE),
    surfaceContainerLowest: Color(0xFF0B0C0D),
    surfaceContainerLow: Color(0xFF15161A),
    surfaceContainer: Color(0xFF1B1C1F),
    surfaceContainerHigh: Color(0xFF1B1C1F),
    surfaceContainerHighest: Color(0xFF26282C),
    outline: Color(0xFF767A80),
    outlineVariant: Color(0xFF2A2C30),
    inverseSurface: Color(0xFFEDEEF0),
    onInverseSurface: Color(0xFF0F1012),
    inversePrimary: Color(0xFFC9411F),
    scrim: Color(0xFF000000),
    shadow: Color(0xFF000000),
    surfaceTint: Color(0x00000000),
  );
}

/// Fonts and type scale (all sans-serif).
///
/// - sans: the system sans-serif font (MiSans on MIUI, Microsoft YaHei on Windows), not bundled. All digits use tabular figures,
///   so sizes and speeds keep their width while the numbers change.
/// - mono: bundled Latin subset of JetBrains Mono (400 / 500); only the edge codes of the legacy "film strip" in the history
///   details still use it.
class ShareMeText {
  static const mono = 'JetBrainsMono';
  static const _tabular = [FontFeature.tabularFigures()];

  static TextStyle _sans(double size, double lineHeight, FontWeight weight, {double letterSpacingEm = 0}) => TextStyle(
    fontSize: size,
    height: lineHeight / size,
    fontWeight: weight,
    letterSpacing: letterSpacingEm * size,
    fontFeatures: _tabular,
  );

  static TextStyle _mono(double size, double lineHeight, FontWeight weight, {double letterSpacingEm = 0}) => TextStyle(
    fontFamily: mono,
    fontSize: size,
    height: lineHeight / size,
    fontWeight: weight,
    letterSpacing: letterSpacingEm * size,
  );

  // Headings
  static final display = _sans(26, 34, FontWeight.w700, letterSpacingEm: -0.01);
  static final headline = _sans(26, 34, FontWeight.w700, letterSpacingEm: -0.01);
  static final brand = _sans(20, 26, FontWeight.w700, letterSpacingEm: -0.01);
  static final deviceName = _sans(16.5, 22, FontWeight.w600);
  static final deviceNameSm = _sans(15.5, 21, FontWeight.w600);

  // Body text
  static final title = _sans(16, 22, FontWeight.w600);
  static final body = _sans(15, 22, FontWeight.w400);
  static final meta = _sans(13, 18, FontWeight.w400);
  static final section = _sans(13.5, 19, FontWeight.w600);
  static final label = _sans(15, 20, FontWeight.w600);
  static final labelPrimary = _sans(16, 20, FontWeight.w600);
  static final labelSm = _sans(12, 16, FontWeight.w500);

  // Numbers (size, speed, time remaining)
  static final dataLg = _sans(44, 48, FontWeight.w600);
  static final data = _sans(12.5, 16, FontWeight.w500);

  // Edge codes and frame numbers of the legacy film strip
  static final edge = _mono(10.5, 14, FontWeight.w400, letterSpacingEm: 0.01);
  static final frameNo = _mono(10, 16, FontWeight.w400, letterSpacingEm: 0.06);

  /// Maps the type scale onto Material's TextTheme.
  static TextTheme textTheme(ShareMeColors c) => TextTheme(
    displaySmall: display.copyWith(color: c.ink),
    headlineMedium: headline.copyWith(color: c.ink),
    titleLarge: deviceName.copyWith(color: c.ink),
    titleMedium: title.copyWith(color: c.ink),
    bodyLarge: body.copyWith(color: c.ink),
    bodyMedium: meta.copyWith(color: c.ink2),
    labelLarge: label.copyWith(color: c.ink),
    labelSmall: labelSm.copyWith(color: c.ink2),
  );
}

/// Corner radii and sizes.
class ShareMeSize {
  static const radiusFrame = 4.0;
  static const radiusTag = 8.0;
  static const radiusTile = 13.0;
  static const radiusButton = 18.0;
  static const radiusGroup = 22.0;
  static const radiusSheet = 28.0;
  static const radiusPill = 999.0;
  static const buttonH = 56.0;
  static const buttonHSm = 44.0;
  static const navBarH = 72.0;
  static const icon = 22.0;
}

/// Motion durations and curves.
class ShareMeMotion {
  static const press = Duration(milliseconds: 120);
  static const short = Duration(milliseconds: 200);
  static const medium = Duration(milliseconds: 300);
  static const stamp = Duration(milliseconds: 260);
  static const stagger = Duration(milliseconds: 30);
  static const standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const enter = Cubic(0.05, 0.7, 0.1, 1.0);
  static const exit = Cubic(0.3, 0.0, 0.8, 0.15);
  static const stampCurve = Cubic(0.34, 1.4, 0.64, 1.0);
}

extension ShareMeThemeContext on BuildContext {
  ShareMeColors get sm => Theme.of(this).extension<ShareMeColors>()!;
}

/// The Shuttle theme. A null [sansFamily] uses the system font (the Android default).
ThemeData buildShareMeTheme(Brightness brightness, {String? sansFamily}) {
  final dark = brightness == Brightness.dark;
  final c = dark ? ShareMeColors.dark : ShareMeColors.light;
  final scheme = dark ? ShareMeScheme.dark : ShareMeScheme.light;
  final textTheme = ShareMeText.textTheme(c);

  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusButton));
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(ShareMeSize.radiusButton),
    borderSide: BorderSide.none,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    fontFamily: sansFamily,
    textTheme: textTheme,
    // Same density on phone and desktop (as LocalSend does)
    visualDensity: VisualDensity.standard,
    extensions: [c],
    iconTheme: IconThemeData(color: c.ink, size: ShareMeSize.icon),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.28),
      selectionHandleColor: c.accent,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: ShareMeText.title.copyWith(color: c.ink, fontSize: 18),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: ShareMeSize.navBarH,
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: c.accentSoft,
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.accent : c.ink2, size: ShareMeSize.icon),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => ShareMeText.labelSm.copyWith(
          color: s.contains(WidgetState.selected) ? c.ink : c.ink2,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.group,
      indicatorColor: c.accentSoft,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: IconThemeData(color: c.accent, size: ShareMeSize.icon),
      unselectedIconTheme: IconThemeData(color: c.ink2, size: ShareMeSize.icon),
      selectedLabelTextStyle: ShareMeText.labelSm.copyWith(color: c.ink, fontWeight: FontWeight.w700),
      unselectedLabelTextStyle: ShareMeText.labelSm.copyWith(color: c.ink2),
    ),
    // Primary button: the icon's warm gradient + a warm drop shadow (one per screen).
    // The gradient is painted by backgroundBuilder; when disabled it falls back to the tonal background.
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: c.tonal,
            disabledForegroundColor: c.ink3,
            shadowColor: Colors.transparent,
            minimumSize: const Size(64, ShareMeSize.buttonH),
            shape: buttonShape,
            textStyle: ShareMeText.labelPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 24),
          ).copyWith(
            backgroundBuilder: (context, states, child) => states.contains(WidgetState.disabled)
                ? child ?? const SizedBox.shrink()
                : DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: ShareMeGradients.button,
                      borderRadius: BorderRadius.circular(ShareMeSize.radiusButton),
                      boxShadow: [
                        BoxShadow(
                          color: ShareMeGradients.glow.withValues(alpha: dark ? 0.35 : 0.42),
                          blurRadius: 22,
                          spreadRadius: -10,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: child,
                  ),
          ),
    ),
    // LocalSend's existing pages use ElevatedButton a lot: style it as the secondary (tonal) button, without a shadow
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.tonal,
        foregroundColor: c.ink,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        minimumSize: const Size(64, ShareMeSize.buttonHSm),
        shape: buttonShape,
        textStyle: ShareMeText.label,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.line),
        minimumSize: const Size(64, ShareMeSize.buttonHSm),
        shape: buttonShape,
        textStyle: ShareMeText.label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.ink,
        shape: buttonShape,
        textStyle: ShareMeText.label,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: c.ink)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.group,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.accent, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      hintStyle: ShareMeText.body.copyWith(color: c.ink3),
    ),
    cardTheme: CardThemeData(
      color: c.group,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.ink2,
      textColor: c.ink,
      titleTextStyle: ShareMeText.title.copyWith(color: c.ink),
      subtitleTextStyle: ShareMeText.meta.copyWith(color: c.ink2),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.group,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.ink3,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(ShareMeSize.radiusSheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.group,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusSheet)),
      titleTextStyle: ShareMeText.title.copyWith(color: c.ink, fontSize: 18),
      contentTextStyle: ShareMeText.body.copyWith(color: c.ink2),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.snack,
      contentTextStyle: ShareMeText.body.copyWith(color: const Color(0xFFF3F3F1)),
      actionTextColor: const Color(0xFFFFB48C),
      behavior: SnackBarBehavior.floating,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusButton)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : c.ink3),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.tonalStrong),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      side: BorderSide(color: c.ink3, width: 1.5),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.ink3)),
    chipTheme: ChipThemeData(
      backgroundColor: c.tonal,
      selectedColor: c.ink,
      labelStyle: ShareMeText.labelSm.copyWith(color: c.ink),
      side: BorderSide.none,
      shape: const StadiumBorder(),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : c.group),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onInk : c.ink),
        side: WidgetStatePropertyAll(BorderSide(color: c.line)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.tonalStrong, circularTrackColor: c.tonal),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.snack, borderRadius: BorderRadius.circular(ShareMeSize.radiusTag)),
      textStyle: ShareMeText.labelSm.copyWith(color: const Color(0xFFF3F3F1)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.group,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusButton)),
    ),
  );
}
