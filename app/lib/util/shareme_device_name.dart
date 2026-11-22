// Shuttle: the default device name is the one the system uses.
//
// On first launch LocalSend picks a random "adjective + fruit" name (e.g. Great Tomato), which doesn't tell you which device it is.
// Use a recognizable name instead: the computer name on PCs (e.g. OFFICE-PC, via LocalSend's own getDeviceName()), and on phones the
// name the owner gave the phone (e.g. "Alice's phone"), or else the marketing model name (e.g. Redmi Note 13 Pro).
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/device_info_helper.dart';
import 'package:logging/logging.dart';

final _logger = Logger('DeviceName');

/// The system's device name, falling back to a random name if it is unavailable.
///
/// On Android the system device_name isn't used: Xiaomi sets it to a model code nobody recognizes. Native code tries, in order, the
/// name the owner gave the phone → the marketing model name (e.g. Redmi Note 13 Pro) → the model code (MainActivity.friendlyDeviceName).
Future<String> defaultDeviceAlias() async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final name = (await android_channel.getFriendlyDeviceNameAndroid())?.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (e) {
      _logger.warning('Could not get the friendly device name', e);
    }
  }
  try {
    final name = (await getDeviceName())?.trim();
    if (name != null && name.isNotEmpty) return name;
  } catch (e) {
    _logger.warning('Could not get the system device name', e);
  }
  return generateRandomAlias();
}

/// Whether [alias] is a random LocalSend name (an "adjective + fruit" in English or Simplified Chinese). Custom names don't count.
Future<bool> isGeneratedAlias(String alias) async {
  for (final locale in const [AppLocale.en, AppLocale.zhCn]) {
    final generator = (await locale.build()).aliasGenerator;
    for (final adjective in generator.adjectives) {
      for (final fruit in generator.fruits) {
        if (generator.combination(adjective: adjective, fruit: fruit) == alias) return true;
      }
    }
  }
  return false;
}

/// Whether the alias should be replaced with the system device name: yes for a random LocalSend name or an Android model code
/// (before this version, the automatic rename set Xiaomi phones to a model code). Custom names are kept.
Future<bool> shouldUseDeviceAlias(String alias) async {
  if (await isGeneratedAlias(alias)) return true;
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return (await DeviceInfoPlugin().androidInfo).model.trim() == alias.trim();
  } catch (_) {
    return false;
  }
}
