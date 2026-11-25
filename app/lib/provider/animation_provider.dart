import 'package:flutter/scheduler.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// If true, then animations are disabled.
/// Used when the app is in the background.
final sleepProvider = StateProvider<bool>((ref) {
  return false;
}, debugLabel: 'sleepProvider');

/// If false, then animations are disabled.
final animationProvider = ViewProvider<bool>((ref) {
  final sleeping = ref.watch(sleepProvider);
  final enableAnimations = ref.watch(settingsProvider.select((s) => s.enableAnimations));
  final animations = enableAnimations && !sleeping;

  timeDilation = animations ? 1.0 : 0.00001;
  if (animations) {
    setDefaultRouteTransition();
  } else {
    Routerino.transition = RouterinoTransition.noTransition;
  }

  return animations;
}, debugLabel: 'animationProvider');

void setDefaultRouteTransition() {
  // Shuttle: a short fade on desktop (LocalSend slides the whole window sideways, which looks heavy on a large screen)
  if (checkPlatformIsDesktop()) {
    Routerino.transition = RouterinoTransition.fade(duration: const Duration(milliseconds: 200));
  } else {
    Routerino.transition = RouterinoTransition.material;
  }
}
