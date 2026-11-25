import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/pin_dialog.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
import 'package:localsend_app/widget/shareme/setting_rows.dart';
import 'package:localsend_app/widget/shareme/sm_card.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:logging/logging.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

final _logger = Logger('WebSharePage');

enum _ServerState { initializing, running, error, stopping }

/// Shares a link with web browsers, in one of two modes:
/// - send: offers [WebSharePage.files] for download.
/// - receive: serves the upload page so browsers can upload files to this device.
///   Incoming requests are not listed here because they open the receive page
///   like any other incoming request.
class WebSharePage extends StatefulWidget {
  /// The files offered for download (share via link).
  /// `null` serves the upload page instead (receive via link).
  final List<CrossFile>? files;

  const WebSharePage({this.files});

  @override
  State<WebSharePage> createState() => _WebSharePageState();
}

class _WebSharePageState extends State<WebSharePage> with Refena {
  _ServerState _stateEnum = _ServerState.initializing;
  bool _encrypted = false;
  String? _initializedError;

  /// The address shown in the QR code (null = the first one)
  String? _ip;

  bool get _sendMode => widget.files != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init(encrypted: false);
    });
  }

  void _init({required bool encrypted}) async {
    final settings = ref.read(settingsProvider);
    setState(() {
      _stateEnum = _ServerState.initializing;
      _encrypted = encrypted;
      _initializedError = null;
    });
    await sleepAsync(500);
    try {
      final files = widget.files;

      // The pin of a previous web share session is kept;
      // receive mode initially uses the receive pin from settings.
      final previousWeb = ref.read(serverProvider)?.web;
      final webPin = previousWeb != null ? previousWeb.pin : (files == null ? settings.receivePin : null);

      if (files != null) {
        // The auto accept setting of a previous web download state is kept.
        await ref
            .notifier(serverProvider)
            .restartServerWithWebDownload(
              alias: settings.alias,
              port: settings.port,
              https: _encrypted,
              files: files,
              pin: webPin,
            );
      } else {
        await ref
            .notifier(serverProvider)
            .restartServer(
              alias: settings.alias,
              port: settings.port,
              https: _encrypted,
              web: WebShareUpload(pin: webPin),
            );
      }
      if (!mounted) return;
      setState(() {
        _stateEnum = _ServerState.running;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _stateEnum = _ServerState.error;
          _initializedError = e.toString();
        });
      }
    }
  }

  /// Web share uses unencrypted http by default, so we need to revert to the previous state.
  Future<void> _revertServerState() async {
    await ref.notifier(serverProvider).restartServerFromSettings();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, _) async {
        if (_stateEnum == _ServerState.initializing || _stateEnum == _ServerState.stopping) {
          return;
        }

        setState(() {
          _stateEnum = _ServerState.stopping;
        });
        await sleepAsync(250);
        try {
          // Also needed in the error state: the failed restart already stopped the old server.
          await _revertServerState();
        } catch (e) {
          _logger.warning('Failed to restore the server', e);
        }
        await sleepAsync(250);

        if (context.mounted) {
          context.pop();
        }
      },
      canPop: false,
      child: SmScaffold(
        appBar: AppBar(
          title: Text(_sendMode ? t.webSharePage.title : t.webReceivePage.title),
        ),
        body: switch (_stateEnum) {
          _ServerState.initializing || _ServerState.stopping => const Center(child: CircularProgressIndicator()),
          _ServerState.error => _Failed(
            error: _initializedError ?? '',
            onRetry: () => _init(encrypted: _encrypted),
          ),
          _ServerState.running => Builder(builder: _running),
        },
      ),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) context.showSnackBar(t.shareme.text.copied);
  }

  Future<void> _togglePin(String? pin) async {
    if (pin != null) {
      await ref.notifier(serverProvider).setWebPin(null);
      return;
    }
    final newPin = await showDialog<String>(
      context: context,
      builder: (_) => const PinDialog(obscureText: false, generateRandom: true),
    );
    if (newPin != null && newPin.isNotEmpty) await ref.notifier(serverProvider).setWebPin(newPin);
  }

  Widget _running(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.settings;
    final serverState = context.watch(serverProvider);
    final download = serverState?.webDownloadState;
    if (serverState == null || (_sendMode && download == null)) {
      // the server is restarting (e.g. because the pin changed)
      return const Center(child: CircularProgressIndicator());
    }
    final ips = context.watch(localIpProvider).localIps;
    final settings = context.watch(settingsProvider);
    final pin = serverState.web?.pin;
    final ip = ips.contains(_ip) ? _ip : ips.firstOrNull;
    String urlOf(String ip) => '${_encrypted ? 'https' : 'http'}://$ip:${serverState.port}';
    final autoAccept = download != null ? download.autoAccept : settings.receiveViaLinkAutoAccept;

    Future<void> setAutoAccept(bool v) async {
      if (download != null) {
        ref.notifier(serverProvider).setWebDownloadAutoAccept(v);
      } else {
        await ref.notifier(settingsProvider).setReceiveViaLinkAutoAccept(v);
      }
    }

    return SmPageList(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      maxWidth: 520,
      children: [
        if (ip == null)
          SmRowNote(s.noNetwork)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SmCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      // Always white, so cameras can read it in dark mode too
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
                        border: Border.all(color: c.line),
                      ),
                      child: SizedBox.square(
                        dimension: 190,
                        child: PrettyQrView.data(
                          data: pin == null ? urlOf(ip) : '${urlOf(ip)}/?pin=${Uri.encodeQueryComponent(pin)}',
                          errorCorrectLevel: QrErrorCorrectLevel.M,
                          decoration: const PrettyQrDecoration(shape: PrettyQrSmoothSymbol(roundFactor: 0, color: Color(0xFF1A1D1B))),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SelectableText(urlOf(ip), style: ShareMeText.deviceName.copyWith(color: c.ink)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pin == null ? s.linkHint : t.webSharePage.pinHint(pin: pin),
                      style: ShareMeText.meta.copyWith(color: c.ink2),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () async => _copy(urlOf(ip)),
                        icon: const Icon(LucideIcons.copy, size: 18),
                        label: Text(s.copyLink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // This device has several addresses: tap one to use it
        if (ips.length > 1) ...[
          SmRowTitle(s.otherAddresses),
          SmRowGroup(
            children: [
              for (final other in ips)
                SmRow(
                  title: urlOf(other),
                  trailing: Icon(
                    other == ip ? LucideIcons.circleCheck : LucideIcons.circle,
                    size: 20,
                    color: other == ip ? c.accent : c.ink3,
                  ),
                  onTap: () => setState(() => _ip = other),
                ),
            ],
          ),
        ],
        if (download != null) ...[
          SmRowTitle(t.webSharePage.requests),
          if (download.sessions.isEmpty)
            SmRowNote(t.webSharePage.noRequests)
          else
            SmRowGroup(
              children: [
                for (final session in download.sessions.values)
                  SmRow(
                    title: session.deviceInfo,
                    subtitle: session.ip,
                    trailing: session.pending
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: t.general.decline,
                                icon: Icon(LucideIcons.x, color: c.ink2),
                                onPressed: () => ref.notifier(serverProvider).declineWebDownloadRequest(session.sessionId),
                              ),
                              IconButton(
                                tooltip: t.general.accept,
                                icon: Icon(LucideIcons.check, color: c.ok),
                                onPressed: () => ref.notifier(serverProvider).acceptWebDownloadRequest(session.sessionId),
                              ),
                            ],
                          )
                        : Text(t.general.accepted, style: ShareMeText.meta.copyWith(color: c.ok)),
                  ),
              ],
            ),
        ],
        SmRowTitle(s.general),
        SmRowGroup(
          children: [
            SmRow(
              title: t.webSharePage.autoAccept,
              trailing: Switch(value: autoAccept, onChanged: setAutoAccept),
              onTap: () async => setAutoAccept(!autoAccept),
            ),
            SmRow(
              title: t.webSharePage.requirePin,
              trailing: Switch(value: pin != null, onChanged: (_) async => _togglePin(pin)),
              onTap: () async => _togglePin(pin),
            ),
            SmRow(
              title: t.webSharePage.encryption,
              subtitle: _encrypted ? t.webSharePage.encryptionHint : null,
              trailing: Switch(
                value: _encrypted,
                onChanged: (v) => _init(encrypted: v),
              ),
              onTap: () => _init(encrypted: !_encrypted),
            ),
          ],
        ),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _Failed({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.cloudOff, size: 44, color: c.warn),
            const SizedBox(height: 16),
            Text(
              t.webSharePage.error,
              style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText(
              error,
              style: ShareMeText.meta.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            ElevatedButton(onPressed: onRetry, child: Text(t.shareme.pair.tryAgainShort)),
          ],
        ),
      ),
    );
  }
}
