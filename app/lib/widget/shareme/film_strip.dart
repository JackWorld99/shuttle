import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/sm_card.dart';
import 'package:localsend_app/widget/shareme/stamp.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart'; // re-exports photo_manager (LocalSend uses it the same way)

/// One frame of the film strip.
class FilmFrame {
  final String fileName;
  final FileType fileType;
  final String? path;
  final bool isMessage;

  /// Saved to the system gallery: the temp file is already deleted and [path] is null, so the thumbnail is found by file name.
  final bool inGallery;

  /// Gallery asset ID of a sent photo / video on this device (history page); when set, the system thumbnail is used directly.
  final String? assetId;

  /// A thumbnail already in memory (some sent files)
  final Uint8List? bytes;

  const FilmFrame({
    required this.fileName,
    required this.fileType,
    required this.path,
    this.isMessage = false,
    this.inGallery = false,
    this.assetId,
    this.bytes,
  });
}

/// One batch of received / sent items (formerly a "film strip"; now a white card + rounded thumbnails + a caption + an "Original" chip).
///
/// Caption: `From {source} · {n} items · {size}` (sent records use [edgeLabel], e.g. "Sent to {peer}").
/// - "Original": the protocol transfers the original file bytes (confirmed by matching SHA-256); a check mark is added only when
///   [verified] is true (every file in the batch had its SHA-256 checked), so nothing is claimed that can't be guaranteed.
///   Hidden when the whole batch failed to send ([showOriginal] is false).
/// - When the sender is one of "My devices" ([sealFingerprint] is not null), a small avatar precedes the caption; unknown devices get none.
class FilmStrip extends StatelessWidget {
  final List<FilmFrame> frames;
  final String fromAlias;
  final int totalBytes;
  final String? sealFingerprint;
  final bool verified;

  /// Pops the "Original" chip on the done page; no animation in lists.
  final bool animateStamp;
  final VoidCallback? onTap;

  /// Start of the caption, "From {source}" by default; sent records use "Sent to {peer}".
  final String? edgeLabel;

  /// Whether to show "Original": hidden when the whole batch failed to send (nothing was transferred, so nothing is "original").
  final bool showOriginal;

  /// Thumbnail edge length: 100 on the done page; 56 in the small desktop popup at the bottom right
  final double frameSize;

  const FilmStrip({
    required this.frames,
    required this.fromAlias,
    required this.totalBytes,
    required this.sealFingerprint,
    required this.verified,
    this.animateStamp = false,
    this.onTap,
    this.edgeLabel,
    this.showOriginal = true,
    this.frameSize = 100,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final chip = showOriginal ? OriginalChip(verified: verified) : null;
    return SmCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: frameSize,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: frames.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => FileThumb(frame: frames[i], size: frameSize, radius: frameSize < 64 ? 10 : 14),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    if (sealFingerprint != null) ...[
                      DeviceAvatar(size: 22, mine: true, deviceType: knownDeviceType(sealFingerprint!)),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        [
                          edgeLabel ?? t.shareme.home.fromName(name: fromAlias),
                          t.shareme.home.edgeCount(n: frames.length),
                          formatSize(totalBytes),
                        ].join(' · '),
                        style: ShareMeText.meta.copyWith(color: c.ink2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (chip != null) ...[
                      const SizedBox(width: 8),
                      if (animateStamp) Stamp(delay: const Duration(milliseconds: 250), tilt: false, child: chip) else chip,
                    ],
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

/// "Original" chip: light green background, dark green text; a leading check mark when every file in the batch had its SHA-256 checked.
class OriginalChip extends StatelessWidget {
  final bool verified;

  const OriginalChip({required this.verified, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Container(
      padding: EdgeInsets.fromLTRB(verified ? 6 : 8, 2, 8, 2),
      decoration: BoxDecoration(color: c.okSoft, borderRadius: BorderRadius.circular(ShareMeSize.radiusPill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (verified) ...[
            Icon(LucideIcons.check, size: 13, color: c.okInk),
            const SizedBox(width: 3),
          ],
          Text(
            t.shareme.home.original,
            style: ShareMeText.labelSm.copyWith(color: c.okInk, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// A frame: photos show a thumbnail; videos a tonal tile + play icon; text a tonal tile + text icon; anything else its extension.
/// Also used as the leading preview of rows on the history page ([size] 40 / 48).
class FileThumb extends StatelessWidget {
  final FilmFrame frame;
  final double size;
  final double? radius;

  /// Width and height of a tile that isn't square ([size], its longer side, still decides the picture's resolution)
  final Size? fit;

  const FileThumb({required this.frame, this.size = 100, this.radius, this.fit, super.key});

  @override
  Widget build(BuildContext context) {
    final path = frame.path;
    final bytes = frame.bytes;
    // Sharp on dense screens without decoding the full picture; a little extra because wide pictures are cropped to the tile
    final pixels = (size * MediaQuery.devicePixelRatioOf(context) * 1.4).round().clamp(240, 1200);
    final iconSize = (size * 0.27).clamp(0.0, 44.0);
    final colors = smKindColors(
      dark: Theme.of(context).brightness == Brightness.dark,
      kind: frame.isMessage ? 'text' : frame.fileType.name,
    );
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colors.top, colors.bottom]),
        border: Border.all(color: colors.icon.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(radius ?? ShareMeSize.radiusFrame),
      ),
      alignment: Alignment.center,
      child: switch (frame.fileType) {
        _ when frame.isMessage => Icon(LucideIcons.type, color: colors.icon, size: iconSize),
        FileType.video => Icon(LucideIcons.play, color: colors.icon, size: iconSize),
        FileType.image => Icon(LucideIcons.image, color: colors.icon, size: iconSize),
        _ => Padding(
          padding: EdgeInsets.symmetric(horizontal: size * 0.08),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              fileExtension(frame.fileName),
              style: ShareMeText.data.copyWith(
                color: colors.icon,
                fontSize: (size * 0.22).clamp(11.0, 30.0),
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
            ),
          ),
        ),
      },
    );
    final canShowImage = frame.fileType == FileType.image && path != null && !path.startsWith('content://') && File(path).existsSync();
    final fromGallery = (frame.inGallery || frame.assetId != null) && (frame.fileType == FileType.image || frame.fileType == FileType.video);
    // With a gallery asset ID prefer the system thumbnail (fast, and videos get a picture too)
    final picture = canShowImage && frame.assetId == null
        ? Image.file(
            File(path),
            fit: BoxFit.cover,
            cacheWidth: pixels,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) => sync ? child : _FadeOver(fallback: fallback, ready: frame != null, child: child),
            errorBuilder: (_, _, _) => fallback,
          )
        : fromGallery
        ? _GalleryThumb(
            // A list reuses its elements: without the key, the picture loaded for one file stays for the next
            key: ValueKey('${frame.assetId ?? frame.fileName}@$pixels'),
            frame: frame,
            fallback: fallback,
            small: size < 60,
            pixels: pixels,
          )
        : bytes != null
        ? Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: pixels,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) => sync ? child : _FadeOver(fallback: fallback, ready: frame != null, child: child),
            errorBuilder: (_, _, _) => fallback,
          )
        : null;
    final box = SizedBox.fromSize(size: fit ?? Size.square(size), child: picture ?? fallback);
    // The type tile has round corners of its own, and clipping costs time in every frame
    if (picture == null || radius == 0) return box;
    return ClipRRect(borderRadius: BorderRadius.circular(radius ?? ShareMeSize.radiusFrame), child: box);
  }
}

/// The type tile until the picture is decoded, then the picture fades in over it (no blank flash). Once it covers the tile, the tile is
/// no longer drawn.
class _FadeOver extends StatefulWidget {
  final Widget fallback;
  final bool ready;
  final Widget child;

  const _FadeOver({required this.fallback, required this.ready, required this.child});

  @override
  State<_FadeOver> createState() => _FadeOverState();
}

class _FadeOverState extends State<_FadeOver> {
  late bool _covered = widget.ready;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!_covered) widget.fallback,
        AnimatedOpacity(
          // Keeps its place (and its state) when the tile below goes
          key: const ValueKey('picture'),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          opacity: widget.ready ? 1 : 0,
          onEnd: () {
            if (mounted && widget.ready) setState(() => _covered = true);
          },
          child: widget.child,
        ),
      ],
    );
  }
}

/// Finds a received photo / video in the system gallery by file name and shows the system-generated thumbnail.
///
/// LocalSend saves to the gallery via a temp file that is deleted once handed to Gal, so the record has no path (file_saver.dart),
/// and Gal returns no gallery asset ID either; the only option is a lookup by file name, taking the most recently added match.
/// Without gallery permission, or if nothing is found, the type icon is shown. Results are cached by file name.
class _GalleryThumb extends StatefulWidget {
  final FilmFrame frame;
  final Widget fallback;
  final bool small;
  final int pixels;

  const _GalleryThumb({required this.frame, required this.fallback, required this.pixels, this.small = false, super.key});

  @override
  State<_GalleryThumb> createState() => _GalleryThumbState();
}

class _GalleryThumbState extends State<_GalleryThumb> {
  static final _cache = <String, Uint8List?>{};
  Uint8List? _data;

  @override
  void initState() {
    super.initState();
    final key = '${widget.frame.assetId ?? widget.frame.fileName}@${widget.pixels}';
    if (_cache.containsKey(key)) {
      _data = _cache[key];
    } else {
      unawaited(_load(key));
    }
  }

  Future<void> _load(String key) async {
    final name = widget.frame.fileName;
    final assetId = widget.frame.assetId;
    Uint8List? data;
    try {
      final permission = await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption());
      if (permission.hasAccess && assetId != null) {
        final asset = await AssetEntity.fromId(assetId);
        data = await asset?.thumbnailDataWithSize(ThumbnailSize.square(widget.pixels));
      } else if (permission.hasAccess) {
        // The file name comes from the other device: quote it ourselves and double single quotes (standard SQL) to avoid an unintended query
        final quoted = "'${name.replaceAll("'", "''")}'";
        final filter = AdvancedCustomFilter()
            .addWhereCondition(ColumnWhereCondition(column: CustomColumns.android.displayName, operator: '=', value: quoted))
            .addOrderBy(column: CustomColumns.base.createDate, isAsc: false); // most recently added first
        final assets = await PhotoManager.getAssetListRange(start: 0, end: 1, filterOption: filter);
        if (assets.isNotEmpty) {
          data = await assets.first.thumbnailDataWithSize(ThumbnailSize.square(widget.pixels));
        }
      }
    } catch (_) {
      data = null;
    }
    _cache[key] = data;
    if (mounted) setState(() => _data = data);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return widget.fallback;
    final c = context.sm;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true),
        if (widget.frame.fileType == FileType.video)
          Positioned(
            left: 6,
            bottom: 6,
            child: Icon(LucideIcons.play, size: widget.small ? 12 : 16, color: c.onInk, shadows: const [Shadow(blurRadius: 4)]),
          ),
      ],
    );
  }
}

String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 || dot == name.length - 1 ? 'FILE' : name.substring(dot + 1).toUpperCase();
}
