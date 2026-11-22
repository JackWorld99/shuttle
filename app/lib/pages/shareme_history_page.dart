import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/pages/tabs/transfer_tab.dart' show pickAndSend;
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/sent_history_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_app/widget/shareme/message_sheet.dart';
import 'package:localsend_app/widget/shareme/send_text_sheet.dart' show looksLikeLink;
import 'package:localsend_isolates/model/file_type.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// The "History" tab.
///
/// - Received entries (LocalSend's receive history, one per file) and sent entries (Shuttle's own, one per batch) are
///   merged and grouped by day.
/// - Files received in one batch become one row: new entries are merged by receive session ID (batchId); old entries have
///   none, so they are grouped by guessing "same sender, less than 2 minutes apart".
/// - Four filters: All / Photos & videos / Files / Text & links. Files are filtered by category first, then merged into rows.
/// - Tap a photo or file row → that batch's details (film strip); tap text or a link → the existing sheet; long-press →
///   delete the record (not the files).
/// - Failed sends state the reason in amber. "Retry" is left for later (it needs a way to find the original files again).
/// - Only the rows visible on screen are built (ListView.builder; building all at once, up to 500 rows with a thumbnail
///   each, made opening slow with a long history). The search next to the title matches file names, text and device
///   names, case-insensitively.
class SmHistoryPage extends StatefulWidget {
  const SmHistoryPage({super.key});

  @override
  State<SmHistoryPage> createState() => _SmHistoryPageState();
}

enum _Filter { all, media, files, texts }

class _SmHistoryPageState extends State<SmHistoryPage> with Refena {
  _Filter _filter = _Filter.all;

  /// The search box contents while it is open (null = search closed)
  String? _query;
  final _search = TextEditingController();

  /// Only show the keyboard when "Search" is tapped. No autofocus: the search box is the list's first item and gets rebuilt
  /// after scrolling away and back, and autofocus would pop the keyboard up again.
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _clearAll() async {
    final ok = await _confirm(context, title: t.shareme.history.clearAllTitle, body: t.shareme.history.clearAllBody);
    if (!ok) return;
    ref.redux(receiveHistoryProvider).dispatch(RemoveAllHistoryEntriesAction());
    ref.redux(sentHistoryProvider).dispatch(RemoveAllSentHistoryAction());
  }

  void _toggleSearch() {
    setState(() {
      if (_query == null) {
        _query = '';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      } else {
        _query = null;
        _search.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final received = context.watch(receiveHistoryProvider);
    final sent = context.watch(sentHistoryProvider);
    final historyOn = context.watch(settingsProvider.select((s) => s.saveToHistory));
    final mine = context.watch(favoritesProvider).map((f) => f.fingerprint).toSet();
    final hasAny = received.isNotEmpty || sent.isNotEmpty;
    final query = _query?.trim().toLowerCase() ?? '';
    final records = buildHistoryRecords(received, sent, _accepts(_filter)).where((r) => query.isEmpty || r.matches(query)).toList();

    // A flat list of day headers and record rows. ListView.builder only builds the items visible on screen.
    final items = <_Item>[];
    for (final day in _groupByDay(records)) {
      items.add(_Item.day(_dayLabel(context, day.first.time)));
      for (var i = 0; i < day.length; i++) {
        items.add(_Item.row(day[i], first: i == 0, last: i == day.length - 1));
      }
    }

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title row: large title + search + clear
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 12, 0),
          child: Row(
            children: [
              Text(t.shareme.history.title, style: ShareMeText.headline.copyWith(color: c.ink)),
              const Spacer(),
              if (hasAny)
                IconButton(
                  tooltip: t.shareme.history.search,
                  icon: Icon(_query == null ? LucideIcons.search : LucideIcons.x, color: c.ink2),
                  onPressed: _toggleSearch,
                ),
              if (hasAny)
                IconButton(
                  tooltip: t.shareme.history.clearAll,
                  icon: Icon(LucideIcons.trash2, color: c.ink2),
                  onPressed: _clearAll,
                ),
            ],
          ),
        ),
        if (_query != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: t.shareme.history.searchHint,
                prefixIcon: Icon(LucideIcons.search, size: 20, color: c.ink3),
              ),
            ),
          ),
        SizedBox(
          height: 34 + 24,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            children: [
              for (final f in _Filter.values) ...[
                _FilterChip(
                  label: switch (f) {
                    _Filter.all => t.shareme.history.all,
                    _Filter.media => t.shareme.history.media,
                    _Filter.files => t.shareme.history.files,
                    _Filter.texts => t.shareme.history.texts,
                  },
                  selected: _filter == f,
                  onTap: () => setState(() => _filter = f),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        if (!historyOn)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(t.shareme.history.off, style: ShareMeText.meta.copyWith(color: c.ink2)),
          ),
        if (!hasAny)
          const _Empty()
        else if (records.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
            child: Text(
              query.isNotEmpty ? t.shareme.history.searchEmpty : t.shareme.history.emptyFilter,
              style: ShareMeText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: 1 + items.length,
      itemBuilder: (context, index) {
        if (index == 0) return header;
        final item = items[index - 1];
        final record = item.record;
        if (record == null) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 16, 10),
            child: Text(item.dayLabel!, style: ShareMeText.section.copyWith(color: c.ink2)),
          );
        }
        // Rows of the same day form one card: the first row rounds the top corners, the last row the bottom ones
        final radius = BorderRadius.vertical(
          top: item.first ? const Radius.circular(ShareMeSize.radiusGroup) : Radius.zero,
          bottom: item.last ? const Radius.circular(ShareMeSize.radiusGroup) : Radius.zero,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: c.group,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                if (!item.first) Divider(height: 1, thickness: 1, indent: 78, color: c.line),
                HistoryRecordRow(record: record, isMine: mine.contains(record.fingerprint)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One item in the history list: a day header, or a row within a day.
class _Item {
  final String? dayLabel;
  final HistoryRecord? record;
  final bool first;
  final bool last;

  const _Item.day(String label) : dayLabel = label, record = null, first = false, last = false;

  const _Item.row(HistoryRecord r, {required this.first, required this.last}) : dayLabel = null, record = r;
}

// ───────────────────────── Data: merge both kinds of entries into "one row per batch" ─────────────────────────

/// One row on the "History" page.
class HistoryRecord {
  final String key;

  /// Local time
  final DateTime time;
  final bool outgoing;
  final String alias;
  final String? fingerprint;
  final List<FilmFrame> frames;
  final int bytes;

  /// Text / link
  final String? message;

  /// The original received entries (used for deletion)
  final List<ReceiveHistoryEntry> received;

  /// The original sent entry
  final SentHistoryEntry? sent;

  const HistoryRecord({
    required this.key,
    required this.time,
    required this.outgoing,
    required this.alias,
    required this.fingerprint,
    required this.frames,
    required this.bytes,
    required this.message,
    required this.received,
    required this.sent,
  });

  /// The whole batch was not delivered (declined, canceled, error)
  bool get failed => sent != null && sent!.result != SentHistoryResult.delivered && sent!.result != SentHistoryResult.partial;

  /// Partly delivered: the number of undelivered files
  int get undelivered => sent == null || sent!.result != SentHistoryResult.partial ? 0 : sent!.files.where((f) => !f.delivered).length;

  /// Every file's SHA-256 was verified (only known for received files)
  bool get verified => received.isNotEmpty && message == null && received.every((e) => e.checksumVerified == true);

  bool get allMedia => frames.isNotEmpty && frames.every((f) => _isMedia(f.fileType));

  /// Search: whether the file names, text or device name contain [query] (already lowercased)
  bool matches(String query) =>
      alias.toLowerCase().contains(query) ||
      (message?.toLowerCase().contains(query) ?? false) ||
      frames.any((f) => f.fileName.toLowerCase().contains(query));
  bool get noMedia => frames.every((f) => !_isMedia(f.fileType));
}

bool _isMedia(FileType type) => type == FileType.image || type == FileType.video;

typedef _Accepts = bool Function({required bool isMessage, required FileType type});

_Accepts _accepts(_Filter filter) {
  return ({required bool isMessage, required FileType type}) => switch (filter) {
    _Filter.all => true,
    _Filter.media => !isMessage && _isMedia(type),
    _Filter.files => !isMessage && !_isMedia(type),
    _Filter.texts => isMessage,
  };
}

/// Merges received entries (one per file) and sent entries (one per batch) into "one row per batch", newest first.
List<HistoryRecord> buildHistoryRecords(
  List<ReceiveHistoryEntry> received,
  List<SentHistoryEntry> sent,
  bool Function({required bool isMessage, required FileType type}) accepts,
) {
  final records = <HistoryRecord>[];

  // Received: filter first, then merge into batches
  final sorted = received.where((e) => accepts(isMessage: e.isMessage, type: e.fileType)).toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  final groups = <String, List<ReceiveHistoryEntry>>{};
  String? legacyKey;
  ReceiveHistoryEntry? legacyPrev;
  for (final e in sorted) {
    if (e.isMessage) {
      groups['m:${e.id}'] = [e];
      continue;
    }
    final batch = e.batchId;
    if (batch != null) {
      groups.putIfAbsent('b:$batch', () => []).add(e);
      continue;
    }
    // Old entries have no batchId: same sender and under 2 minutes from the previous entry = same batch (as "Just received" on the home page)
    final prev = legacyPrev;
    if (legacyKey != null && prev != null && prev.senderAlias == e.senderAlias && prev.timestamp.difference(e.timestamp).inMinutes < 2) {
      groups[legacyKey]!.add(e);
    } else {
      legacyKey = 'l:${e.id}';
      groups[legacyKey] = [e];
    }
    legacyPrev = e;
  }
  for (final MapEntry(key: key, value: list) in groups.entries) {
    final first = list.first;
    records.add(
      HistoryRecord(
        key: key,
        time: first.timestamp.toLocal(),
        outgoing: false,
        alias: first.senderAlias,
        fingerprint: first.senderFingerprint,
        frames: first.isMessage
            ? const []
            : [
                for (final e in list.reversed) // in the order received
                  FilmFrame(fileName: e.fileName, fileType: e.fileType, path: e.path, inGallery: e.savedToGallery),
              ],
        bytes: list.fold(0, (a, e) => a + e.fileSize),
        message: first.isMessage ? first.fileName : null,
        received: list,
        sent: null,
      ),
    );
  }

  // Sent: one per batch
  for (final s in sent) {
    final message = s.message;
    if (message != null) {
      if (!accepts(isMessage: true, type: FileType.text)) continue;
    }
    final files = message != null ? const <SentHistoryFile>[] : s.files.where((f) => accepts(isMessage: false, type: f.fileType)).toList();
    if (message == null && files.isEmpty) continue;
    records.add(
      HistoryRecord(
        key: 's:${s.id}',
        time: s.timestamp.toLocal(),
        outgoing: true,
        alias: s.targetAlias,
        fingerprint: s.targetFingerprint,
        frames: [
          for (final f in files) FilmFrame(fileName: f.fileName, fileType: f.fileType, path: f.path, assetId: f.assetId),
        ],
        bytes: files.fold(0, (a, f) => a + f.size),
        message: message,
        received: const [],
        sent: s,
      ),
    );
  }

  records.sort((a, b) => b.time.compareTo(a.time));
  return records;
}

List<List<HistoryRecord>> _groupByDay(List<HistoryRecord> records) {
  final days = <List<HistoryRecord>>[];
  for (final r in records) {
    if (days.isNotEmpty && DateUtils.isSameDay(days.last.first.time, r.time)) {
      days.last.add(r);
    } else {
      days.add([r]);
    }
  }
  return days;
}

String _dayLabel(BuildContext context, DateTime day) {
  final today = DateUtils.dateOnly(DateTime.now());
  final d = DateUtils.dateOnly(day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return t.shareme.history.today;
  if (diff == 1) return t.shareme.history.yesterday;
  final locale = Localizations.localeOf(context).toLanguageTag();
  try {
    return (d.year == today.year ? DateFormat.MMMEd(locale) : DateFormat.yMMMEd(locale)).format(d);
  } catch (_) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

String _hhmm(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// Today: time only; other days: date + time
String _whenLabel(BuildContext context, DateTime time) {
  final today = DateUtils.isSameDay(time, DateTime.now());
  return today ? _hhmm(time) : '${_dayLabel(context, time)} ${_hhmm(time)}';
}

String _failReason(SentHistoryEntry s) {
  return switch (s.result) {
    SentHistoryResult.declined => t.shareme.history.reasonDeclined,
    SentHistoryResult.canceledByReceiver => t.shareme.history.reasonCanceledByReceiver,
    SentHistoryResult.canceledBySender => t.shareme.history.reasonCanceledBySender,
    SentHistoryResult.recipientBusy => t.shareme.history.reasonBusy,
    SentHistoryResult.tooManyAttempts => t.shareme.history.reasonPin,
    SentHistoryResult.error => s.errorMessage ?? t.shareme.history.reasonError,
    SentHistoryResult.delivered || SentHistoryResult.partial => '',
  };
}

/// Title for a text: its first line; links drop the https:// prefix.
String _messageTitle(String message) {
  final s = message.trim();
  if (looksLikeLink(s)) return s.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  final firstLine = s.split('\n').first.trim();
  return firstLine.isEmpty ? s : firstLine;
}

String _filesTitle(HistoryRecord r) {
  final n = r.frames.length;
  if (n == 1) return r.frames.first.fileName;
  if (r.allMedia) return t.shareme.history.mediaCount(n: n);
  if (r.noMedia) return t.shareme.history.fileCount(n: n);
  return t.shareme.history.itemCount(n: n);
}

Future<bool> _confirm(BuildContext context, {required String title, required String body}) async {
  final c = context.sm;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.shareme.history.cancel)),
        // Delete uses amber, not red (red is reserved for the seal)
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: c.warn),
          child: Text(t.shareme.history.delete),
        ),
      ],
    ),
  );
  return result == true;
}

Future<void> _delete(BuildContext context, HistoryRecord r) async {
  final ok = await _confirm(context, title: t.shareme.history.deleteTitle, body: t.shareme.history.deleteBody);
  if (!ok || !context.mounted) return;
  final sentHistory = context.redux(sentHistoryProvider);
  final receivedHistory = context.redux(receiveHistoryProvider);
  final sent = r.sent;
  if (sent != null) {
    sentHistory.dispatch(RemoveSentHistoryAction(sent.id));
  }
  if (r.received.isNotEmpty) {
    receivedHistory.dispatch(RemoveHistoryEntriesAction(r.received.map((e) => e.id).toSet()));
  }
}

// ───────────────────────── Widgets ─────────────────────────

/// Filter chip: 34 high, radius 10, 1px `line` border; when selected, an ink background with onInk text.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.ink : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: selected ? BorderSide.none : BorderSide(color: c.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Text(label, style: ShareMeText.labelSm.copyWith(fontSize: 13.5, color: selected ? c.onInk : c.ink)),
          ),
        ),
      ),
    );
  }
}

/// History row: 48 preview | title and source | time. Also used by "Recent" on the desktop home page.
class HistoryRecordRow extends StatelessWidget {
  final HistoryRecord record;
  final bool isMine;

  const HistoryRecordRow({required this.record, required this.isMine, super.key});

  Future<void> _open(BuildContext context) async {
    final r = record;
    final message = r.message;
    if (message != null) {
      final isLink = looksLikeLink(message);
      final who = r.outgoing
          ? (isLink ? t.shareme.history.sentLink(name: r.alias) : t.shareme.history.sentText(name: r.alias))
          : (isLink ? t.shareme.history.receivedLink(name: r.alias) : t.shareme.history.receivedText(name: r.alias));
      await showHistoryMessageSheet(
        context,
        message: message,
        header: '$who · ${_whenLabel(context, r.time)}',
        sealFingerprint: isMine ? r.fingerprint : null,
      );
      return;
    }
    // A single received file (not in the gallery): open it directly
    if (!r.outgoing && r.received.length == 1 && !r.received.first.savedToGallery && r.received.first.path != null) {
      final e = r.received.first;
      await openFile(context, e.fileType, e.path!);
      return;
    }
    await context.push(() => SmHistoryBatchPage(record: r, isMine: isMine));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final r = record;
    final message = r.message;
    final failed = r.failed;
    final title = message != null ? _messageTitle(message) : _filesTitle(r);
    final isQuote = message != null && !looksLikeLink(message);

    final Widget subtitle;
    if (failed) {
      subtitle = Text(
        t.shareme.history.sendFailed(reason: _failReason(r.sent!)),
        style: ShareMeText.meta.copyWith(color: c.warn, fontSize: 12.5),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      final color = c.ink2;
      final meta = ShareMeText.meta.copyWith(color: color, fontSize: 12.5);
      subtitle = Row(
        children: [
          Icon(r.outgoing ? LucideIcons.arrowUpRight : LucideIcons.arrowDownLeft, size: 14, color: color),
          const SizedBox(width: 4),
          Text(r.outgoing ? t.shareme.history.to : t.shareme.history.from, style: meta),
          const SizedBox(width: 5),
          if (isMine && r.fingerprint != null) ...[
            DeviceAvatar(size: 16, mine: true, deviceType: knownDeviceType(r.fingerprint!)),
            const SizedBox(width: 5),
          ],
          // A long name truncates only the name; the size always shows in full (at 1.25x text size "124.1 MB" was cut to "124.1 …")
          Flexible(
            child: Text(
              isMine ? r.alias : '${r.alias}${t.shareme.history.unpaired}',
              style: meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (message == null && r.bytes > 0) ...[
            Text(' · ', style: meta),
            Text(formatSize(r.bytes), style: ShareMeText.data.copyWith(fontSize: 11.5, color: color), maxLines: 1, softWrap: false),
          ],
          if (r.undelivered > 0) ...[
            Text(' · ', style: meta),
            Flexible(
              child: Text(
                t.shareme.history.partFailed(n: r.undelivered),
                style: meta.copyWith(color: c.warn),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      );
    }

    return InkWell(
      onTap: () async => _open(context),
      onLongPress: () async => _delete(context, r),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              _Lead(record: r),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The time sits at the right end of the title row: it looks top-right as in the design, but the
                    // second row (direction, device, size) can use the full width, so large text doesn't squeeze the name to "Te…"
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: ShareMeText.body.copyWith(color: c.ink, fontWeight: isQuote ? FontWeight.w400 : FontWeight.w500, height: 21 / 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(_hhmm(r.time), style: ShareMeText.data.copyWith(fontSize: 11.5, color: c.ink2)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    subtitle,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Leading preview: two or more photos are stacked; a single one is a 48 thumbnail; text / link / file is a tonal square;
/// a failure is an amber square.
class _Lead extends StatelessWidget {
  final HistoryRecord record;

  const _Lead({required this.record});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final r = record;
    Widget box(Widget child, {Color? color}) => Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(color: color ?? c.tonal, borderRadius: BorderRadius.circular(ShareMeSize.radiusTile)),
      alignment: Alignment.center,
      child: child,
    );

    if (r.failed) {
      return box(Icon(LucideIcons.triangleAlert, size: 21, color: c.warn), color: c.warnContainer);
    }
    final message = r.message;
    if (message != null) {
      return box(Icon(looksLikeLink(message) ? LucideIcons.link : LucideIcons.type, size: 21, color: c.ink));
    }
    final media = r.frames.where((f) => _isMedia(f.fileType)).toList();
    if (media.length >= 2) {
      // Two stacked: the second is offset 8 down-right with a group-colored border, so it looks laid on top
      return SizedBox.square(
        dimension: 48,
        child: Stack(
          children: [
            FileThumb(frame: media[0], size: 40),
            Positioned(
              left: 8,
              top: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(ShareMeSize.radiusFrame + 2),
                  border: Border.all(color: c.group, width: 2),
                ),
                child: FileThumb(frame: media[1], size: 40),
              ),
            ),
          ],
        ),
      );
    }
    if (r.frames.isEmpty) return box(Icon(LucideIcons.file, size: 21, color: c.ink));
    return FileThumb(frame: media.isNotEmpty ? media.first : r.frames.first, size: 48, radius: ShareMeSize.radiusTile);
  }
}

/// Empty state: one sentence + one button, no illustration.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 96, 40, 0),
      child: Column(
        children: [
          Text(
            t.shareme.history.emptyTitle,
            style: ShareMeText.deviceName.copyWith(
              color: c.ink,
              fontSize: 20,
              fontVariations: const [FontVariation('wght', 800)],
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            t.shareme.history.emptyBody,
            style: ShareMeText.body.copyWith(color: c.ink2, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          // PCs have no gallery, so the button says "Send files" and opens the file picker (it used to say "Send photos & videos")
          if (checkPlatformIsDesktop())
            ElevatedButton.icon(
              onPressed: () async => pickAndSend(context, FilePickerOption.file),
              icon: const Icon(LucideIcons.file, size: 18),
              label: Text(t.shareme.history.emptyActionFiles),
            )
          else
            ElevatedButton.icon(
              onPressed: () async => pickAndSend(context, FilePickerOption.media),
              icon: const Icon(LucideIcons.image, size: 18),
              label: Text(t.shareme.history.emptyAction),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── Batch details ─────────────────────────

/// Opened from a photo / file row: title, source and time, film strip; received batches also show where they were saved.
class SmHistoryBatchPage extends StatelessWidget {
  final HistoryRecord record;
  final bool isMine;

  const SmHistoryBatchPage({required this.record, required this.isMine, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final r = record;
    final sent = r.sent;
    final when = _whenLabel(context, r.time);
    final inGallery = r.received.where((e) => e.savedToGallery).toList();
    final elsewhere = r.received.where((e) => !e.savedToGallery && e.path != null).toList();
    final notDelivered = sent == null ? const <SentHistoryFile>[] : sent.files.where((f) => !f.delivered).toList();

    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.failed
                      ? t.shareme.history.partFailed(n: r.frames.length)
                      : r.outgoing
                      ? t.shareme.history.sentTitle(n: r.frames.length)
                      : t.shareme.receive.receivedTitle(n: r.frames.length),
                  style: ShareMeText.display.copyWith(color: c.ink),
                ),
                const SizedBox(height: 6),
                Text(
                  r.outgoing ? t.shareme.history.toAt(name: r.alias, time: when) : t.shareme.history.fromAt(name: r.alias, time: when),
                  style: ShareMeText.meta.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
          FilmStrip(
            frames: r.frames,
            fromAlias: r.alias,
            totalBytes: r.bytes,
            // Seal = delivered and the peer is in "My devices"; no seal if the whole batch wasn't delivered
            sealFingerprint: isMine && !r.failed ? r.fingerprint : null,
            verified: r.verified,
            edgeLabel: r.outgoing ? t.shareme.history.edgeTo(name: r.alias) : null,
            showOriginal: !r.failed,
          ),
          if (sent != null && (r.failed || notDelivered.isNotEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.failed ? t.shareme.history.sendFailed(reason: _failReason(sent)) : t.shareme.history.partFailed(n: notDelivered.length),
                    style: ShareMeText.title.copyWith(color: c.warn),
                  ),
                  if (!r.failed)
                    for (final f in notDelivered)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('${f.fileName} · ${t.shareme.history.notDelivered}', style: ShareMeText.meta.copyWith(color: c.ink2)),
                      ),
                ],
              ),
            ),
          if (inGallery.isNotEmpty || elsewhere.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.shareme.receive.whereSaved, style: ShareMeText.section.copyWith(color: c.ink2)),
                  const SizedBox(height: 10),
                  Material(
                    color: c.group,
                    borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        if (inGallery.isNotEmpty)
                          ListTile(
                            leading: Icon(LucideIcons.images, color: c.ink2),
                            title: Text(t.shareme.receive.mediaItems(n: inGallery.length)),
                            subtitle: Text(t.shareme.receive.savedToGallery, style: ShareMeText.meta.copyWith(color: c.ok)),
                          ),
                        for (final e in elsewhere)
                          ListTile(
                            leading: Icon(LucideIcons.file, color: c.ink2),
                            title: Text(e.fileName, overflow: TextOverflow.ellipsis),
                            subtitle: Text(formatSize(e.fileSize), style: ShareMeText.data.copyWith(color: c.ink2)),
                            trailing: TextButton(
                              onPressed: () async => openFile(context, e.fileType, e.path!),
                              child: Text(t.shareme.receive.open),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (inGallery.isNotEmpty && checkPlatform([TargetPlatform.android])) ...[
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () async => android_channel.openGallery(),
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                      icon: const Icon(LucideIcons.images, size: 18),
                      label: Text(t.shareme.receive.viewInGallery),
                    ),
                  ],
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
            child: TextButton.icon(
              onPressed: () async {
                await _delete(context, r);
                if (context.mounted && !_stillExists(context, r)) Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(foregroundColor: c.warn),
              icon: const Icon(LucideIcons.trash2, size: 18),
              label: Text(t.shareme.history.deleteRecord),
            ),
          ),
        ],
      ),
    );
  }

  static bool _stillExists(BuildContext context, HistoryRecord r) {
    final sent = r.sent;
    if (sent != null) return context.read(sentHistoryProvider).any((e) => e.id == sent.id);
    final ids = r.received.map((e) => e.id).toSet();
    return context.read(receiveHistoryProvider).any((e) => ids.contains(e.id));
  }
}
