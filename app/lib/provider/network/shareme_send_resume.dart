// Shuttle: continuing interrupted transfers (resume), sending side: what the send page needs to know about it.
// The logic is in send_provider.dart. See docs/resume-transfer-design.md in the project folder.

import 'package:refena_flutter/refena_flutter.dart';

/// Delays between the automatic attempts to continue after a lost connection: about 2 minutes in all, which covers a
/// Wi-Fi hiccup, a router restart or Tailscale reconnecting. After that, "Continue sending" is offered.
const defaultContinueDelays = [
  Duration(seconds: 3),
  Duration(seconds: 6),
  Duration(seconds: 12),
  Duration(seconds: 25),
  Duration(seconds: 50),
];

/// The delays in use ([defaultContinueDelays]; tests shorten them).
List<Duration> continueDelays = defaultContinueDelays;

/// The resume state of one send session.
class SendResume {
  /// The receiver can continue interrupted uploads (it answered Shuttle's resume extension).
  bool supported = false;

  /// The offset each file starts at, as the receiver named it in its latest answer.
  Map<String, int> offsets = {};

  /// The files whose upload was interrupted by a lost connection, to be continued.
  final Set<String> interrupted = {};

  /// The PIN the receiver asked for, so a continuation does not ask again.
  String? pin;

  /// The number of the automatic attempt to continue that is running, or `null`.
  int? reconnectAttempt;

  /// The automatic attempts are over: "Continue sending" continues the interrupted files.
  bool canContinue = false;

  /// The bytes the receiver already had when the latest answer came (for "Continuing from 63%").
  int continuedBytes = 0;
}

final sendResumeProvider = ChangeNotifierProvider((ref) => SendResumeNotifier());

/// The resume state of the send sessions, by session ID.
class SendResumeNotifier extends ChangeNotifier {
  final _sessions = <String, SendResume>{};

  SendResume? get(String sessionId) => _sessions[sessionId];

  SendResume ensure(String sessionId) => _sessions.putIfAbsent(sessionId, SendResume.new);

  /// Applies [change] and lets the pages rebuild.
  void update(String sessionId, void Function(SendResume resume) change) {
    change(ensure(sessionId));
    notifyListeners();
  }

  void remove(String sessionId) {
    if (_sessions.remove(sessionId) != null) notifyListeners();
  }
}
