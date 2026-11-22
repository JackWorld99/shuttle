import 'package:localsend_app/gen/strings.g.dart';

/// Number formatting rules:
/// - Size: below 1 GB in MB with 1 decimal (248.6 MB); from 1 GB in GB with 2 decimals (1.84 GB); one space between number and unit.
/// - Speed: MB/s with 1 decimal.
/// - Duration: mm:ss.
String formatSize(int bytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String formatSpeed(double bytesPerSecond) => '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';

String formatDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// "just now / 2 min ago / 3 h ago / 5 d ago"
String formatAgo(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return t.shareme.time.justNow;
  if (diff.inHours < 1) return t.shareme.time.minutesAgo(n: diff.inMinutes);
  if (diff.inDays < 1) return t.shareme.time.hoursAgo(n: diff.inHours);
  return t.shareme.time.daysAgo(n: diff.inDays);
}

/// The first 16 characters of a fingerprint in groups of 4: "7F3A C21E 9B04 51D8" (shared by the receive and settings pages).
String groupFingerprint(String fp) {
  final s = fp.replaceAll(':', '').toUpperCase();
  final head = s.length > 16 ? s.substring(0, 16) : s;
  return [for (var i = 0; i < head.length; i += 4) head.substring(i, (i + 4).clamp(0, head.length))].join(' ');
}
