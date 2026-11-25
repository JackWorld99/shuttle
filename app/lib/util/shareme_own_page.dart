import 'package:flutter/widgets.dart';

/// Closes the page [context] belongs to, and only that one.
///
/// Transfer pages close by themselves (delivered, session gone). By then a new request may have opened on top of them, and going home
/// would close that one too, which answers its sender with "declined".
///
/// [close] is how the page closes when nothing is on top of it. [ownSheet] means that a sheet of this page is open ("Stop sending?"):
/// it goes as well.
void closeOwnPage(BuildContext context, VoidCallback close, {bool ownSheet = false}) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isActive) return; // closing already
  final navigator = Navigator.of(context);
  if (ownSheet && !route.isCurrent && _top(navigator) is PopupRoute) navigator.pop();
  if (route.isCurrent) {
    close();
  } else {
    navigator.removeRoute(route);
  }
}

Route<dynamic>? _top(NavigatorState navigator) {
  Route<dynamic>? top;
  navigator.popUntil((route) {
    top = route;
    return true; // only looking
  });
  return top;
}
