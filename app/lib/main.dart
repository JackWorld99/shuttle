import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/init_error.dart';
import 'package:localsend_app/config/shareme_licenses.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/widget/watcher/life_cycle_watcher.dart';
import 'package:localsend_app/widget/watcher/shortcut_watcher.dart';
import 'package:localsend_app/widget/watcher/tray_watcher.dart';
import 'package:localsend_app/widget/watcher/window_brightness_watcher.dart';
import 'package:localsend_app/widget/watcher/window_watcher.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:system_date_time_format/system_date_time_format.dart';

Future<void> main(List<String> args) async {
  final RefenaContainer container;
  try {
    container = await preInit(args);
  } catch (e, stackTrace) {
    showInitErrorApp(
      error: e,
      stackTrace: stackTrace,
    );
    return;
  }

  registerShareMeFontLicenses(); // Shuttle: font licenses
  _enableSemanticsForTests(); // Shuttle: for automated tests

  runApp(
    RefenaScope.withContainer(
      container: container,
      child: SDTFScope(
        child: TranslationProvider(
          child: const LocalSendApp(),
        ),
      ),
    ),
  );
}

/// Shuttle: by default the desktop app only exposes its buttons to the Windows accessibility API when a screen reader is running.
/// With the environment variable SHAREME_SEMANTICS=1 they are always exposed, so automated tests can find and "invoke" buttons
/// via UI Automation instead of simulating the mouse (simulated clicks were blocked in the test environment). Normal launches
/// are unaffected.
/// Observed: with this switch on, UI Automation still sees only a single FLUTTERVIEW and no buttons in the Windows build
/// (Flutter's Windows embedder seems to expose them only when it detects a screen reader). So this path is unused for now;
/// the switch is kept to try again later.
// The handle only needs to be held (disposing it turns semantics off again), so nothing reads it
// ignore: unused_element
SemanticsHandle? _testSemantics;

void _enableSemanticsForTests() {
  if (!checkPlatformIsDesktop()) return;
  if (Platform.environment['SHAREME_SEMANTICS'] != '1') return;
  _testSemantics = SemanticsBinding.instance.ensureSemantics();
}

class LocalSendApp extends StatelessWidget {
  const LocalSendApp();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final (themeMode, colorMode, customColor) = ref.watch(
      settingsProvider.select((settings) => (settings.theme, settings.colorMode, settings.customColor)),
    );
    final dynamicColors = ref.watch(dynamicColorsProvider);
    return TrayWatcher(
      child: WindowWatcher(
        child: LifeCycleWatcher(
          onChangedState: (AppLifecycleState state) {
            switch (state) {
              case AppLifecycleState.resumed:
                ref.redux(localIpProvider).dispatch(InitLocalIpAction());
                // Shuttle: when "my devices" are connected only via Tailscale while this device is on a LAN, look for a direct
                // LAN connection again (see RescanForLanAction)
                unawaited(ref.global.dispatchAsync(RescanForLanAction()));
                if (checkPlatform([TargetPlatform.iOS, TargetPlatform.android])) {
                  // The OS may have invalidated the sockets of the suspended app without any error ever reaching the accept loop.
                  // ignore: discarded_futures
                  ref.notifier(serverProvider).ensureRunning();
                }
                if (checkPlatform([TargetPlatform.iOS])) {
                  // The multicast sockets die the same silent way but cannot be probed, so always rebind them.
                  ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryRestartAction());
                }
                break;
              case AppLifecycleState.detached:
                // The main isolate is only exited when all child isolates are exited.
                // https://github.com/localsend/localsend/issues/1568
                ref.redux(parentIsolateProvider).dispatch(IsolateDisposeAction());
                break;
              default:
                break;
            }
          },
          child: ShortcutWatcher(
            child: MaterialApp(
              title: t.appName,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              debugShowCheckedModeBanner: false,
              theme: getTheme(colorMode, customColor, Brightness.light, dynamicColors),
              darkTheme: getTheme(colorMode, customColor, Brightness.dark, dynamicColors),
              themeMode: colorMode == ColorMode.oled ? ThemeMode.dark : themeMode,
              builder: (context, child) => WindowBrightnessWatcher(child: child!),
              navigatorKey: context.read(navigationProvider).key,
              home: RouterinoHome(
                builder: () => const HomePage(
                  initialTab: HomeTab.transfer,
                  appStart: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
