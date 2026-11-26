import 'dart:async';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/shareme_send_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart' show isInsecureTrustedDevice;
import 'package:localsend_app/provider/network/shareme_send_resume.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart' show QueueSendResult;
import 'package:localsend_app/provider/sent_history_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/message_preview.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/pin_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart' as rust_cancel;
import 'package:localsend_isolates/rust/api/http.dart' as rust_http;
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/util/file_hash.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uri_content/uri_content.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
final _logger = Logger('Send');

/// Shuttle: why a send from the queue stopped when the receiver asks for a PIN (the queue never asks for one in the background)
String get needsPinMessage => t.shareme.queue.needsPin;

/// This provider manages sending files to other devices.
///
/// In contrast to [serverProvider], this provider does not manage a server.
/// Instead, it only does HTTP requests to other servers.
/// Shuttle: how an attempt to continue after a lost connection went.
enum _ContinueOutcome {
  /// The receiver took the files: send them.
  accepted,

  /// Not reachable or busy yet: try again later.
  retry,

  /// Declined or canceled: give up (the files are marked failed).
  stop,
}

final sendProvider = NotifierProvider<SendNotifier, Map<String, SendSessionState>>((ref) {
  return SendNotifier();
});

class SendNotifier extends Notifier<Map<String, SendSessionState>> {
  SendNotifier();

  /// Cancel tokens of the running checksum calculations.
  /// Session ID -> Cancel token
  final _hashCancelTokens = <String, rust_cancel.RsCancellationToken>{};

  /// Cancel tokens of the running prepare-upload requests.
  /// Cancelling aborts the request, which tells the receiver that the sender
  /// is no longer waiting for a decision.
  /// Session ID -> Cancel token
  final _prepareUploadCancelTokens = <String, rust_cancel.RsCancellationToken>{};

  @override
  Map<String, SendSessionState> init() {
    return {};
  }

  /// The debug observer stringifies the state on every change,
  /// so large file maps must be summarized to keep transfers responsive in debug mode.
  @override
  String describeState(Map<String, SendSessionState> state) {
    if (state.values.every((session) => session.files.length <= 10)) {
      return state.toString();
    }
    return state.map((sessionId, session) {
      if (session.files.length <= 10) {
        return MapEntry(sessionId, session.toString());
      }
      return MapEntry(
        sessionId,
        session.copyWith(files: {}).toString().replaceFirst('files: {}', 'files: <${session.files.length} files>'),
      );
    }).toString();
  }

  /// Shuttle: sessions whose end result is kept for [takeResult] (the send queue reads how its sends ended, also when the session
  /// closed itself, e.g. a successful background send)
  final _tracked = <String>{};
  final _results = <String, QueueSendResult>{};

  /// Starts a session and returns its ID once it is over (or waits for the user on a page).
  /// If [background] is true, then the session closes itself on success and no pages will be open
  /// If [background] is false, then this method will open pages by itself and waits for user input to close the session.
  ///
  /// Shuttle: [sessionId] and [fileIds] let the send queue pick the IDs (to match files back to its entries); with [askPin] false a
  /// receiver that wants a PIN ends the send with [needsPinMessage] instead of opening the PIN dialog (no dialog popping up hours later).
  Future<String> startSession({
    required Device target,
    required List<CrossFile> files,
    required bool background,
    String? sessionId,
    List<String>? fileIds,
    bool askPin = true,
  }) async {
    final id = sessionId ?? _uuid.v4();
    await _startSession(sessionId: id, target: target, files: files, background: background, fileIds: fileIds, askPin: askPin);
    return id;
  }

  /// Keeps the end result of [sessionId] for [takeResult]. Call before [startSession].
  void trackResult(String sessionId) => _tracked.add(sessionId);

  /// The end result of a session passed to [trackResult]: its last state and file statuses, whether it is still open or was closed
  /// (by itself, a page or the user). Stops tracking it.
  QueueSendResult? takeResult(String sessionId) {
    _tracked.remove(sessionId);
    final closed = _results.remove(sessionId);
    final open = state[sessionId];
    if (open == null) return closed;
    final transfers = ref.read(fileTransferProvider);
    return QueueSendResult(
      state: open,
      statuses: {for (final id in open.files.keys) id: transfers.getStatus(sessionId: sessionId, fileId: id)},
    );
  }

  Future<void> _startSession({
    required String sessionId,
    required Device target,
    required List<CrossFile> files,
    required bool background,
    required List<String>? fileIds,
    required bool askPin,
  }) async {
    // Pinned to the device the user picked, so the request is not sent at all
    // if someone else answers on that address.
    final client = ref.read(httpProvider).pinnedTo(target.fingerprint);
    final createChecksums = ref.read(settingsProvider).createChecksums;

    // The ids are assigned upfront, so the checksums calculated below
    // can be mapped back to the corresponding file.
    final selectedFiles = [
      for (final (i, file) in files.indexed) (id: fileIds != null && i < fileIds.length ? fileIds[i] : _uuid.v4(), file: file),
    ];

    state = state.updateSession(
      sessionId: sessionId,
      state: (_) => SendSessionState(
        sessionId: sessionId,
        remoteSessionId: null,
        background: background,
        status: SessionStatus.waiting,
        target: target,
        files: {
          for (final (:id, :file) in selectedFiles)
            id: SendingFile(
              file: FileDto(
                id: id,
                fileName: file.name,
                size: file.size,
                fileType: file.fileType,
                hash: null,
                // calculated below
                // send simple message by embedding it into the preview
                preview: files.length == 1 && file.fileType == FileType.text ? createMessagePreview(file.bytes) : null,
                metadata: file.lastModified != null || file.lastAccessed != null
                    ? FileMetadata(
                        lastModified: file.lastModified,
                        lastAccessed: file.lastAccessed,
                      )
                    : null,
              ),
              token: null,
              thumbnail: file.thumbnail,
              asset: file.asset,
              path: file.path,
              bytes: file.bytes,
              errorMessage: null,
            ),
        },
        // Skipping the checksums marks all files as hashed, so the UI does not
        // show the checksum progress.
        hashedFileCount: createChecksums ? 0 : selectedFiles.length,
        startTime: null,
        endTime: null,
        sendingTasks: [],
        errorMessage: null,
      ),
    );

    ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,
          statuses: {for (final f in selectedFiles) f.id: FileStatus.queue},
        );

    if (!background) {
      // ignore: use_build_context_synchronously, unawaited_futures
      Routerino.context.push(
        // Shuttle: SmSendPage replaces LocalSend's SendPage (one page covers waiting → transfer → delivered)
        () => SmSendPage(sessionId: sessionId),
        transition: RouterinoTransition.fade(),
      );
    }

    // Shuttle security: sending to "my devices" requires an encrypted connection. The device list already filters this once
    // (RegisterDeviceAction); check again here: if the selected address is unencrypted anyway, don't send, and say why.
    final trusted = ref.read(favoritesProvider).map((f) => f.fingerprint).toSet();
    if (isInsecureTrustedDevice(device: target, httpsEnabled: ref.read(settingsProvider).https, trustedFingerprints: trusted)) {
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(status: SessionStatus.finishedWithErrors, errorMessage: t.shareme.send.insecure),
      );
      return;
    }

    // Calculate the checksums which are part of the request.
    // The files are read and hashed in Rust, several files at the same time
    // (Shuttle: one file after another kept a batch of 200 photos waiting for ~6 s).
    // The checksums are mapped back by file ID, so the request lists the files in the selected order.
    final hashes = <String, String>{};
    if (createChecksums) {
      final hashCancelToken = rust_cancel.createCancellationToken();
      _hashCancelTokens[sessionId] = hashCancelToken;
      try {
        await calculateFileHashes(
          files: [for (final (id: _, :file) in selectedFiles) (path: file.path, bytes: file.bytes)],
          cancelToken: hashCancelToken,
          concurrency: defaultHashConcurrency,
          // session has been canceled while calculating the checksums
          shouldStop: () => state[sessionId] == null,
          onProgress: (index, bytes) {
            if (state[sessionId] == null) {
              // session has been canceled while calculating the checksums
              return;
            }
            final (:id, :file) = selectedFiles[index];
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: id,
                  progress: file.size == 0 ? 1 : (bytes / file.size).clamp(0, 1),
                );
          },
          onFileDone: (index, hash, error) {
            if (state[sessionId] == null) {
              // session has been canceled while calculating the checksums.
              // Errors caused by the cancellation are not logged.
              return;
            }
            final (:id, :file) = selectedFiles[index];
            if (hash != null) {
              hashes[id] = hash;
            } else {
              // Sending the checksum is optional, so a file that cannot be read
              // here still gets a chance to be sent.
              _logger.warning('Could not calculate the checksum of ${file.name}', error);
            }

            // Also set for files whose hashing failed, so the progress bar stays
            // consistent with the files that are left.
            ref.notifier(fileTransferProvider).setProgress(sessionId: sessionId, fileId: id, progress: 1);
            state = state.updateSession(
              sessionId: sessionId,
              state: (s) => s?.copyWith(hashedFileCount: s.hashedFileCount + 1),
            );
          },
        );
      } finally {
        _hashCancelTokens.remove(sessionId);
      }
    }

    final hashedState = state[sessionId];
    if (hashedState == null) {
      // session has been canceled while calculating the checksums
      return;
    }

    final requestState = hashedState.copyWith(
      files: hashedState.files.map(
        (id, sendingFile) => MapEntry(id, sendingFile.copyWith(file: sendingFile.file.withHash(hashes[id]))),
      ),
    );
    state = state.updateSession(
      sessionId: sessionId,
      state: (_) => requestState,
    );

    final requestDto = rust_model.PrepareUploadRequestDto(
      info: _registerDto(),
      files: {
        for (final entry in requestState.files.entries) entry.key: entry.value.file.toRust(),
      },
      // Shuttle: interrupted files can be continued (resume). Receivers that don't know it ignore it.
      shuttleResume: const rust_model.ShuttleResumeRequest(v: 1),
    );

    rust_http.PrepareUploadResult? response;
    bool invalidPin;
    bool pinFirstAttempt = true;
    String? pin;
    final prepareUploadCancelToken = rust_cancel.createCancellationToken();
    _prepareUploadCancelTokens[sessionId] = prepareUploadCancelToken;
    try {
      do {
        invalidPin = false;
        try {
          response = await client.prepareUpload(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            payload: requestDto,
            // The peer is already verified during the TLS handshake by the
            // fingerprint the client is pinned to.
            publicKey: null,
            pin: pin,
            cancelToken: prepareUploadCancelToken,
          );
        } on rust_http.RsHttpClientError_StatusCode catch (e) {
          switch (e.status) {
            case 401:
              if (!askPin) {
                // Shuttle: a send from the queue runs unattended, so don't open the PIN dialog at some random later moment
                state = state.updateSession(
                  sessionId: sessionId,
                  state: (s) => s?.copyWith(status: SessionStatus.finishedWithErrors, errorMessage: needsPinMessage),
                );
                return;
              }
              invalidPin = true;

              // wait until animation is finished
              await sleepAsync(500);
              if (state[sessionId] == null) {
                // session has been canceled in the meantime
                return;
              }

              pin = await showDialog<String>(
                context: Routerino.context, // ignore: use_build_context_synchronously
                builder: (_) => PinDialog(
                  obscureText: true,
                  showInvalidPin: !pinFirstAttempt,
                ),
              );

              pinFirstAttempt = false;

              if (state[sessionId] == null) {
                // session has been canceled while the dialog was open
                return;
              }

              if (pin == null) {
                state = state.updateSession(
                  sessionId: sessionId,
                  state: (s) => s?.copyWith(
                    status: SessionStatus.canceledBySender,
                  ),
                );
                return;
              }
              break;
            case 403:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.declined,
                ),
              );
              return;
            case 409:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.recipientBusy,
                ),
              );
              return;
            case 429:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.tooManyAttempts,
                ),
              );
              return;
            default:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.finishedWithErrors,
                  errorMessage: e.humanErrorMessage,
                ),
              );
              return;
          }
        } catch (e) {
          state = state.updateSession(
            sessionId: sessionId,
            state: (s) => s?.copyWith(
              status: SessionStatus.finishedWithErrors,
              errorMessage: e.humanErrorMessage,
            ),
          );
          return;
        }
      } while (invalidPin);
    } finally {
      _prepareUploadCancelTokens.remove(sessionId);
    }

    if (response == null) {
      return;
    }

    if (state[sessionId] == null) {
      // The session has been canceled locally while the response was on its way,
      // so the session the receiver just created must be canceled as well.
      final remoteSessionId = response.response?.sessionId;
      if (remoteSessionId != null) {
        unawaited(_notifyReceiverCancel(target, remoteSessionId));
      }
      return;
    }

    final Map<String, String> fileMap;
    if (response.statusCode == 204) {
      // Nothing selected
      // Interpret this as "Read and close"
      fileMap = {};
    } else {
      try {
        fileMap = response.response!.files;
        final remoteSessionId = response.response!.sessionId;
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            remoteSessionId: remoteSessionId,
          ),
        );
        _recordResumeAnswer(sessionId, response.response!, pin: pin);
      } catch (e) {
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: SessionStatus.finishedWithErrors,
            errorMessage: e.humanErrorMessage,
          ),
        );
        return;
      }
    }

    if (fileMap.isEmpty) {
      // receiver has nothing selected
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          status: SessionStatus.finished,
        ),
      );

      final session = state[sessionId];
      if (session?.background == false) {
        // Pop back to the existing HomePage instead of pushing a new one:
        // a second HomePage attaches a second PageView to the shared PageController,
        // and removing routes without animation orphans a hero in flight.
        ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.transfer));
        ref.global.dispatch(NavigateAction.popUntilRoot());

        // Shuttle: text / links skip the progress page and go back home as soon as the receiver accepts, so tell the user it was sent.
        final onlyMessages = session!.files.values.every((f) => f.file.fileType == FileType.text && f.file.preview != null);
        if (onlyMessages) {
          // ignore: use_build_context_synchronously
          Routerino.context.showSnackBar(t.shareme.text.sentTo(name: session.target.alias));
        }
      }

      closeSession(sessionId);
      return;
    }

    final sendingFiles = {
      for (final file in requestState.files.values)
        file.file.id: fileMap.containsKey(file.file.id) ? file.copyWith(token: fileMap[file.file.id]) : file,
    };

    // Recreate the transfer state: the hash progress is no longer needed and must not be
    // mistaken for upload progress, which starts at zero for every file.
    final transferNotifier = ref.notifier(fileTransferProvider);
    transferNotifier.removeSession(sessionId);
    transferNotifier.setStatuses(
      sessionId: sessionId,
      statuses: {for (final file in sendingFiles.values) file.file.id: file.token != null ? FileStatus.queue : FileStatus.skipped},
    );
    // Shuttle: files the receiver has a part of start there (resume)
    _showResumedProgress(sessionId, sendingFiles.values);

    // Shuttle: not when the page for this session is already open (it covers this state too; replacing it would cut its animation off)
    if (state[sessionId]?.background == false && !SmSendPage.isOpen(sessionId)) {
      final background = ref.read(settingsProvider).sendMode == SendMode.multiple;

      unawaited(
        // ignore: use_build_context_synchronously
        Routerino.context
            .pushAndRemoveUntil(
              removeUntil: HomePage,
              transition: RouterinoTransition.fade(),
              // immediately is not possible: https://github.com/flutter/flutter/issues/121910
              // Shuttle: SmSendPage replaces LocalSend's ProgressPage (the receiving side still uses ProgressPage)
              builder: () => SmSendPage(
                closeSessionOnClose: !background,
                sessionId: sessionId,
              ),
            )
            .then((_) {
              if (background) {
                // The page was popped (e.g. backing out mid-transfer), so the session
                // runs in background again and is removed silently on success.
                setBackground(sessionId, true);
              }
            }),
      );
    }

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.sending,
        files: sendingFiles,
      ),
    );

    // Keep the process alive for the whole transfer. Started here, while the app is still in the
    // foreground, because Android 12+ rejects starting a foreground service from the background.
    TransferNotification.start(sessionId: sessionId, receiving: false);

    await _sendLoop(sessionId, sendingFiles);
  }

  /// Reports the total session progress to the foreground service notification,
  /// so that it stays up to date while the app is minimized.
  void _updateForegroundServiceProgress(String sessionId) {
    if (!TransferNotification.shouldUpdate) {
      // Checked before the sum below because progress events arrive several times per second per file.
      return;
    }

    final session = state[sessionId];
    if (session == null) {
      return;
    }

    final transferNotifier = ref.read(fileTransferProvider);
    int currentBytes = 0;
    int totalBytes = 0;
    for (final sendingFile in session.files.values) {
      if (transferNotifier.getStatus(sessionId: sessionId, fileId: sendingFile.file.id) == FileStatus.skipped) {
        // not accepted by the receiver
        continue;
      }
      final size = sendingFile.file.size;
      totalBytes += size;
      currentBytes += (transferNotifier.getProgress(sessionId: sessionId, fileId: sendingFile.file.id) * size).round();
    }

    TransferNotification.update(
      sessionId: sessionId,
      currentBytes: currentBytes,
      totalBytes: totalBytes,
      startTime: session.startTime,
      endTime: session.endTime,
    );
  }

  Future<void> _sendLoop(String sessionId, Map<String, SendingFile> files) async {
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(startTime: DateTime.now().millisecondsSinceEpoch),
    );

    final connectionLost = await _sendFiles(
      sessionId: sessionId,
      files: files.values.toList(),
    );
    if (connectionLost) {
      // Shuttle: continue the unfinished files where they stopped (resume)
      await _continueAfterLostConnection(sessionId);
    }

    _finish(sessionId: sessionId);
  }

  void _finish({required String sessionId}) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }

    // The transfer is over, the process no longer needs to be kept alive for it.
    TransferNotification.stop(sessionId);

    if (state[sessionId]!.status != SessionStatus.sending) {
      _logger.info('Transfer was canceled.');
    } else {
      final hasError = ref.read(fileTransferProvider).getStatuses(sessionId).any((status) => status == FileStatus.failed);
      if (!hasError && sessionState.background == true) {
        // close session because everything is fine and it is in background.
        // Shuttle: marked finished first, otherwise the history recorded it as "you canceled" (closed while still sending)
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(status: SessionStatus.finished, endTime: DateTime.now().millisecondsSinceEpoch),
        );
        closeSession(sessionId);
        _logger.info('Transfer finished and session removed.');
      } else {
        // keep session alive when there are errors or currently in foreground
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        );

        if (hasError) {
          _logger.info('Transfer finished with errors.');
        } else {
          _logger.info('Transfer finished successfully.');
        }
      }
    }
  }

  final uriContent = UriContent();

  /// Sends a single file. Currently only used to retry a failed file.
  Future<void> sendFile({
    required String sessionId,
    required SendingFile file,
    required bool isRetry,
  }) async {
    if (file.token == null) {
      return;
    }

    final status = state[sessionId]?.status;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (status == null || !allowedStates.contains(status)) {
      return;
    }

    if (isRetry) {
      _logger.info('Retrying ${file.file.fileName}');

      ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: file.file.id, status: FileStatus.queue);
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          status: SessionStatus.sending,
          files: s.files.map((key, value) {
            if (key == file.file.id) {
              return MapEntry(key, value.copyWith(errorMessage: null));
            }
            return MapEntry(key, value);
          }),
        ),
      );
    }

    final connectionLost = await _sendFiles(
      sessionId: sessionId,
      files: [file],
    );
    if (connectionLost) {
      // Shuttle: lost again while retrying: continue where it stopped (resume)
      await _continueAfterLostConnection(sessionId);
    }

    if (isRetry) {
      if (state[sessionId] != null && ref.read(fileTransferProvider).getStatuses(sessionId).isFinishedOrError) {
        _finish(sessionId: sessionId);
      }
    }
  }

  /// Sends the given [files] as one isolate task.
  /// The isolate iterates through the list and reports the state of each file
  /// via [HttpUploadEvent]s.
  /// Files without a token (i.e. not selected by the receiver) are skipped.
  ///
  /// Shuttle: returns whether the connection was lost while the receiver can continue the files (resume). The
  /// interrupted files and those not started are then left in the queue, to be continued in a new session.
  Future<bool> _sendFiles({
    required String sessionId,
    required List<SendingFile> files,
  }) async {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return false;
    }

    final resume = ref.read(sendResumeProvider).get(sessionId);
    final resumable = resume != null && resume.supported;
    final uploadFiles = [
      for (final file in files)
        if (file.token != null)
          HttpUploadFile(
            remoteFileToken: file.token!,
            fileId: file.file.id,
            filePath: file.path,
            fileBytes: file.bytes,
            fileSize: file.file.size,
            resumeOffset: resume?.offsets[file.file.id],
          ),
    ];

    if (uploadFiles.isEmpty) {
      return false;
    }

    var connectionLost = false;
    final taskResult = ref
        .redux(parentIsolateProvider)
        .dispatchTakeResult(
          IsolateHttpUploadFilesAction(
            remoteSessionId: sessionState.remoteSessionId,
            files: uploadFiles,
            device: sessionState.target,
            stopOnLostConnection: resumable,
          ),
        );

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        sendingTasks: [
          ...?s.sendingTasks,
          SendingTask(
            taskId: taskResult.taskId,
          ),
        ],
      ),
    );

    try {
      await for (final event in taskResult.events) {
        switch (event) {
          case HttpUploadFileStartedEvent():
            _logger.info('Sending ${state[sessionId]?.files[event.fileId]?.file.fileName}');
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.sending);
          case HttpUploadFileProgressEvent():
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  progress: event.progress,
                );
            _updateForegroundServiceProgress(sessionId);
          case HttpUploadFileFinishedEvent():
            // set progress to 100% when successfully finished
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  progress: 1,
                );
            _updateForegroundServiceProgress(sessionId);
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.finished);
            if (resumable) ref.notifier(sendResumeProvider).update(sessionId, (r) => r.interrupted.remove(event.fileId));
          case HttpUploadFileFailedEvent() when event.connectionLost && resumable:
            // Shuttle: not failed, it continues in a new session (resume)
            _logger.info('Connection lost while sending ${state[sessionId]?.files[event.fileId]?.file.fileName}: ${event.error}');
            connectionLost = true;
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.queue);
          case HttpUploadFileFailedEvent():
            _logger.warning('Error while sending file ${state[sessionId]?.files[event.fileId]?.file.fileName}: ${event.error}');
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.failed);
            state = state.updateSession(
              sessionId: sessionId,
              state: (s) => s?.withFileError(event.fileId, event.error),
            );
        }
      }
    } catch (e, st) {
      // the whole task failed, mark all files of this task that did not finish as failed
      _logger.warning('Error while sending files', e, st);
      final error = e.humanErrorMessage;
      final transferNotifier = ref.notifier(fileTransferProvider);
      final failedFileIds = uploadFiles
          .map((file) => file.fileId)
          .where((id) => const {FileStatus.queue, FileStatus.sending}.contains(transferNotifier.getStatus(sessionId: sessionId, fileId: id)))
          .toSet();
      transferNotifier.setStatuses(
        sessionId: sessionId,
        statuses: {for (final id in failedFileIds) id: FileStatus.failed},
      );
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          files: s.files.map((key, value) {
            if (failedFileIds.contains(key)) {
              return MapEntry(key, value.copyWith(errorMessage: error));
            }
            return MapEntry(key, value);
          }),
        ),
      );
    } finally {
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          sendingTasks: s.sendingTasks?.where((task) => task.taskId != taskResult.taskId).toList(),
        ),
      );
    }
    return connectionLost;
  }

  /// Shuttle: this device as the sender of a prepare-upload request.
  rust_model.RegisterDto _registerDto() {
    final originDevice = ref.read(deviceFullInfoProvider);
    return rust_model.RegisterDto(
      alias: originDevice.alias,
      version: originDevice.version,
      deviceModel: originDevice.deviceModel,
      deviceType: originDevice.deviceType.toRust(),
      token: originDevice.fingerprint,
      port: originDevice.port,
      protocol: originDevice.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
      hasWebInterface: originDevice.download,
    );
  }

  /// Shuttle: remembers whether the receiver can continue interrupted files and where each file starts (resume).
  void _recordResumeAnswer(String sessionId, rust_model.PrepareUploadResponseDto response, {required String? pin}) {
    final offsets = response.shuttleResume;
    ref.notifier(sendResumeProvider).update(sessionId, (r) {
      r.supported = offsets != null;
      r.offsets = {for (final entry in (offsets ?? const <String, BigInt>{}).entries) entry.key: entry.value.toInt()};
      r.pin = pin;
      r.continuedBytes = r.offsets.values.fold(0, (a, b) => a + b);
    });
    if (offsets != null && offsets.values.any((o) => o > BigInt.zero)) {
      _logger.info('The receiver continues files of $sessionId: $offsets');
    }
  }

  /// Shuttle: shows the files that continue where an earlier upload stopped at that point, not at 0.
  void _showResumedProgress(String sessionId, Iterable<SendingFile> files) {
    final resume = ref.read(sendResumeProvider).get(sessionId);
    if (resume == null) return;
    for (final f in files) {
      final offset = resume.offsets[f.file.id] ?? 0;
      if (offset > 0 && f.file.size > 0) {
        ref.notifier(fileTransferProvider).setProgress(sessionId: sessionId, fileId: f.file.id, progress: offset / f.file.size);
      }
    }
  }

  /// Shuttle: the accepted files of [session] that are not done yet (interrupted or not started).
  List<SendingFile> _unfinishedFiles(SendSessionState session) {
    final transfers = ref.read(fileTransferProvider);
    return [
      for (final f in session.files.values)
        if (f.token != null &&
            const {FileStatus.queue, FileStatus.sending}.contains(transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id)))
          f,
    ];
  }

  /// Shuttle: the bytes sent so far (for telling whether an attempt to continue got anywhere).
  int _sentBytes(String sessionId) {
    final session = state[sessionId];
    if (session == null) return 0;
    final transfers = ref.read(fileTransferProvider);
    return session.files.values.fold(0, (a, f) => a + (transfers.getProgress(sessionId: sessionId, fileId: f.file.id) * f.file.size).round());
  }

  void _failFiles(String sessionId, Iterable<SendingFile> files, String? error) {
    ref.notifier(fileTransferProvider).setStatuses(sessionId: sessionId, statuses: {for (final f in files) f.file.id: FileStatus.failed});
    if (error != null) {
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          files: {for (final e in s.files.entries) e.key: files.any((f) => f.file.id == e.key) ? e.value.copyWith(errorMessage: error) : e.value},
        ),
      );
    }
  }

  /// Shuttle: after the connection was lost, continues the unfinished files of [sessionId] in a new session at the
  /// receiver, which keeps what arrived (resume). Tries a few times ([continueDelays]); a new round starts whenever an
  /// attempt got further. When the attempts are over, "Continue sending" is offered. Returns when the files are done,
  /// the attempts are over, or the session was canceled.
  Future<void> _continueAfterLostConnection(String sessionId, {bool immediate = false}) async {
    var attempt = 0;
    var sentBefore = _sentBytes(sessionId);
    final resumeNotifier = ref.notifier(sendResumeProvider);
    while (true) {
      final session = state[sessionId];
      if (session == null || session.status != SessionStatus.sending) return;
      final unfinished = _unfinishedFiles(session);
      if (unfinished.isEmpty) {
        resumeNotifier.update(sessionId, (r) => r.reconnectAttempt = null);
        return;
      }
      if (attempt >= continueDelays.length) {
        _logger.info('Could not continue $sessionId in time, offering "Continue sending"');
        resumeNotifier.update(sessionId, (r) {
          r.reconnectAttempt = null;
          r.canContinue = true;
          r.interrupted.addAll(unfinished.map((f) => f.file.id));
        });
        _failFiles(sessionId, unfinished, null);
        return;
      }

      resumeNotifier.update(sessionId, (r) => r.reconnectAttempt = attempt + 1);
      await Future<void>.delayed(immediate && attempt == 0 ? Duration.zero : continueDelays[attempt]);
      attempt++;
      if (state[sessionId]?.status != SessionStatus.sending) return; // canceled meanwhile

      final outcome = await _prepareContinuation(sessionId, unfinished);
      if (outcome == _ContinueOutcome.retry) continue;
      resumeNotifier.update(sessionId, (r) => r.reconnectAttempt = null);
      if (outcome == _ContinueOutcome.stop) return;

      final accepted = state[sessionId];
      if (accepted == null) return;
      final connectionLost = await _sendFiles(
        sessionId: sessionId,
        files: [for (final f in unfinished) accepted.files[f.file.id]!],
      );
      if (!connectionLost) return;

      // Lost again: a new round of attempts, as long as this one got further
      final sentNow = _sentBytes(sessionId);
      if (sentNow > sentBefore) attempt = 0;
      sentBefore = sentNow;
    }
  }

  /// Shuttle: asks the receiver to continue [files] of [sessionId] in a new session, naming the old one so it can
  /// take over without asking its user again.
  Future<_ContinueOutcome> _prepareContinuation(String sessionId, List<SendingFile> files) async {
    final session = state[sessionId];
    if (session == null) return _ContinueOutcome.stop;
    final target = session.target;
    final pin = ref.read(sendResumeProvider).get(sessionId)?.pin;
    final requestDto = rust_model.PrepareUploadRequestDto(
      info: _registerDto(),
      files: {for (final f in files) f.file.id: f.file.toRust()},
      shuttleResume: rust_model.ShuttleResumeRequest(v: 1, resumeOf: session.remoteSessionId),
    );

    final cancelToken = rust_cancel.createCancellationToken();
    _prepareUploadCancelTokens[sessionId] = cancelToken;
    final rust_http.PrepareUploadResult result;
    try {
      result = await ref
          .read(httpProvider)
          .pinnedTo(target.fingerprint)
          .prepareUpload(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            payload: requestDto,
            publicKey: null,
            pin: pin,
            cancelToken: cancelToken,
          );
    } on rust_http.RsHttpClientError_StatusCode catch (e) {
      _logger.info('Continuing $sessionId: the receiver answered ${e.status}');
      if (e.status == 409 || e.status >= 500) {
        // busy (e.g. still with the old session) or a passing error
        return _ContinueOutcome.retry;
      }
      // declined, PIN, too many attempts
      _failFiles(sessionId, files, e.humanErrorMessage);
      return _ContinueOutcome.stop;
    } catch (e) {
      _logger.info('Continuing $sessionId: not reachable yet ($e)');
      return _ContinueOutcome.retry;
    } finally {
      _prepareUploadCancelTokens.remove(sessionId);
    }

    final response = result.response;
    if (state[sessionId] == null) {
      // canceled while waiting for the answer
      if (response != null) unawaited(_notifyReceiverCancel(target, response.sessionId));
      return _ContinueOutcome.stop;
    }
    if (response == null) {
      // 204: the receiver took none of them
      _failFiles(sessionId, files, null);
      return _ContinueOutcome.stop;
    }

    _logger.info('Continuing $sessionId as ${response.sessionId}');
    _recordResumeAnswer(sessionId, response, pin: pin);
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        remoteSessionId: response.sessionId,
        files: {
          for (final e in s.files.entries)
            e.key: response.files.containsKey(e.key) ? e.value.copyWith(token: response.files[e.key], errorMessage: null) : e.value,
        },
      ),
    );
    ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,
          statuses: {for (final f in files) f.file.id: response.files.containsKey(f.file.id) ? FileStatus.queue : FileStatus.failed},
        );
    _showResumedProgress(sessionId, files);
    return _ContinueOutcome.accepted;
  }

  /// Shuttle: "Continue sending": continues the files interrupted by a lost connection in a new session, where they
  /// stopped. [target] is the receiver at its current address (it may have changed networks meanwhile).
  Future<void> continueSession(String sessionId, {Device? target}) async {
    final session = state[sessionId];
    final resume = ref.read(sendResumeProvider).get(sessionId);
    if (session == null || resume == null || !resume.canContinue) return;
    final ids = {...resume.interrupted};
    _logger.info('Continuing ${ids.length} files of $sessionId');
    ref.notifier(sendResumeProvider).update(sessionId, (r) => r.canContinue = false);
    ref.notifier(fileTransferProvider).setStatuses(sessionId: sessionId, statuses: {for (final id in ids) id: FileStatus.queue});
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.sending,
        endTime: null,
        target: target ?? s.target,
        files: {for (final e in s.files.entries) e.key: ids.contains(e.key) ? e.value.copyWith(errorMessage: null) : e.value},
      ),
    );
    TransferNotification.start(sessionId: sessionId, receiving: false);
    await _continueAfterLostConnection(sessionId, immediate: true);
    _finish(sessionId: sessionId);
  }

  /// Closes the send-session and sends a cancel event to the receiver.
  void cancelSession(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    final remoteSessionId = sessionState.remoteSessionId;

    _cancelRunningRequests(sessionState);

    if (remoteSessionId == null) {
      closeSession(sessionId);
      return;
    }

    // notify the receiver
    unawaited(_notifyReceiverCancel(sessionState.target, remoteSessionId));

    // finally, close session locally
    closeSession(sessionId);
  }

  /// Tells [target] that its session [remoteSessionId] is canceled.
  /// Errors are only logged.
  Future<void> _notifyReceiverCancel(Device target, String remoteSessionId) async {
    try {
      await ref
          .read(httpProvider)
          .pinnedTo(target.fingerprint)
          .cancel(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            sessionId: remoteSessionId,
          );
    } catch (e) {
      _logger.warning('Error while canceling session', e);
    }
  }

  void cancelSessionByReceiver(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    TransferNotification.stop(sessionId);
    _cancelRunningRequests(sessionState);

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.canceledByReceiver,
        endTime: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _cancelRunningRequests(SendSessionState state) {
    _hashCancelTokens.remove(state.sessionId)?.cancel();
    _prepareUploadCancelTokens.remove(state.sessionId)?.cancel();

    for (final task in state.sendingTasks ?? <SendingTask>[]) {
      ref
          .redux(parentIsolateProvider)
          .dispatch(
            IsolateHttpUploadCancelAction(
              taskId: task.taskId,
            ),
          );
    }
  }

  /// Closes the session.
  /// Shuttle: [recordHistory] false leaves it out of the sent history (an attempt whose content stays in the send queue: the
  /// attempt that finally delivers it is recorded).
  void closeSession(String sessionId, {bool recordHistory = true}) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    TransferNotification.stop(sessionId);
    ref.notifier(sendResumeProvider).remove(sessionId); // Shuttle
    _hashCancelTokens.remove(sessionId)?.cancel();
    _prepareUploadCancelTokens.remove(sessionId)?.cancel();
    if (_tracked.contains(sessionId)) {
      final transfers = ref.read(fileTransferProvider);
      _results[sessionId] = QueueSendResult(
        state: sessionState,
        statuses: {for (final id in sessionState.files.keys) id: transfers.getStatus(sessionId: sessionId, fileId: id)},
      );
    }
    if (recordHistory) _recordSentHistory(sessionState); // Shuttle: must run before the session (and its file statuses) is removed
    state = state.removeSession(ref, sessionId);
    if (sessionState.status == SessionStatus.finished && ref.read(settingsProvider).sendMode == SendMode.single) {
      // clear selected files
      ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
    }
  }

  /// Shuttle: records a "sent" history entry when the session ends. LocalSend only records received items (upstream issue #1269).
  /// Only the file name, type, size and original location are stored; files are not copied.
  void _recordSentHistory(SendSessionState session) {
    try {
      final transfers = ref.read(fileTransferProvider);
      final values = session.files.values.toList();
      final message = values.length == 1 && values.first.file.fileType == FileType.text ? values.first.file.preview : null;
      final files = message != null
          ? <SentHistoryFile>[]
          : [
              for (final f in values)
                SentHistoryFile(
                  fileName: f.file.fileName,
                  fileType: f.file.fileType,
                  size: f.file.size,
                  path: f.path,
                  assetId: f.asset?.id,
                  delivered: transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.finished,
                ),
            ];
      final delivered = files.where((f) => f.delivered).length;
      final result = switch (session.status) {
        SessionStatus.finished when message != null || delivered == files.length => SentHistoryResult.delivered,
        SessionStatus.finished => delivered == 0 ? SentHistoryResult.declined : SentHistoryResult.partial, // receiver accepted only some / none
        SessionStatus.finishedWithErrors => delivered > 0 ? SentHistoryResult.partial : SentHistoryResult.error,
        SessionStatus.declined => SentHistoryResult.declined,
        SessionStatus.canceledByReceiver => SentHistoryResult.canceledByReceiver,
        SessionStatus.recipientBusy => SentHistoryResult.recipientBusy,
        SessionStatus.tooManyAttempts => SentHistoryResult.tooManyAttempts,
        // Closed while still waiting for the receiver / while sending = you canceled
        SessionStatus.waiting || SessionStatus.sending || SessionStatus.canceledBySender => SentHistoryResult.canceledBySender,
      };
      final ms = session.endTime ?? session.startTime ?? DateTime.now().millisecondsSinceEpoch;
      ref
          .redux(sentHistoryProvider)
          .dispatch(
            AddSentHistoryAction(
              SentHistoryEntry(
                id: session.sessionId,
                targetAlias: session.target.alias,
                targetFingerprint: session.target.fingerprint,
                timestamp: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
                files: files,
                message: message,
                result: result,
                errorMessage: session.errorMessage ?? values.map((f) => f.errorMessage).nonNulls.firstOrNull,
              ),
            ),
          );
    } catch (e, st) {
      _logger.warning('Could not record sent history', e, st);
    }
  }

  void clearAllSessions() {
    for (final sessionId in state.keys) {
      TransferNotification.stop(sessionId);
    }
    for (final cancelToken in _hashCancelTokens.values) {
      cancelToken.cancel();
    }
    _hashCancelTokens.clear();
    for (final cancelToken in _prepareUploadCancelTokens.values) {
      cancelToken.cancel();
    }
    _prepareUploadCancelTokens.clear();
    state = {};
    ref.notifier(fileTransferProvider).removeAllSessions();
  }

  void setBackground(String sessionId, bool background) {
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(background: background),
    );
  }
}

extension on Map<String, SendSessionState> {
  Map<String, SendSessionState> updateSession({
    required String sessionId,
    required SendSessionState? Function(SendSessionState? old) state,
  }) {
    final newState = state(this[sessionId]);
    if (newState == null) {
      // no change
      return this;
    }
    return {
      ...this,
      sessionId: newState,
    };
  }

  Map<String, SendSessionState> removeSession(Ref ref, String sessionId) {
    ref.notifier(fileTransferProvider).removeSession(sessionId);
    return {...this}..remove(sessionId);
  }
}

extension on SendSessionState {
  SendSessionState withFileError(String fileId, String? errorMessage) {
    return copyWith(
      files: {...files}
        ..update(
          fileId,
          (file) => file.copyWith(
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
