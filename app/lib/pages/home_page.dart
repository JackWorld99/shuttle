import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/shareme_history_page.dart';
import 'package:localsend_app/pages/shareme_settings_page.dart';
import 'package:localsend_app/pages/tabs/transfer_tab.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/shareme_presence.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/shareme_update_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' show listenPendingActionAndroid, takePendingActionAndroid;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:localsend_app/widget/shareme/desktop_layout.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// Shuttle: the navigation is "Transfer · History · Settings".
/// The old "Receive" page is gone (receiving always runs in the background); "Send" is merged into the "Transfer" home page.
enum HomeTab {
  transfer(LucideIcons.arrowLeftRight),
  history(LucideIcons.history),
  settings(LucideIcons.settings);

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.transfer:
        return t.shareme.nav.transfer;
      case HomeTab.history:
        return t.shareme.nav.history;
      case HomeTab.settings:
        return t.shareme.nav.settings;
    }
  }
}

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({
    required this.initialTab,
    required this.appStart,
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena {
  bool _dragAndDropIndicator = false;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<NotifierEvent<NetworkState>>? _networkWatch;
  Timer? _rescanSoon;
  final List<Timer> _rescanLater = [];
  Timer? _presence;

  @override
  void initState() {
    super.initState();

    // Shuttle: every 20 s, check that devices are still reachable; unreachable ones show "Offline" and go back to "Online"
    // when they return (shareme_presence.dart).
    _presence = Timer.periodic(presenceInterval, (_) => _checkPresence());

    ensureRef((ref) async {
      // Shuttle: when this device's addresses change (Wi-Fi ↔ mobile data, Tailscale up or down), clear the old device list
      // and rescan, same as tapping "Refresh". Wait 2 s first: Android fires several changes in a row while switching
      // networks (Wi-Fi down, mobile data up, VPN up), so let it settle.
      // Rescan at 10 s (keeping the list): once Wi-Fi is off, Tailscale needs a few seconds to move its tunnel to mobile data,
      // so the 2 s scan often can't reach the PC yet (in testing it found the PC when Wi-Fi came back, not when Wi-Fi went off).
      // Rescan again at 60 s and 120 s: for a while after the phone joins Wi-Fi, phone → PC connections fail while
      // PC → phone works (measured at 10 to 100 s). If the 2 s and 10 s scans both fall in that window, the PC is only found
      // via Tailscale, the list keeps showing "remote" and transfers take the slow path; and the rescan on returning to the
      // foreground never fires while the app stays in the foreground.
      // Upstream doesn't watch network changes on the PC (Windows) anyway (LocalSend #12, #78), so this only matters on phones.
      _networkWatch = ref.stream(localIpProvider).listen((event) {
        if (!localIpsChanged(event.prev, event.next)) return;
        _rescanSoon?.cancel();
        for (final timer in _rescanLater) {
          timer.cancel();
        }
        _rescanLater.clear();
        _rescanSoon = Timer(const Duration(seconds: 2), () {
          if (!mounted) return;
          ref.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
          unawaited(ref.global.dispatchAsync(StartSmartScan()));
        });
        for (final seconds in const [10, 60, 120]) {
          _rescanLater.add(
            Timer(Duration(seconds: seconds), () {
              if (!mounted) return;
              unawaited(ref.global.dispatchAsync(StartSmartScan()));
            }),
          );
        }
      });
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
      await _runPendingAction(); // Shuttle: cold start from the "send clipboard" quick settings tile
    });
    if (checkPlatform([TargetPlatform.android])) {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          _checkPresence(force: true); // skipped in the background, so re-check My devices now (send clipboard needs a device)
          unawaited(_runPendingAction());
        },
      );
      // There is no onResume when the app is already in the foreground, so the native side notifies us directly (otherwise
      // tapping the tile did nothing). If the app isn't resumed yet (the shade still covers it), leave the action to the
      // onResume above: the clipboard can only be read in the foreground.
      listenPendingActionAndroid(() {
        if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) unawaited(_runPendingAction());
      });
    }
  }

  /// Phones only check while Shuttle is in the foreground (saves battery); PCs always check (they stay in the tray, and
  /// "send clipboard" relies on it to pick a device).
  void _checkPresence({bool force = false}) {
    if (!mounted) return;
    if (checkPlatform([TargetPlatform.android, TargetPlatform.iOS]) && WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    unawaited(ref.global.dispatchAsync(CheckPresenceAction(force: force)));
  }

  @override
  void dispose() {
    _presence?.cancel();
    unawaited(_networkWatch?.cancel());
    _rescanSoon?.cancel();
    for (final timer in _rescanLater) {
      timer.cancel();
    }
    _lifecycle?.dispose();
    if (checkPlatform([TargetPlatform.android])) listenPendingActionAndroid(null);
    super.dispose();
  }

  /// Shuttle: the phone's "send clipboard" quick settings tile opens the app with a pending action. From Android 10 on, only
  /// the foreground app can read the clipboard, so wait (briefly) until the window is really in the foreground.
  Future<void> _runPendingAction() async {
    if (!checkPlatform([TargetPlatform.android])) return;
    final action = await takePendingActionAndroid();
    if (action != 'send_clipboard' || !mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.transfer));
    // Routerino.context is the global navigator context, not this State's (LocalSend uses it the same way elsewhere)
    // ignore: use_build_context_synchronously
    await sendClipboard(Routerino.context);
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);
    // Shuttle: a small dot on the "Settings" icon when a new version is downloaded (or waiting to be downloaded)
    final updateDot = context.watch(smUpdateProvider.select((s) => s.hasNewVersion));

    return DropTarget(
      onDragEntered: (_) {
        setState(() {
          _dragAndDropIndicator = true;
        });
        // Shuttle desktop: on drag-enter, switch to "Transfer" so its drop zone lights up (instead of LocalSend's full-screen overlay)
        if (useDesktopLayout(context)) {
          shareMeDragActive.value = true;
          vm.changeTab(HomeTab.transfer);
        }
      },
      onDragExited: (_) {
        setState(() {
          _dragAndDropIndicator = false;
        });
        shareMeDragActive.value = false;
      },
      onDragDone: (event) async {
        // the drop may contain a mix of files and directories
        final droppedDirectories = event.files.where((file) => Directory(file.path).existsSync()).toList();
        final droppedFiles = event.files.where((file) => !Directory(file.path).existsSync()).toList();

        for (final directory in droppedDirectories) {
          await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory.path));
        }

        if (droppedFiles.isNotEmpty) {
          await ref
              .redux(selectedSendingFilesProvider)
              .dispatchAsync(
                AddFilesAction(
                  files: droppedFiles,
                  converter: CrossFileConverters.convertXFile,
                ),
              );
        }
        vm.changeTab(HomeTab.transfer);
        // Shuttle desktop: after the drop, ask right away who to send to
        shareMeDragActive.value = false;
        if (mounted) setState(() => _dragAndDropIndicator = false);
        if (context.mounted && useDesktopLayout(context)) {
          await chooseTargetAndSend(context);
        }
      },
      child: ResponsiveBuilder(
        builder: (sizingInformation) {
          return Scaffold(
            body: Row(
              children: [
                if (!sizingInformation.isMobile)
                  NavigationRail(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    // Shuttle desktop: 76-wide navigation rail with labels under the icons (rail 76 | device column 300 | content)
                    extended: sizingInformation.isDesktop && !useDesktopLayout(context),
                    labelType: useDesktopLayout(context) ? NavigationRailLabelType.all : null,
                    minWidth: 76,
                    backgroundColor: Theme.of(context).cardColorWithElevation,
                    leading: sizingInformation.isDesktop && !useDesktopLayout(context)
                        ? Column(
                            children: [
                              const SizedBox(height: 20),
                              Text(
                                'Shuttle',
                                style: ShareMeText.brand.copyWith(color: context.sm.ink),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                            ],
                          )
                        : null,
                    destinations: HomeTab.values.map((tab) {
                      return NavigationRailDestination(
                        icon: _TabIcon(tab: tab, dot: updateDot),
                        label: Text(tab.label),
                      );
                    }).toList(),
                  ),
                Expanded(
                  child: SafeArea(
                    left: sizingInformation.isMobile,
                    child: Stack(
                      children: [
                        PageView(
                          controller: vm.controller,
                          physics: const NeverScrollableScrollPhysics(),
                          children: const [
                            TransferTab(),
                            SmHistoryPage(), // Shuttle: history page
                            SmSettingsPage(), // Shuttle: settings page
                          ],
                        ),
                        if (_dragAndDropIndicator && !useDesktopLayout(context))
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.file_download, size: 128),
                                const SizedBox(height: 30),
                                Text(t.sendTab.placeItems, style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // The navigation bar shares the page background, separated by a thin line along its top
            bottomNavigationBar: sizingInformation.isMobile
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: context.sm.line)),
                    ),
                    child: NavigationBar(
                      selectedIndex: vm.currentTab.index,
                      onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                      destinations: HomeTab.values.map((tab) {
                        return NavigationDestination(
                          icon: _TabIcon(tab: tab, dot: updateDot),
                          label: tab.label,
                        );
                      }).toList(),
                    ),
                  )
                : null,
          );
        },
      ),
    );
  }
}

/// Navigation icon; "Settings" gets a small dot at the top right when a new version is available.
class _TabIcon extends StatelessWidget {
  final HomeTab tab;
  final bool dot;

  const _TabIcon({required this.tab, required this.dot});

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: dot && tab == HomeTab.settings,
      smallSize: 8,
      backgroundColor: context.sm.accent,
      child: Icon(tab.icon),
    );
  }
}
