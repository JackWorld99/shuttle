import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/receive_page.dart' show ReceivePageVm;
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shuttle: the "incoming request" page. Only used for file requests; text and links are handled separately (snackbar or
/// bottom sheet, see ReceiveController).
///
/// It answers "who, what, and can it be trusted" first:
/// - "My devices": shows the device's seal. Only over an encrypted connection, where the sender's fingerprint comes from
///   the mTLS certificate and can't be forged, does it say the certificate fingerprint matches the one from when it was added;
///   without encryption it honestly says the identity can't be confirmed.
/// - Unknown device: no seal, only a dashed placeholder, plus an amber warning and the device fingerprint in monospace.
///
/// Data and actions fully reuse LocalSend's [ReceivePageVm] (accept / decline / close).
class SmReceivePage extends StatelessWidget {
  final ViewProvider<ReceivePageVm> vm;

  const SmReceivePage(this.vm, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final vm = context.watch(this.vm);
    final sender = vm.sender;
    final favorites = context.watch(favoritesProvider);
    final isMine = favorites.any((f) => f.fingerprint == sender.fingerprint);
    // Only verified devices in "My devices" are accepted directly; unverified ones are asked on this page too
    final verified = isVerifiedMine(favorites: favorites, paired: context.watch(pairedDevicesProvider), fingerprint: sender.fingerprint);
    final autoAccept = context.watch(settingsProvider.select((s) => s.quickSaveFromFavorites));
    final bytes = vm.files.fold<int>(0, (a, f) => a + f.size);

    void decline() {
      vm.onDecline();
      context.global.dispatch(NavigateAction.popUntil<WebSharePage>()); // as in LocalSend: back to WebSharePage if receiving via link, else home
    }

    void close() {
      vm.onClose();
      context.global.dispatch(NavigateAction.popUntil<WebSharePage>()); // as in LocalSend: back to WebSharePage if receiving via link, else home
    }

    final canceled = vm.status == SessionStatus.canceledBySender;

    return PopScope(
      // Back gesture = decline (same as LocalSend's ReceivePage)
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !canceled) vm.onDecline();
        if (didPop && canceled) vm.onClose();
      },
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            children: [
              Center(
                child: DeviceAvatar(deviceType: sender.deviceType, size: 64, mine: isMine, verified: verified, badgeRing: c.bg),
              ),
              const SizedBox(height: 18),
              Text(
                sender.alias,
                style: ShareMeText.display.copyWith(color: c.ink),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                t.shareme.receive.wantsToSend(n: vm.files.length, size: formatSize(bytes)),
                style: ShareMeText.body.copyWith(color: c.ink2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              if (isMine && sender.https && !verified)
                _TrustLine(icon: LucideIcons.shield, color: c.ink2, text: t.shareme.receive.mineUnchecked)
              else if (isMine)
                _TrustLine(
                  icon: sender.https ? LucideIcons.shieldCheck : LucideIcons.shieldAlert,
                  color: sender.https ? c.ok : c.warn,
                  text: sender.https ? t.shareme.receive.mineVerified : t.shareme.receive.mineUnencrypted,
                )
              else
                Text(
                  '${t.shareme.receive.fingerprint}  ${groupFingerprint(sender.fingerprint)}',
                  style: ShareMeText.data.copyWith(color: c.ink2),
                  textAlign: TextAlign.center,
                ),
              if (!isMine) ...[
                const SizedBox(height: 18),
                _Banner(title: t.shareme.receive.strangerTitle, body: t.shareme.receive.strangerBody),
              ],
              if (!sender.https) ...[
                const SizedBox(height: 10),
                _Banner(title: t.shareme.receive.unencrypted, body: null),
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  Text(t.shareme.receive.contents, style: ShareMeText.section.copyWith(color: c.ink2)),
                  const SizedBox(width: 8),
                  Text(t.shareme.receive.original, style: ShareMeText.meta.copyWith(color: c.ink3, fontSize: 12.5)),
                ],
              ),
              const SizedBox(height: 10),
              _Preview(files: vm.files),
              const SizedBox(height: 8),
              Text(_summary(vm.files), style: ShareMeText.meta.copyWith(color: c.ink2)),
              if (verified && !canceled) ...[
                const SizedBox(height: 14),
                Material(
                  color: c.group,
                  borderRadius: BorderRadius.circular(ShareMeSize.radiusButton),
                  child: SwitchListTile(
                    value: autoAccept,
                    onChanged: (v) async => context.notifier(settingsProvider).setQuickSaveFromFavorites(v),
                    title: Text(t.shareme.receive.autoAcceptVerified, style: ShareMeText.body.copyWith(color: c.ink, fontSize: 14)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ShareMeSize.radiusButton)),
                  ),
                ),
              ],
              const SizedBox(height: 26),
              if (canceled) ...[
                Text(
                  t.shareme.receive.canceledBySender,
                  style: ShareMeText.title.copyWith(color: c.warn),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                FilledButton(onPressed: close, child: Text(t.shareme.receive.close)),
              ] else
                // Two buttons side by side: the primary "Accept" takes 2/3 of the width, on the right
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: decline,
                        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                        child: Text(t.shareme.receive.decline),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(onPressed: vm.onAccept, child: Text(t.shareme.receive.accept)),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _summary(List<FileDto> files) {
    final photos = files.where((f) => f.fileType == FileType.image).length;
    final videos = files.where((f) => f.fileType == FileType.video).length;
    final others = files.length - photos - videos;
    return [
      if (photos > 0) t.shareme.receive.photos(n: photos),
      if (videos > 0) t.shareme.receive.videos(n: videos),
      if (others > 0) t.shareme.receive.files(n: others),
    ].join(' · ');
  }
}

class _TrustLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _TrustLine({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text, style: ShareMeText.meta.copyWith(color: color)),
        ),
      ],
    );
  }
}

/// Warning banner: warnContainer background, size-20 warning icon, and a bold lead phrase that states the problem.
class _Banner extends StatelessWidget {
  final String title;
  final String? body;

  const _Banner({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.warnContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.triangleAlert, size: 20, color: c.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (body != null) TextSpan(text: ' $body'),
                ],
              ),
              style: ShareMeText.meta.copyWith(color: c.ink, fontSize: 13.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview: at most 7 tiles, the 8th shows the remaining count (no thumbnails before accepting, so icons by file type).
class _Preview extends StatelessWidget {
  final List<FileDto> files;

  const _Preview({required this.files});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final shown = files.length > 8 ? files.take(7).toList() : files;
    final rest = files.length - shown.length;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final f in shown)
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: c.tonal, borderRadius: BorderRadius.circular(ShareMeSize.radiusFrame)),
            alignment: Alignment.center,
            child: switch (f.fileType) {
              FileType.image => Icon(LucideIcons.image, color: c.ink2, size: 24),
              FileType.video => Icon(LucideIcons.play, color: c.ink2, size: 24),
              _ => Text(fileExtension(f.fileName), style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 11)),
            },
          ),
        if (rest > 0)
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: c.tonalStrong, borderRadius: BorderRadius.circular(ShareMeSize.radiusFrame)),
            alignment: Alignment.center,
            child: Text('+$rest', style: ShareMeText.data.copyWith(color: c.ink, fontSize: 14)),
          ),
      ],
    );
  }
}
