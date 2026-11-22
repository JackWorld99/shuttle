import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/util/network_interfaces.dart';
import 'package:logging/logging.dart';
import 'package:network_info_plus/network_info_plus.dart' as plugin;
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('NetworkInfo');

final localIpProvider = ReduxProvider<LocalIpService, NetworkState>((ref) {
  return LocalIpService(
    ref.notifier(settingsProvider),
  );
});

StreamSubscription? _subscription;

/// Shuttle: whether the local addresses really changed (Wi-Fi ↔ mobile data, Tailscale connecting or disconnecting). If so, the
/// old device list should be cleared and a new scan started; otherwise, after the phone switches to mobile data, "my devices"
/// still show as being on the same Wi-Fi (direct). Only the address sets are compared (order ignored); the first addresses after
/// app start don't count, since startup scans anyway.
bool localIpsChanged(NetworkState prev, NetworkState next) {
  return prev.initialized && !const SetEquality<String>().equals(prev.localIps.toSet(), next.localIps.toSet());
}

class LocalIpService extends ReduxNotifier<NetworkState> {
  final SettingsService _settingsService;

  LocalIpService(this._settingsService);

  @override
  NetworkState init() {
    return const NetworkState(
      localIps: [],
      initialized: false,
    );
  }

  @override
  get initialAction => InitLocalIpAction();
}

/// Fetches the local IP address and registers a listener to update the IP address
class InitLocalIpAction extends ReduxAction<LocalIpService, NetworkState> {
  @override
  NetworkState reduce() {
    if (!kIsWeb) {
      // ignore: discarded_futures
      _subscription?.cancel();

      if (checkPlatform([TargetPlatform.windows])) {
        // https://github.com/localsend/localsend/issues/12
        // https://github.com/localsend/localsend/issues/78
      } else {
        _subscription = Connectivity().onConnectivityChanged.listen((_) async {
          await dispatchAsync(FetchLocalIpAction());
        });
      }
    }

    return state;
  }

  @override
  void after() {
    // ignore: discarded_futures
    dispatchAsync(FetchLocalIpAction());
  }
}

class FetchLocalIpAction extends AsyncReduxAction<LocalIpService, NetworkState> {
  @override
  Future<NetworkState> reduce() async {
    final result = await _getIp(
      whitelist: notifier._settingsService.state.networkWhitelist,
      blacklist: notifier._settingsService.state.networkBlacklist,
    );
    return NetworkState(
      localIps: result.ips,
      interfaceNames: result.interfaceNames,
      initialized: true,
    );
  }
}

Future<({List<String> ips, Map<String, String> interfaceNames})> _getIp({
  required List<String>? whitelist,
  required List<String>? blacklist,
}) async {
  final info = plugin.NetworkInfo();
  String? ip;
  try {
    ip = await info.getWifiIP();
  } catch (e) {
    _logger.warning('Failed to get wifi IP', e);
  }

  final interfaces = await getNetworkInterfaces(
    whitelist: whitelist,
    blacklist: blacklist,
  );
  final nativeResult = interfaces
      .map((interface) => interface.addresses.map((a) => a.address).toList())
      .expand((ip) => ip)
      .where((ip) => !ip.contains(':')) // ignore IPv6 for now
      .toList();
  final interfaceNames = ipv4InterfaceNames(interfaces);

  final addresses = rankIpAddresses(nativeResult, ip);
  _logger.info('Network state: ${[for (final a in addresses) interfaceNames[a] == null ? a : '$a (${interfaceNames[a]})']}');
  return (ips: addresses, interfaceNames: interfaceNames);
}

/// Shuttle: the network interface of each IPv4 address (Android: wlan0 / rmnet_data0 / tun0 …, Windows: Wi-Fi / Tailscale …).
/// Pairing uses it to drop addresses the peer can't reach, such as the mobile-data interface (pairAddresses), instead of guessing
/// Tailscale from the address range alone.
Map<String, String> ipv4InterfaceNames(Iterable<NetworkInterface> interfaces) {
  return {
    for (final interface in interfaces)
      for (final a in interface.addresses)
        if (a.type == InternetAddressType.IPv4) a.address: interface.name,
  };
}

List<String> rankIpAddresses(List<String> nativeResult, String? thirdPartyResult) {
  if (thirdPartyResult == null) {
    // only take the list
    return nativeResult._rankIpAddresses(null);
  } else if (nativeResult.isEmpty) {
    // only take the first IP from third party library
    return [thirdPartyResult];
  } else if (thirdPartyResult.endsWith('.1')) {
    // merge
    return {thirdPartyResult, ...nativeResult}.toList()._rankIpAddresses(null);
  } else {
    // merge but prefer result from third party library
    return {thirdPartyResult, ...nativeResult}.toList()._rankIpAddresses(thirdPartyResult);
  }
}

/// Sorts Ip addresses with first being the most likely primary local address
/// Currently,
/// - sorts ending with ".1" last
/// - primary is always first
extension ListIpExt on List<String> {
  List<String> _rankIpAddresses(String? primary) {
    return sorted((a, b) {
      int scoreA = a == primary ? 10 : (a.endsWith('.1') ? 0 : 1);
      int scoreB = b == primary ? 10 : (b.endsWith('.1') ? 0 : 1);
      return scoreB.compareTo(scoreA);
    });
  }
}
