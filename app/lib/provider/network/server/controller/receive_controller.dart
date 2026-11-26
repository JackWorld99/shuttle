import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/pages/shareme_receive_page.dart';
import 'package:localsend_app/pages/shareme_receive_progress_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart' show isLateQueuedMessage;
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/native/win_window.dart';
import 'package:localsend_app/util/shareme_file_safety.dart';
import 'package:localsend_app/util/shareme_resume.dart';
import 'package:localsend_app/util/shareme_sender_identity.dart';
import 'package:localsend_app/widget/shareme/message_sheet.dart';
import 'package:localsend_app/widget/shareme/quick_saved_notice.dart';
import 'package:localsend_app/widget/shareme/receive_popup.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/server.dart' show SessionEndReasonV2;
import 'package:localsend_isolates/util/rust.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('ReceiveController');

/// Shuttle: how long after its last activity an accepted request can be continued without asking again.
const _continuationWindow = Duration(minutes: 30);

/// Shuttle: a request the user (or quick save) accepted, remembered so that its continuation after a lost connection
/// is accepted the same way without asking again.
class _AcceptedRequest {
  final String sessionId;

  /// The certificate of the sender (continuations are bound to it).
  final String senderCert;

  /// The desired file name by content ([_contentKey]).
  final Map<String, String> names;

  DateTime lastActivity;

  _AcceptedRequest({required this.sessionId, required this.senderCert, required this.names, required this.lastActivity});
}

String _contentKey(String sha256, int size) => '${sha256.toLowerCase()}|$size';

/// Handles all server events for receiving files.
/// The HTTP requests themselves are served by the Rust server which emits
/// the events handled here.
class ReceiveController {
  final ServerUtils server;

  ReceiveController(this.server);

  /// Shuttle: the last accepted request that can be continued (resume extension).
  _AcceptedRequest? _lastAccepted;

  /// A device registered itself on this server.
  Future<void> onRegister(HttpServerRegisterEvent event) async {
    if (event.info.fingerprint == server.ref.read(securityProvider).certificateHash) {
      // "I talked to myself lol"
      return;
    }

    // Shuttle security: when the server doesn't verify client certificates (the link page is being served, or encryption is off),
    // the fingerprint in the registration is self-reported. Ignore anyone claiming to be one of "my devices" — otherwise they could
    // rename the favorite or redirect content meant for it to another address. Real "my devices" are found by our own (encrypted,
    // certificate-checked) scans.
    final serverState = server.getState();
    if (!serverVerifiesClients(https: serverState.https, webShareActive: serverState.web != null) &&
        server.ref.read(favoritesProvider).any((f) => f.fingerprint == event.info.fingerprint)) {
      server.ref
          .notifier(discoveryLoggerProvider)
          .addLog('[SECURITY] ignored "/register" from ${event.ip}: claims to be one of My devices without a certificate');
      return;
    }

    // Feed the device into the discovery store; it comes back (and is
    // registered) via the [StartDiscoveryListener] stream.
    server.ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryAddDeviceAction(device: event.info.toDevice(event.ip, withChannel: true)));
    server.ref.notifier(discoveryLoggerProvider).addLog('[DISCOVER/TCP] Received "/register" HTTP request: ${event.info.alias} (${event.ip})');
  }

  /// A sender requests to upload files.
  /// The Rust server already checked the PIN and enforces that only one
  /// session can be active at a time.
  Future<void> onPrepareUpload(HttpServerPrepareUploadEvent event) async {
    // Shuttle: continuing interrupted files is bound to the sender's certificate.
    server.ref
        .read(resumeStoreProvider)
        .registerSession(
          sessionId: event.sessionId,
          senderCert: event.resume != null ? event.certFingerprint : null,
          files: {for (final entry in event.files.entries) entry.key: entry.value.toDart()},
        );

    // Shuttle: the sender lost its connection and continues a request accepted a moment ago: accepted again without
    // asking, with the same names, and on the same page if it is still open.
    final continued = _continuationOf(event);
    if (continued != null && server.getStateOrNull()?.session?.sessionId == continued.sessionId) {
      await _continueOnSamePage(event, continued);
      return;
    }

    if (server.getStateOrNull()?.session != null) {
      // The Rust server is the authority on the single-session invariant:
      // a new request means the old session is over (e.g. finished but still
      // displayed, or aborted while waiting).
      closeSession();
    }

    final settings = server.ref.read(settingsProvider);
    final destinationDir = settings.destination ?? await getDefaultDestinationDirectory();
    final cacheDir = await getCacheDirectory();
    final sessionId = event.sessionId;
    final files = {
      for (final entry in event.files.entries) entry.key: entry.value.toDart(),
    };

    // The fingerprint of the sender's mTLS certificate cannot be spoofed, unlike the
    // self-reported fingerprint in the JSON payload.
    // Shuttle security: without a certificate (link page served, or encryption off), don't fall back to the self-reported
    // fingerprint — an impostor would be treated as one of "my devices" (auto-accepted, text auto-copied). Instead it gets a
    // prefix so it never matches "my devices".
    final senderFingerprint = verifiedSenderFingerprint(certFingerprint: event.certFingerprint, claimed: event.info.fingerprint);

    _logger.info('Session Id: $sessionId');
    _logger.info('Destination Directory: $destinationDir');

    server.setState(
      (oldState) => oldState?.copyWith(
        session: ReceiveSessionState(
          sessionId: sessionId,
          status: SessionStatus.waiting,
          sender: event.info.toDevice(event.ip, withChannel: false).copyWith(fingerprint: senderFingerprint),
          senderAlias: server.ref.read(favoritesProvider).firstWhereOrNull((e) => e.fingerprint == senderFingerprint)?.alias ?? event.info.alias,
          files: {
            for (final file in files.values)
              file.id: ReceivingFile(
                file: file,
                token: null,
                desiredName: null,
                path: null,
                savedToGallery: false,
                errorMessage: null,
              ),
          },
          startTime: null,
          endTime: null,
          destinationDirectory: destinationDir,
          cacheDirectory: cacheDir,
          saveToGallery: checkPlatformWithGallery() && settings.saveToGallery && files.values.every((f) => !f.fileName.contains('/')),
          createdDirectories: {},
        ),
      ),
    );

    server.ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,
          statuses: {for (final file in files.values) file.id: FileStatus.queue},
        );

    bool quickSave = settings.quickSave && server.getState().session?.isMessageRequest != true;
    final quickSaveFromFavorites = settings.quickSaveFromFavorites && server.getState().session?.isMessageRequest != true;
    // Shuttle: only verified "my devices" are accepted directly; devices added with just "Add" still ask first (see isVerifiedMine)
    if (quickSaveFromFavorites && isVerifiedMineDevice(server.ref, senderFingerprint)) {
      quickSave = true;
    }
    if (server.getState().webUpload && settings.receiveViaLinkAutoAccept && server.getState().session?.isMessageRequest != true) {
      // The upload page (receive via link) is being served and requests should be accepted automatically.
      quickSave = true;
    }
    if (continued != null) {
      // Shuttle: the continuation of an accepted request whose page is closed by now. Where its files continue is only
      // known once the interrupted uploads of the old session reported what they saved.
      quickSave = true;
      await server.ref.read(resumeStoreProvider).settled(continued.sessionId);
      if (server.getStateOrNull()?.session?.sessionId != sessionId) return;
    }

    if (quickSave) {
      // Shuttle desktop: while the main window is in the tray / minimized, progress and completion show in the small bottom-right popup
      if (await SmPopupWindow.shouldUse()) {
        await SmPopupWindow.open(null);
      } else {
        // Push before accepting: the permission request in [acceptFileRequest] may block for a while.
        openQuietly(
          // ignore: use_build_context_synchronously, discarded_futures
          () => Routerino.context.push(
            // Shuttle: receive progress uses Shuttle's own page (SmReceiveProgressPage)
            () => SmReceiveProgressPage(sessionId: sessionId),
            transition: RouterinoTransition.fade(),
          ),
        );
      }

      // accept all files
      await acceptFileRequest({
        for (final f in files.values) f.id: continued?.names[_contentKey(f.hash!, f.size)] ?? f.fileName,
      });
      return;
    }

    // Shuttle desktop: while the main window is in the tray / minimized, file requests use the small bottom-right popup instead
    // of bringing up the whole main window and stealing focus. Text and links work as before (main window + bottom sheet).
    if (server.getState().session?.message != null) await SmPopupWindow.makeWay(); // a text needs the normal window
    final usePopup = server.getState().session?.message == null && await SmPopupWindow.shouldUse();
    if (!usePopup &&
        checkPlatformHasTray() &&
        (await windowManager.isMinimized() || !(await windowManager.isVisible()) || !(await windowManager.isFocused()))) {
      await showFromTray();
    }

    final message = server.getState().session?.message;
    // Shuttle: the text sheet uses the sender as it was when the sheet opened. Text from "my devices" is answered and the session
    // closed right away (see below), after which session is null; without this copy the sheet couldn't tell the text came from
    // "my devices" and wouldn't auto-copy it.
    final messageSender = message == null ? null : server.getState().session?.sender;
    if (message != null) {
      // Message already received
      server.ref
          .redux(receiveHistoryProvider)
          .dispatch(
            AddHistoryEntryAction(
              entryId: const Uuid().v4(),
              fileName: message,
              fileType: FileType.text,
              path: null,
              savedToGallery: false,
              isMessage: true,
              fileSize: utf8.encode(message).length,
              senderAlias: server.getState().session!.senderAlias,
              timestamp: DateTime.now().toUtc(),
              senderFingerprint: senderFingerprint, // Shuttle
              batchId: sessionId, // Shuttle
            ),
          );
    }

    final receiveProvider = ViewProvider((ref) {
      // No select: comparing the selected session runs the dart_mappable deep equality
      // over the whole files map on every state change.
      final current = ref.watch(serverProvider)?.session;
      // Shuttle: only this request. A page of an earlier request may still be on the navigation stack when the next one comes in;
      // it must not show that one, and above all not answer it (closing the page declines).
      final session = current?.sessionId == sessionId ? current : null;
      bool own() => ref.read(serverProvider)?.session?.sessionId == sessionId;
      return ReceivePageVm(
        status: session?.status,
        sender: messageSender ?? session?.sender ?? Device.empty,
        showSenderInfo: true,
        files: session?.files.values.map((f) => f.file).toList() ?? [],
        message: message,
        onAccept: () async {
          if (!own()) return;
          if (message != null) {
            // accept nothing
            await ref.notifier(serverProvider).acceptFileRequest({});
            return;
          }

          final selectedFiles = ref.read(selectedReceivingFilesProvider);

          // Push before accepting: the permission request in [acceptFileRequest] may block for a while.
          unawaited(
            Routerino.context.pushAndRemoveUntil(
              // Shuttle: file requests use SmReceivePage (text requests returned early above and never get here)
              removeUntil: SmReceivePage,
              builder: () => SmReceiveProgressPage(sessionId: sessionId),
              transition: RouterinoTransition.fade(),
            ),
          );

          await ref.notifier(serverProvider).acceptFileRequest(selectedFiles);
        },
        onDecline: () {
          if (own()) ref.notifier(serverProvider).declineFileRequest();
        },
        onClose: () {
          if (own()) ref.notifier(serverProvider).closeSession();
        },
      );
    });

    server.ref.notifier(selectedReceivingFilesProvider).setFiles(files.values.toList());

    // ignore: use_build_context_synchronously, unawaited_futures
    if (message == null && usePopup) {
      await SmPopupWindow.open(receiveProvider);
    } else if (message == null) {
      Routerino.context.push(() => SmReceivePage(receiveProvider)); // ignore: use_build_context_synchronously, unawaited_futures
    } else if (isVerifiedMineDevice(server.ref, senderFingerprint)) {
      // Shuttle: text from verified "my devices" is copied to the clipboard automatically and answered with "received" at once,
      // with only a brief snackbar instead of a sheet covering the screen (unverified devices get the sheet as usual, no auto-copy).
      // "View" opens the full text; for a URL the button is "Open". The text is still saved to the history.
      // Read the sender name first: once "received" is answered the session is over and it would read as empty (the snackbar
      // once said "Copied, from " with no name).
      final alias = server.getStateOrNull()?.session?.senderAlias ?? '';
      // Shuttle: text that waited in the sender's send queue for a while isn't copied: it would replace whatever was copied in
      // the meantime. The sender puts the time it was queued into the "modified" field (isLateQueuedMessage); ordinary text has none.
      final late = isLateQueuedMessage(files.values.firstOrNull?.metadata?.lastModified, DateTime.now());
      if (!late) unawaited(Clipboard.setData(ClipboardData(text: message)));
      server.ref.read(receiveProvider).onAccept();
      showReceivedTextSnack(alias: alias, message: message, senderFingerprint: senderFingerprint, late: late);
    } else {
      // Shuttle: text and links are shown in a bottom sheet that is closed after reading.
      // Closing the sheet answers the sender with "seen" (accepting no files, like LocalSend's "Close" button);
      // if the sender already canceled, just close the session.
      final sheet = showSmSheet<void>(
        // ignore: use_build_context_synchronously
        Routerino.context,
        maxWidth: 480,
        scroll: false,
        builder: (_) => SmMessageSheet(receiveProvider),
      );
      unawaited(
        sheet.then((_) {
          // Only handle this sheet's own session. If it was already answered (from "my devices"), or a new transfer arrived while the
          // sheet was open, do nothing — otherwise the new transfer would be closed as "accept nothing"
          final current = server.getStateOrNull()?.session;
          if (current == null || current.sessionId != sessionId) return;
          final vm = server.ref.read(receiveProvider);
          if (current.status == SessionStatus.canceledBySender) {
            vm.onClose();
          } else {
            vm.onAccept();
          }
        }),
      );
    }
  }

  /// An accepted file started being uploaded.
  /// The server isolate receives and saves the file on its own
  /// ([HttpServerReceiveConfig] was sent with the accept decision);
  /// only the session state is updated here.
  void onFileUpload(HttpServerFileUploadEvent event) {
    // Shuttle: counted for every session, also one being replaced by its continuation
    server.ref.read(resumeStoreProvider).onUploadStarted(event.sessionId);
    ReceiveContinuation.touch(event.sessionId);

    final receiveState = server.getStateOrNull()?.session;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (receiveState == null || receiveState.sessionId != event.sessionId || !allowedStates.contains(receiveState.status)) {
      _logger.warning('Failing upload of file ${event.fileId}: no matching active session');
      // Fail the upload (and any further ones) by cancelling the session on the Rust side.
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: event.sessionId));
      return;
    }

    final fileId = event.fileId;
    final receivingFile = receiveState.files[fileId];
    if (receivingFile == null || receivingFile.desiredName == null) {
      _logger.warning('Unexpected fileId: $fileId');
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: event.sessionId));
      return;
    }

    // begin of actual file transfer
    server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.sending);
    if (receiveState.startTime == null || receiveState.status != SessionStatus.sending) {
      server.setState(
        (oldState) => oldState?.copyWith(
          session: receiveState.copyWith(
            startTime: receiveState.startTime ?? DateTime.now().millisecondsSinceEpoch,
            status: SessionStatus.sending, // in case it was finishedWithErrors and user retries a failed file
          ),
        ),
      );
    }
  }

  /// The receive progress of a file reported by the server isolate.
  void onFileUploadProgress(HttpServerFileUploadProgressEvent event) {
    final receiveState = server.getStateOrNull()?.session;
    if (receiveState == null || receiveState.sessionId != event.sessionId) {
      return;
    }

    // Shuttle: data is arriving (for the "connection seems lost" hint and the continuation window)
    ReceiveContinuation.touch(event.sessionId);
    final accepted = _lastAccepted;
    if (accepted != null && accepted.sessionId == event.sessionId) {
      accepted.lastActivity = DateTime.now();
    }

    server.ref
        .notifier(fileTransferProvider)
        .setProgress(
          sessionId: event.sessionId,
          fileId: event.fileId,
          progress: event.progress,
        );

    _updateForegroundServiceProgress(receiveState);
  }

  /// Reports the total session progress to the foreground service notification,
  /// so that it stays up to date while the app is minimized.
  void _updateForegroundServiceProgress(ReceiveSessionState session) {
    if (!TransferNotification.shouldUpdate) {
      // Checked before the sum below because progress events arrive several times per second per file.
      return;
    }

    final transferNotifier = server.ref.read(fileTransferProvider);
    int currentBytes = 0;
    int totalBytes = 0;
    for (final receivingFile in session.files.values) {
      if (receivingFile.desiredName == null) {
        // not accepted by the user
        continue;
      }
      final size = receivingFile.file.size;
      totalBytes += size;
      currentBytes += (transferNotifier.getProgress(sessionId: session.sessionId, fileId: receivingFile.file.id) * size).round();
    }

    TransferNotification.update(
      sessionId: session.sessionId,
      currentBytes: currentBytes,
      totalBytes: totalBytes,
      startTime: session.startTime,
      endTime: session.endTime,
    );
  }

  /// Shuttle: the saved part of a continuable upload, remembered for a later continuation.
  void onFilePartial(HttpServerFilePartialEvent event) {
    unawaited(server.ref.read(resumeStoreProvider).onPartial(event));
  }

  /// A file has been received completely (or failed) by the server isolate.
  Future<void> onFileUploadResult(HttpServerFileUploadResultEvent event) async {
    // Shuttle: also for a session that was replaced by its continuation, whose part must be known to continue it
    await server.ref.read(resumeStoreProvider).onResult(event);

    final receiveState = server.getStateOrNull()?.session;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (receiveState == null || receiveState.sessionId != event.sessionId || !allowedStates.contains(receiveState.status)) {
      return;
    }

    final fileId = event.fileId;
    final receivingFile = receiveState.files[fileId];
    if (receivingFile == null || receivingFile.desiredName == null) {
      _logger.warning('Unexpected fileId: $fileId');
      return;
    }

    final fileType = receivingFile.file.fileType;
    final filePath = event.path;
    final error = event.error;

    if (error == null) {
      // Shuttle: on the PC, files from unknown devices (including "Receive from a browser") get the Mark of the Web, see
      // shareme_file_safety.dart. Only verified "my devices" are exempt.
      final fromMyDevice = isVerifiedMineDevice(server.ref, receiveState.sender.fingerprint);
      if (filePath != null && !event.savedToGallery && !fromMyDevice) {
        await markFromInternet(filePath);
      }
      server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.finished);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session?.fileFinished(
            fileId: fileId,
            path: filePath,
            savedToGallery: event.savedToGallery,
            errorMessage: null,
          ),
        ),
      );

      // Track it in history
      server.ref
          .redux(receiveHistoryProvider)
          .dispatch(
            AddHistoryEntryAction(
              entryId: fileId,
              fileName: receivingFile.desiredName!,
              fileType: fileType,
              path: filePath,
              savedToGallery: event.savedToGallery,
              isMessage: false,
              fileSize: receivingFile.file.size,
              senderAlias: receiveState.senderAlias,
              timestamp: DateTime.now().toUtc(),
              // Shuttle: record the sender fingerprint and checksum result. Reaching this point means the file was received;
              // if the sender attached a hash and verification is on here, the Rust core already checked it (a mismatch fails
              // the file, so it never gets here)
              senderFingerprint: receiveState.sender.fingerprint,
              checksumVerified: server.ref.read(settingsProvider).verifyChecksums && receivingFile.file.hash != null,
              batchId: event.sessionId,
            ),
          );
    } else {
      server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.failed);
      // Shuttle: the part that arrived is kept for a continuation; say so instead of the technical error
      final partialSaved = event.partialSaved;
      final size = receivingFile.file.size;
      final message = partialSaved != null && size > 0 ? t.shareme.resume.receiveKept(percent: (partialSaved * 100 ~/ size).clamp(1, 99)) : error;
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session?.fileFinished(
            fileId: fileId,
            path: null,
            savedToGallery: false,
            errorMessage: message,
          ),
        ),
      );
    }

    server.ref
        .notifier(fileTransferProvider)
        .setProgress(
          sessionId: receiveState.sessionId,
          fileId: fileId,
          progress: 1,
        );

    final session = server.getStateOrNull()?.session;
    if (session == null) {
      return;
    }

    _updateForegroundServiceProgress(session);

    final statuses = server.ref.read(fileTransferProvider).getStatuses(session.sessionId);
    if (allowedStates.contains(session.status) && statuses.isFinishedOrError) {
      // The transfer is over, the process no longer needs to be kept alive for it.
      TransferNotification.stop(session.sessionId);

      final hasError = statuses.any((status) => status == FileStatus.failed);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session!.copyWith(
            status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      final settings = server.ref.read(settingsProvider);
      // Only auto-close fully successful sessions: a failed file may still be
      // retried by the sender (e.g. after a checksum mismatch), which requires
      // the session to stay open.
      bool quickSave = settings.quickSave && !hasError && server.getState().session?.isMessageRequest != true;
      final quickSaveFromFavorites = settings.quickSaveFromFavorites && !hasError && server.getState().session?.isMessageRequest != true;
      if (quickSaveFromFavorites && isVerifiedMineDevice(server.ref, session.sender.fingerprint)) {
        quickSave = true;
      }
      if (quickSave) {
        // Shuttle: while the bottom-right popup is open, hand it the final state before closing the session, so its "done" view
        // can list every file
        if (SmPopupWindow.active) {
          final finalSession = server.getStateOrNull()?.session;
          if (finalSession != null) {
            final transfers = server.ref.read(fileTransferProvider);
            SmPopupWindow.finalSnapshot = (
              finalSession,
              {for (final f in finalSession.files.values) f.file.id: transfers.getStatus(sessionId: finalSession.sessionId, fileId: f.file.id)},
            );
          }
        }
        // close the session **after** the response has been sent
        Future.delayed(Duration.zero, () {
          closeSession();
          _logger.info('Closing session');

          // Shuttle: while the bottom-right popup is open, it shows "done" and closes itself; leave the pages alone here
          if (SmPopupWindow.active) return;

          // ignore: use_build_context_synchronously, discarded_futures
          openQuietly(() => Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.transfer, appStart: false)));

          // Shuttle: instead of LocalSend's "Open file?" dialog, show a snackbar with one button (see quick_saved_notice.dart)
          if (filePath != null && filePath.isNotEmpty) {
            showQuickSavedNotice(
              senderAlias: session.senderAlias,
              count: statuses.where((s) => s == FileStatus.finished).length,
              filePath: filePath,
              fileType: fileType,
              savedToGallery: event.savedToGallery,
            );
          }
        });
      }
      _logger.info('Received all files.');
    }
  }

  /// An upload session ended on the Rust server.
  void onSessionEnd(HttpServerSessionEndEvent event) {
    final receiveSession = server.getStateOrNull()?.session;
    if (receiveSession == null || receiveSession.sessionId != event.sessionId) {
      return;
    }

    switch (event.reason) {
      case SessionEndReasonV2.finished:
        // Already handled when the last file finished.
        break;
      case SessionEndReasonV2.cancelled:
        _cancelBySender(server);
      case SessionEndReasonV2.replaced:
        // Shuttle: the sender lost its connection and continues in a new request, which follows right away
        break;
    }
  }

  /// The sender aborted the request while the user was still deciding.
  void onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent event) {
    final receiveSession = server.getStateOrNull()?.session;
    if (receiveSession == null || receiveSession.sessionId != event.sessionId || receiveSession.status != SessionStatus.waiting) {
      return;
    }

    _cancelBySender(server);
  }

  /// A remote device cancels a transfer this application is currently
  /// *sending* to it.
  void onCancelReceived(HttpServerCancelReceivedEvent event) {
    final sendSessions = server.ref.read(sendProvider);
    final selectedSession = sendSessions.values.firstWhereOrNull((s) => s.remoteSessionId == event.sessionId);
    if (selectedSession == null) {
      return;
    }

    if (selectedSession.target.ip != event.ip) {
      return;
    }

    if (selectedSession.status != SessionStatus.sending) {
      return;
    }

    server.ref
        .notifier(sendProvider)
        .cancelSessionByReceiver(
          selectedSession.sessionId,
        );
  }

  /// Another application instance requested the running application to show itself.
  /// The show token has already been checked by the Rust server.
  void onShow(HttpServerShowEvent event) {
    if (!checkPlatformIsDesktop()) {
      return;
    }

    // Shuttle: from the bottom-right popup to the full page, like a click on the tray icon
    // ignore: discarded_futures
    SmPopupWindow.expandFromTray().then((expanded) => expanded ? null : showFromTray()).catchError((e) {
      // don't wait for it
      _logger.severe('Failed to show from tray', e);
    });

    final args = event.args;
    if (args.isEmpty) {
      return;
    }

    // ignore: unawaited_futures, discarded_futures
    server.ref.redux(selectedSendingFilesProvider).dispatchAsyncTakeResult(LoadSelectionFromArgsAction(args)).then((filesAdded) {
      if (filesAdded) {
        server.ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.transfer));
      }
    });
  }

  /// Accepts the file request with the given [fileNameMap] (file id -> desired file name).
  Future<void> acceptFileRequest(Map<String, String> fileNameMap) async {
    final session = server.getStateOrNull()?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      return;
    }

    if (fileNameMap.isEmpty) {
      // nothing selected, the Rust server responds with 204 and creates no session
      // This usually happens for message transfers
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerPrepareUploadDecisionAction(config: _buildReceiveConfig(session, {}, null)));
      closeSession();
      return;
    }

    // Shuttle: remembered so that a continuation after a lost connection is accepted the same way
    _rememberAccepted(session, fileNameMap);

    unawaited(setTrayReminder(false)); // Shuttle: the request was handled, clear the tray reminder dot
    server.setState(
      (oldState) {
        final receiveState = oldState!.session!;
        return oldState.copyWith(
          session: receiveState.copyWith(
            status: SessionStatus.sending,
            files: Map.fromEntries(
              receiveState.files.values.map((entry) {
                final desiredName = fileNameMap[entry.file.id];
                return MapEntry(
                  entry.file.id,
                  ReceivingFile(
                    file: entry.file,
                    token: null,
                    desiredName: desiredName,
                    path: null,
                    savedToGallery: false,
                    errorMessage: null,
                  ),
                );
              }),
            ),
          ),
        );
      },
    );

    server.ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: session.sessionId,
          statuses: {
            for (final file in session.files.values) file.file.id: fileNameMap.containsKey(file.file.id) ? FileStatus.queue : FileStatus.skipped,
          },
        );

    // The storage permission only exists below Android 13 (scoped storage): newer versions
    // auto-deny the request, but the round trip through the system permission activity
    // still blocks the UI noticeably.
    final androidSdkInt = server.ref.read(deviceInfoProvider).androidSdkInt;
    if (checkPlatform([TargetPlatform.android]) && androidSdkInt != null && androidSdkInt < 33) {
      try {
        final result = await Permission.storage.request();
        _logger.info('storage permission: $result');
      } catch (e) {
        _logger.warning('Could not request storage permission', e);
      }
    }

    // Keep the process alive for the whole transfer. Started here because:
    // - the app is still in the foreground, and Android 12+ rejects starting a foreground service
    //   from the background,
    // - the service may ask for the notification permission, which Android cancels when it overlaps
    //   with the storage permission requests above.
    TransferNotification.start(sessionId: session.sessionId, receiving: true);

    // Shuttle: where each file starts, if parts of it arrived earlier (resume extension)
    final plan = await server.ref.read(resumeStoreProvider).plan(sessionId: session.sessionId, acceptedIds: fileNameMap.keys);
    _showResumedProgress(session.sessionId, plan);

    // From here on, the server isolate receives all accepted files on its own
    // and reports back via upload progress/result events.
    final updatedSession = server.getStateOrNull()?.session;
    if (updatedSession == null || updatedSession.sessionId != session.sessionId) {
      return;
    }
    server.ref
        .redux(parentIsolateProvider)
        .dispatch(IsolateHttpServerPrepareUploadDecisionAction(config: _buildReceiveConfig(updatedSession, fileNameMap, plan)));
  }

  HttpServerReceiveConfig _buildReceiveConfig(ReceiveSessionState session, Map<String, String> fileNameMap, ResumePlan? plan) {
    return HttpServerReceiveConfig(
      sessionId: session.sessionId,
      fileNameMap: fileNameMap,
      destinationDirectory: session.destinationDirectory,
      cacheDirectory: session.cacheDirectory,
      saveToGallery: session.saveToGallery,
      androidSdkInt: server.ref.read(deviceInfoProvider).androidSdkInt,
      resumeOffsets: plan?.offsets,
      partialFiles: plan?.partialFiles ?? const {},
    );
  }

  /// Shuttle: the continuation of [previous] if [event] is one: the same sender certificate continues the session it
  /// names, not long after it was last active, with files that were accepted in it.
  _AcceptedRequest? _continuationOf(HttpServerPrepareUploadEvent event) {
    final previous = _lastAccepted;
    final resumeOf = event.resume?.resumeOf;
    final cert = event.certFingerprint;
    if (previous == null || resumeOf == null || cert == null) return null;
    if (previous.sessionId != resumeOf || previous.senderCert != cert) return null;
    if (DateTime.now().difference(previous.lastActivity) > _continuationWindow) return null;
    for (final file in event.files.values) {
      final sha256 = file.sha256;
      if (sha256 == null || !previous.names.containsKey(_contentKey(sha256, file.size.toInt()))) return null;
    }
    return previous;
  }

  /// Shuttle: remembers an accepted request that can be continued.
  void _rememberAccepted(ReceiveSessionState session, Map<String, String> fileNameMap) {
    final cert = session.sender.fingerprint;
    if (!server.ref.read(resumeStoreProvider).isResumable(session.sessionId)) {
      return;
    }
    _lastAccepted = _AcceptedRequest(
      sessionId: session.sessionId,
      senderCert: cert,
      names: {
        for (final entry in fileNameMap.entries)
          if (session.files[entry.key]?.file.hash case final sha256?) _contentKey(sha256, session.files[entry.key]!.file.size): entry.value,
      },
      lastActivity: DateTime.now(),
    );
  }

  /// Shuttle: shows the files that continue where an earlier upload stopped at that point, not at 0.
  void _showResumedProgress(String sessionId, ResumePlan? plan) {
    final session = server.getStateOrNull()?.session;
    if (plan == null || session == null || session.sessionId != sessionId) return;
    for (final MapEntry(key: fileId, value: offset) in plan.offsets.entries) {
      final size = session.files[fileId]?.file.size ?? 0;
      if (offset > 0 && size > 0) {
        server.ref.notifier(fileTransferProvider).setProgress(sessionId: sessionId, fileId: fileId, progress: offset / size);
      }
    }
  }

  /// Shuttle: the sender continues [previous] (shown on the open page) after losing its connection. The page keeps
  /// showing the transfer: its files and their progress move over to the new session.
  Future<void> _continueOnSamePage(HttpServerPrepareUploadEvent event, _AcceptedRequest previous) async {
    final newId = event.sessionId;
    final oldId = previous.sessionId;
    _logger.info('Session $oldId continues as $newId (${event.files.length} files)');

    // What the interrupted uploads saved decides where the files continue.
    final resumeStore = server.ref.read(resumeStoreProvider);
    await resumeStore.settled(oldId);

    final current = server.getStateOrNull()?.session;
    if (current == null || current.sessionId != oldId) {
      // The page was closed meanwhile: decline, the sender asks again with "Continue sending"
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerPrepareUploadDecisionAction(config: null));
      return;
    }

    final offered = {for (final entry in event.files.entries) entry.key: entry.value.toDart()};
    final fileNameMap = {for (final f in offered.values) f.id: previous.names[_contentKey(f.hash!, f.size)]!};
    final transfers = server.ref.notifier(fileTransferProvider);
    final oldStatuses = {for (final f in current.files.values) f.file.id: transfers.getStatus(sessionId: oldId, fileId: f.file.id)};
    final oldProgress = {for (final f in current.files.values) f.file.id: transfers.getProgress(sessionId: oldId, fileId: f.file.id)};

    server.setState(
      (oldState) => oldState?.copyWith(
        session: current.copyWith(
          sessionId: newId,
          status: SessionStatus.sending,
          endTime: null,
          files: {
            ...current.files,
            for (final f in offered.values)
              f.id: ReceivingFile(
                file: f,
                token: null,
                desiredName: fileNameMap[f.id],
                path: null,
                savedToGallery: false,
                errorMessage: null,
              ),
          },
        ),
      ),
    );
    transfers.setStatuses(
      sessionId: newId,
      statuses: {
        for (final MapEntry(key: id, value: status) in oldStatuses.entries) id: offered.containsKey(id) ? FileStatus.queue : status,
      },
    );
    for (final MapEntry(key: id, value: progress) in oldProgress.entries) {
      if (!offered.containsKey(id)) transfers.setProgress(sessionId: newId, fileId: id, progress: progress);
    }
    transfers.removeSession(oldId);
    ReceiveContinuation.link(from: oldId, to: newId);
    // Registered before the old one goes, so the service keeping the process alive does not stop in between.
    TransferNotification.start(sessionId: newId, receiving: true);
    TransferNotification.stop(oldId);
    previous.lastActivity = DateTime.now();
    _lastAccepted = _AcceptedRequest(sessionId: newId, senderCert: previous.senderCert, names: previous.names, lastActivity: DateTime.now());

    final plan = await resumeStore.plan(sessionId: newId, acceptedIds: fileNameMap.keys);
    _showResumedProgress(newId, plan);
    final session = server.getStateOrNull()?.session;
    if (session == null || session.sessionId != newId) {
      return;
    }
    server.ref
        .redux(parentIsolateProvider)
        .dispatch(IsolateHttpServerPrepareUploadDecisionAction(config: _buildReceiveConfig(session, fileNameMap, plan)));
  }

  void declineFileRequest() {
    final session = server.getStateOrNull()?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      return;
    }

    server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerPrepareUploadDecisionAction(config: null));
    closeSession();
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory) {
    server.setState(
      (oldState) => oldState?.copyWith(
        session: oldState.session?.copyWith(
          destinationDirectory: destinationDirectory.replaceAll('\\', '/'),
        ),
      ),
    );
  }

  /// Updates the "saveToGallery" setting for the current session.
  void setSessionSaveToGallery(bool saveToGallery) {
    server.setState(
      (oldState) => oldState?.copyWith(
        session: oldState.session?.copyWith(
          saveToGallery: saveToGallery,
        ),
      ),
    );
  }

  /// In addition to [closeSession], this method also
  /// - cancels the session on the Rust server so that further uploads fail
  /// - notifies the sender that the session has been canceled
  void cancelSession() async {
    final session = server.getStateOrNull()?.session;
    if (session == null) {
      // the server is not running
      return;
    }

    // fail further uploads
    server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: session.sessionId));

    // Shuttle: canceling is not an interruption, the parts received so far go
    unawaited(server.ref.read(resumeStoreProvider).discardSession(session.sessionId));
    if (_lastAccepted?.sessionId == session.sessionId) _lastAccepted = null;

    // notify sender
    final target = session.sender;
    try {
      server.ref
          .read(httpProvider)
          .pinnedTo(target.fingerprint)
          // ignore: use_build_context_synchronously, unawaited_futures
          .cancel(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            sessionId: session.sessionId,
          );
    } catch (e) {
      _logger.warning('Failed to notify sender', e);
    }

    closeSession();
  }

  void closeSession() {
    final sessionId = server.getStateOrNull()?.session?.sessionId;
    if (sessionId == null) {
      return;
    }

    TransferNotification.stop(sessionId);
    unawaited(setTrayReminder(false)); // Shuttle: the request is over (declined, canceled, finished), clear the tray reminder dot

    server.setState(
      (oldState) => oldState?.copyWith(
        session: null,
      ),
    );
    server.ref.notifier(fileTransferProvider).removeSession(sessionId);
  }
}

void _cancelBySender(ServerUtils server) {
  final receiveSession = server.getStateOrNull()?.session;
  if (receiveSession == null) {
    return;
  }

  TransferNotification.stop(receiveSession.sessionId);
  unawaited(setTrayReminder(false)); // Shuttle: the sender canceled, nothing left for you to decide
  // Shuttle: canceling is not an interruption, the parts received so far go
  unawaited(server.ref.read(resumeStoreProvider).discardSession(receiveSession.sessionId));

  if (receiveSession.status == SessionStatus.waiting) {
    // received cancel during accept/decline
    // pop just in case if user is in [ReceiveOptionsPage]
    // Shuttle: routerino's popUntil(Type) pops all the way down when the target page isn't found (there is no request page with
    // quick save), so use a predicate with an isFirst fallback that matches every page that shows a request. (Without the popup in
    // it, the home page was left in the small window in the corner.)
    const requestPages = {'SmReceivePage', 'SmReceivePopupPage', 'ReceivePage'};
    Navigator.of(Routerino.context).popUntil((route) => requestPages.contains(route.settings.name) || route.isFirst);
  }

  server.setState(
    (oldState) => oldState?.copyWith(
      session: oldState.session?.copyWith(
        status: SessionStatus.canceledBySender,
        endTime: DateTime.now().millisecondsSinceEpoch,
      ),
    ),
  );
}

extension on ReceiveSessionState {
  ReceiveSessionState fileFinished({
    required String fileId,
    required String? path,
    required bool savedToGallery,
    required String? errorMessage,
  }) {
    return copyWith(
      files: {...files}
        ..update(
          fileId,
          (file) => file.copyWith(
            path: path,
            savedToGallery: savedToGallery,
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
