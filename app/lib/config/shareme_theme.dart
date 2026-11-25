// Shuttle design theme ("warm"): warm off-white background + white cards + sans-serif type; the app icon's warm colors
// (gold → vermilion → deep red) are used only for primary buttons, "my devices" avatars and a few accents.
// No Material You dynamic color: the warm palette is the identity.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

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

  /// Cards: a barely visible vertical tint (translucent in dark mode, so the backdrop glows through) and a hairline edge
  final Color cardTop;
  final Color cardBottom;
  final Color cardBorder;

  /// Neutral icon tiles (unknown or offline devices, files): a light vertical tint ([smTileDecoration])
  final Color tileTop;
  final Color tileBottom;

  /// Selected navigation item and filter chip: translucent warm fill
  final Color selected;

  /// Hairline edge of secondary buttons
  final Color buttonEdge;

  /// Background of bottom sheets, dialogs and menus (a touch warmer than [group])
  final Color sheet;

  /// Ambient backdrop ([SmAmbient]): base gradient plus two soft warm glows, top right and left middle
  final Color bgTop;
  final Color bgBottom;
  final Color glow1;
  final Color glow2;

  /// Primary buttons: vertical gradient and the sheen along the top edge
  final List<Color> buttonGradient;
  final Color buttonSheen;

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
    required this.cardTop,
    required this.cardBottom,
    required this.cardBorder,
    required this.tileTop,
    required this.tileBottom,
    required this.selected,
    required this.buttonEdge,
    required this.sheet,
    required this.bgTop,
    required this.bgBottom,
    required this.glow1,
    required this.glow2,
    required this.buttonGradient,
    required this.buttonSheen,
  });

  static const light = ShareMeColors(
    bg: Color(0xFFF5F4F1),
    group: Color(0xFFFFFFFF),
    tonal: Color(0xFFEFEDE8),
    tonalStrong: Color(0xFFE1DED7),
    ink: Color(0xFF16171A),
    ink2: Color(0xFF5B5E62),
    ink3: Color(0xFF6B6F74),
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
      BoxShadow(color: Color(0x2E7A3A14), blurRadius: 34, spreadRadius: -18, offset: Offset(0, 18)),
    ],
    cardTop: Color(0xFFFFFFFF),
    cardBottom: Color(0xFFFDFBF7),
    cardBorder: Color(0xE6FFFFFF),
    tileTop: Color(0xFFF8F5F0),
    tileBottom: Color(0xFFEAE6DE),
    selected: Color(0x38F2783C),
    buttonEdge: Color(0x2E7A3A14),
    sheet: Color(0xFFFFFDFA),
    bgTop: Color(0xFFFBF7F0),
    bgBottom: Color(0xFFF4F1EA),
    glow1: Color(0x66F4A23F),
    glow2: Color(0x33E2582B),
    buttonGradient: [Color(0xFFE0592C), Color(0xFFC63C1F), Color(0xFFB5301C)],
    buttonSheen: Color(0x66FFFFFF),
  );

  static const dark = ShareMeColors(
    // Warm blacks and grays: next to the warm light, neutral ones looked blue
    bg: Color(0xFF100E0C),
    group: Color(0xFF1E1B19),
    // Translucent white, so the warm backdrop shows through (opaque grays looked bluish on the glass cards)
    tonal: Color(0x1CFFFFFF),
    tonalStrong: Color(0x2EFFFFFF),
    ink: Color(0xFFF3EFEB),
    ink2: Color(0xFFB4ACA5),
    ink3: Color(0xFF9A928B),
    line: Color(0x1CFFFFFF),
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
    snack: Color(0xFF2E2926),
    // None: the cards are translucent, so a shadow would show through them; the hairline edge and the tint separate them enough
    cardShadow: [],
    cardTop: Color(0x1AFFF4EA),
    cardBottom: Color(0x0DFFF4EA),
    cardBorder: Color(0x21FFF4EA),
    tileTop: Color(0x26FFFFFF),
    tileBottom: Color(0x12FFFFFF),
    selected: Color(0x40F2783C),
    buttonEdge: Color(0x24FFFFFF),
    sheet: Color(0xFF1C1A19),
    bgTop: Color(0xFF151210),
    bgBottom: Color(0xFF0B0908),
    glow1: Color(0x66F2783C),
    glow2: Color(0x45C0301F),
    buttonGradient: [Color(0xFFDD5A2E), Color(0xFFC23D21), Color(0xFFAF2E1C)],
    buttonSheen: Color(0x5CFFFFFF),
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
      cardTop: l(cardTop, other.cardTop),
      cardBottom: l(cardBottom, other.cardBottom),
      cardBorder: l(cardBorder, other.cardBorder),
      tileTop: l(tileTop, other.tileTop),
      tileBottom: l(tileBottom, other.tileBottom),
      selected: l(selected, other.selected),
      buttonEdge: l(buttonEdge, other.buttonEdge),
      sheet: l(sheet, other.sheet),
      bgTop: l(bgTop, other.bgTop),
      bgBottom: l(bgBottom, other.bgBottom),
      glow1: l(glow1, other.glow1),
      glow2: l(glow2, other.glow2),
      buttonGradient: [for (var i = 0; i < buttonGradient.length; i++) l(buttonGradient[i], other.buttonGradient[i])],
      buttonSheen: l(buttonSheen, other.buttonSheen),
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

  /// Warm drop shadow under primary buttons and avatars
  static const glow = Color(0xFFBF2E1E);
}

/// Card: white (slightly warm) in light mode, dark glass in dark mode; hairline edge, rounded corners, soft shadow. Used for grouped
/// lists on the home page, in settings and in sheets.
BoxDecoration smCardDecoration(ShareMeColors c, {double radius = ShareMeSize.radiusGroup}) => BoxDecoration(
  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.cardTop, c.cardBottom]),
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: c.cardBorder),
  boxShadow: c.cardShadow,
);

/// A neutral icon tile: unknown or offline devices, file type icons. [color] replaces the neutral tint (e.g. the amber warning tile).
BoxDecoration smTileDecoration(ShareMeColors c, {required double radius, Color? color}) => BoxDecoration(
  color: color,
  gradient: color != null ? null : LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.tileTop, c.tileBottom]),
  borderRadius: BorderRadius.circular(radius),
  border: color != null ? null : Border.all(color: c.line),
);

/// Colors of a file type tile: a light warm tint per kind instead of the same gray for everything. Opaque, because tiles are stacked.
({Color top, Color bottom, Color icon}) smKindColors({required bool dark, required String kind}) => switch ((kind, dark)) {
  ('image', false) => (top: const Color(0xFFFFEBD3), bottom: const Color(0xFFF9D2A8), icon: const Color(0xFFA94E17)),
  ('video', false) => (top: const Color(0xFFFFEAE3), bottom: const Color(0xFFF8D0C2), icon: const Color(0xFFAE3A22)),
  ('pdf', false) => (top: const Color(0xFFFDE8E5), bottom: const Color(0xFFF4CAC4), icon: const Color(0xFFA52A20)),
  ('text', false) => (top: const Color(0xFFF7F1E7), bottom: const Color(0xFFE9DFCF), icon: const Color(0xFF6B5640)),
  (_, false) => (top: const Color(0xFFF6F3ED), bottom: const Color(0xFFE6E1D8), icon: const Color(0xFF5E5A54)),
  ('image', true) => (top: const Color(0xFF5C3F25), bottom: const Color(0xFF422E1D), icon: const Color(0xFFF6BE8A)),
  ('video', true) => (top: const Color(0xFF583226), bottom: const Color(0xFF40261F), icon: const Color(0xFFF4A891)),
  ('pdf', true) => (top: const Color(0xFF572B28), bottom: const Color(0xFF402120), icon: const Color(0xFFF29C92)),
  ('text', true) => (top: const Color(0xFF3A342C), bottom: const Color(0xFF2B2722), icon: const Color(0xFFD2C6B6)),
  (_, true) => (top: const Color(0xFF36322F), bottom: const Color(0xFF292623), icon: const Color(0xFFBEB6AF)),
};

/// A recessed area inside a sheet or dialog (the received text, the device list): darker than the sheet, with a hairline edge.
BoxDecoration smInsetDecoration(ShareMeColors c, {double radius = ShareMeSize.radiusButton}) => BoxDecoration(
  color: c.bg,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: c.line),
);

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

/// Status bar icons that stay readable: white on a dark page, dark on a light one. The navigation bar is left as the app set it at
/// startup (updateSystemOverlayStyle).
SystemUiOverlayStyle smStatusBar({required bool darkBackground}) => SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: darkBackground ? Brightness.light : Brightness.dark, // Android
  statusBarBrightness: darkBackground ? Brightness.dark : Brightness.light, // iOS
);

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
      // Transparent so the ambient backdrop shows through. The status bar icons are stated explicitly because Flutter would guess
      // them from the (transparent) background.
      backgroundColor: Colors.transparent,
      systemOverlayStyle: smStatusBar(darkBackground: dark),
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: ShareMeText.title.copyWith(fontFamily: sansFamily, color: c.ink, fontSize: 18),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: ShareMeSize.navBarH,
      backgroundColor: Colors.transparent, // the home screen's ambient backdrop shows through
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: c.selected, // translucent: stays visible on the warm backdrop
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.accent : c.ink2, size: ShareMeSize.icon),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => ShareMeText.labelSm.copyWith(
          fontFamily: sansFamily,
          color: s.contains(WidgetState.selected) ? c.ink : c.ink2,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent, // the ambient backdrop shows through
      indicatorColor: c.selected, // translucent: stays visible on the warm backdrop
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: IconThemeData(color: c.accent, size: ShareMeSize.icon),
      unselectedIconTheme: IconThemeData(color: c.ink2, size: ShareMeSize.icon),
      selectedLabelTextStyle: ShareMeText.labelSm.copyWith(fontFamily: sansFamily, color: c.ink, fontWeight: FontWeight.w700),
      unselectedLabelTextStyle: ShareMeText.labelSm.copyWith(fontFamily: sansFamily, color: c.ink2),
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
            textStyle: ShareMeText.labelPrimary.copyWith(fontFamily: sansFamily),
            padding: const EdgeInsets.symmetric(horizontal: 24),
          ).copyWith(
            // Vertical warm gradient, a fine light along the top edge and a warm drop shadow; gives way a little when pressed
            backgroundBuilder: (context, states, child) =>
                states.contains(WidgetState.disabled) ? child ?? const SizedBox.shrink() : _PrimaryFill(colors: c, states: states, child: child),
          ),
    ),
    // Secondary buttons: a white button with a hairline edge and a faint shadow in light mode, translucent in dark mode (the old
    // flat gray almost vanished on the warm backdrop). LocalSend's own pages pass their own colors, which still work
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: dark ? c.tonal : c.group,
        foregroundColor: c.ink,
        disabledBackgroundColor: c.tonal,
        disabledForegroundColor: c.ink3,
        elevation: dark ? 0 : 1.5,
        shadowColor: const Color(0x667A3A14),
        surfaceTintColor: Colors.transparent,
        side: BorderSide(color: c.buttonEdge),
        minimumSize: const Size(64, ShareMeSize.buttonHSm),
        shape: buttonShape,
        textStyle: ShareMeText.label.copyWith(fontFamily: sansFamily),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.line),
        minimumSize: const Size(64, ShareMeSize.buttonHSm),
        shape: buttonShape,
        textStyle: ShareMeText.label.copyWith(fontFamily: sansFamily),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.ink,
        shape: buttonShape,
        textStyle: ShareMeText.label.copyWith(fontFamily: sansFamily),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: c.ink)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.group,
      border: inputBorder,
      enabledBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.line)),
      focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.accent, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      hintStyle: ShareMeText.body.copyWith(fontFamily: sansFamily, color: c.ink3),
    ),
    cardTheme: CardThemeData(
      color: c.group,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.cardBorder),
        borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.ink2,
      textColor: c.ink,
      titleTextStyle: ShareMeText.title.copyWith(fontFamily: sansFamily, color: c.ink),
      subtitleTextStyle: ShareMeText.meta.copyWith(fontFamily: sansFamily, color: c.ink2),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.sheet,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.ink3,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.cardBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(ShareMeSize.radiusSheet)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.sheet,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.cardBorder),
        borderRadius: BorderRadius.circular(ShareMeSize.radiusSheet),
      ),
      titleTextStyle: ShareMeText.title.copyWith(fontFamily: sansFamily, color: c.ink, fontSize: 18),
      contentTextStyle: ShareMeText.body.copyWith(fontFamily: sansFamily, color: c.ink2),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.snack,
      contentTextStyle: ShareMeText.body.copyWith(fontFamily: sansFamily, color: const Color(0xFFF3F3F1)),
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
      labelStyle: ShareMeText.labelSm.copyWith(fontFamily: sansFamily, color: c.ink),
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
      textStyle: ShareMeText.labelSm.copyWith(fontFamily: sansFamily, color: const Color(0xFFF3F3F1)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.sheet,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusButton)),
    ),
  );
}

/// Background of the primary buttons.
class _PrimaryFill extends StatelessWidget {
  final ShareMeColors colors;
  final Set<WidgetState> states;
  final Widget? child;

  const _PrimaryFill({required this.colors, required this.states, required this.child});

  @override
  Widget build(BuildContext context) {
    final pressed = states.contains(WidgetState.pressed);
    final lit = states.contains(WidgetState.hovered) || states.contains(WidgetState.focused);
    final radius = BorderRadius.circular(ShareMeSize.radiusButton);
    return AnimatedScale(
      scale: pressed ? 0.975 : 1,
      duration: Duration(milliseconds: pressed ? 90 : 260),
      curve: pressed ? Curves.easeOut : Curves.easeOutBack,
      child: AnimatedContainer(
        duration: ShareMeMotion.press,
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors.buttonGradient, stops: const [0, 0.6, 1]),
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: ShareMeGradients.glow.withValues(alpha: pressed ? 0.25 : 0.42),
              blurRadius: pressed ? 14 : 24,
              spreadRadius: -10,
              offset: Offset(0, pressed ? 6 : 13),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              // Hover lightens, pressing darkens
              Positioned.fill(
                child: AnimatedContainer(
                  duration: ShareMeMotion.press,
                  color: pressed
                      ? const Color(0x1A000000)
                      : lit
                      ? const Color(0x14FFFFFF)
                      : const Color(0x00FFFFFF),
                ),
              ),
              Positioned.fill(child: CustomPaint(painter: _TopLight(colors.buttonSheen))),
              child ?? const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }
}

/// A one-pixel light along the upper edge that fades out around the corners.
class _TopLight extends CustomPainter {
  final Color color;

  const _TopLight(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius((Offset.zero & size).deflate(0.5), const Radius.circular(ShareMeSize.radiusButton - 0.5));
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0, 0.45],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_TopLight old) => old.color != color;
}
