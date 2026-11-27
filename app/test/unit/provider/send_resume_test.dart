// Shuttle: continuing interrupted transfers (resume), sending side. A lost connection does not fail the files: the
// sender continues them in a new session, naming the old one, at the offsets the receiver answers with.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/settings_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/shareme_send_resume.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart' show QueueStep, classifyQueueResult;
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' show PrepareUploadRequestDto, PrepareUploadResponseDto, ProtocolType;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

class _SyncState extends Fake implements SyncState {}

class _Settings extends Fake implements SettingsState {
  @override
  bool get createChecksums => false;

  @override
  bool get https => true;

  // A send that went out completely is marked finished before its session closes (send queue), and closing a finished
  // session reads the send mode
  @override
  SendMode get sendMode => SendMode.multiple;
}

class _TestSettingsService extends SettingsService {
  _TestSettingsService(super.persistence);

  @override
  SettingsState init() => _Settings();
}

class _CancellationToken extends Fake implements RsCancellationToken {
  @override
  void cancel() {}
}

class _RustLibApi extends Fake implements RustLibApi {
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() => _CancellationToken();
}

/// A receiver whose answers to prepare-upload requests are scripted by the test.
class _Receiver extends Fake implements RsHttpClient {
  final List<FutureOr<PrepareUploadResult> Function(PrepareUploadRequestDto payload)> answers;
  final requests = <PrepareUploadRequestDto>[];

  _Receiver(this.answers);

  @override
  Future<PrepareUploadResult> prepareUpload({
    required ProtocolType protocol,
    required String ip,
    required int port,
    required PrepareUploadRequestDto payload,
    String? publicKey,
    String? pin,
    required RsCancellationToken cancelToken,
  }) async {
    requests.add(payload);
    if (requests.length > answers.length) throw StateError('unexpected prepare-upload #${requests.length}');
    return answers[requests.length - 1](payload);
  }

  @override
  Future<void> cancel({required ProtocolType protocol, required String ip, required int port, required String sessionId}) async {}
}

class _HttpClientCollection extends Fake implements HttpClientCollection {
  final RsHttpClient client;

  _HttpClientCollection(this.client);

  @override
  RsHttpClient pinnedTo(String fingerprint, {int? timeoutMs}) => client;
}

PrepareUploadResult _accepted(String sessionId, String fileId, String token, int offset) => PrepareUploadResult(
  statusCode: 200,
  response: PrepareUploadResponseDto(sessionId: sessionId, files: {fileId: token}, shuttleResume: {fileId: BigInt.from(offset)}),
);

void main() {
  late List<List<HttpUploadEvent> Function()> uploadScripts;
  late RefenaHistoryObserver observer;

  setUpAll(() {
    RustLib.initMock(api: _RustLibApi());
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '${h}h ${m}m',
      ),
    );
    // No foreground service (Android only) in this test
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() {
    continueDelays = const [Duration.zero, Duration.zero, Duration.zero];
  });

  tearDown(() {
    continueDelays = defaultContinueDelays;
  });

  RefenaContainer container(_Receiver receiver) {
    var task = 0;
    observer = RefenaHistoryObserver.only(actionDispatched: true);
    return RefenaContainer(
      observers: [observer],
      overrides: [
        persistenceProvider.overrideWithValue(MockPersistenceService()),
        settingsProvider.overrideWithNotifier((ref) => _TestSettingsService(MockPersistenceService())),
        httpProvider.overrideWithBuilder((_) => _HttpClientCollection(receiver)),
        deviceFullInfoProvider.overrideWithBuilder((_) => _createDevice(fingerprint: 'self')),
        parentIsolateProvider.overrideWithReducer(
          notifier: (_) => IsolateController(initialState: ParentIsolateState.initial(_SyncState())),
          reducer: {
            IsolateHttpUploadFilesAction: (state) {
              final events = uploadScripts[task]();
              task++;
              return (state, IsolateHttpUploadActionResult(taskId: task, events: Stream.fromIterable(events)));
            },
          },
        ),
      ],
    );
  }

  List<IsolateHttpUploadFilesAction> uploads() => observer.dispatchedActions.whereType<IsolateHttpUploadFilesAction>().toList();

  Future<void> send(RefenaContainer ref) => ref
      .notifier(sendProvider)
      .startSession(
        target: _createDevice(fingerprint: 'target'),
        files: [
          const CrossFile(
            name: 'video.mp4',
            fileType: FileType.video,
            size: 1000,
            thumbnail: null,
            asset: null,
            path: null,
            bytes: [1, 2, 3],
            lastModified: null,
            lastAccessed: null,
          ),
        ],
        // In the background, so no page opens; a background session closes itself once everything is sent.
        background: true,
      );

  test('a lost connection continues the file in a new session at the offset the receiver names', () async {
    late String fileId;
    late RefenaContainer ref;
    var progressAtContinuation = 0.0;
    final receiver = _Receiver([
      (payload) {
        fileId = payload.files.keys.single;
        return _accepted('remote-1', fileId, 'token-1', 0);
      },
      (payload) {
        final sessionId = ref.read(sendProvider).keys.single;
        // Not failed while it continues
        expect(ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: fileId), FileStatus.queue);
        expect(ref.read(sendProvider)[sessionId]!.status, SessionStatus.sending);
        progressAtContinuation = ref.read(fileTransferProvider).getProgress(sessionId: sessionId, fileId: fileId);
        return _accepted('remote-2', fileId, 'token-2', 500);
      },
    ]);
    uploadScripts = [
      () => [
        HttpUploadFileStartedEvent(fileId: fileId),
        HttpUploadFileProgressEvent(fileId: fileId, progress: 0.5),
        HttpUploadFileFailedEvent(fileId: fileId, error: 'connection reset', connectionLost: true),
      ],
      () => [
        HttpUploadFileStartedEvent(fileId: fileId),
        HttpUploadFileFinishedEvent(fileId: fileId),
      ],
    ];
    ref = container(receiver);

    await send(ref);

    // The first request asked for the extension, the second one continued the first session.
    expect(receiver.requests[0].shuttleResume?.v, 1);
    expect(receiver.requests[0].shuttleResume?.resumeOf, isNull);
    expect(receiver.requests[1].shuttleResume?.resumeOf, 'remote-1');
    expect(receiver.requests[1].files.keys, [fileId]);

    // The upload continued at the receiver's offset with the new token; a lost connection stops the task.
    final tasks = uploads();
    expect(tasks, hasLength(2));
    expect(tasks[0].stopOnLostConnection, isTrue);
    expect(tasks[0].files.single.resumeOffset, 0);
    expect(tasks[1].remoteSessionId, 'remote-2');
    expect(tasks[1].files.single.remoteFileToken, 'token-2');
    expect(tasks[1].files.single.resumeOffset, 500);

    // The progress stayed where the connection was lost.
    expect(progressAtContinuation, 0.5);

    // Everything was sent: the background session closed itself (it stays open when a file failed).
    expect(ref.read(sendProvider), isEmpty);
  });

  test('when the receiver stays unreachable, "Continue sending" is offered and continues the file', () async {
    late String fileId;
    Never unreachable(PrepareUploadRequestDto _) => throw const RsHttpClientError.reqwest('connection refused');
    final receiver = _Receiver([
      (payload) {
        fileId = payload.files.keys.single;
        return _accepted('remote-1', fileId, 'token-1', 0);
      },
      unreachable,
      unreachable,
      unreachable,
      (payload) => _accepted('remote-2', fileId, 'token-2', 700),
    ]);
    uploadScripts = [
      () => [HttpUploadFileFailedEvent(fileId: fileId, error: 'timed out', connectionLost: true)],
      () => [HttpUploadFileFinishedEvent(fileId: fileId)],
    ];
    final ref = container(receiver);

    await send(ref);

    final sessionId = ref.read(sendProvider).keys.single;
    expect(receiver.requests, hasLength(1 + continueDelays.length));
    expect(ref.read(sendProvider)[sessionId]!.status, SessionStatus.finishedWithErrors);
    expect(ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: fileId), FileStatus.failed);
    expect(ref.read(sendResumeProvider).get(sessionId)!.canContinue, isTrue);

    await ref.notifier(sendProvider).continueSession(sessionId);

    expect(receiver.requests.last.shuttleResume?.resumeOf, 'remote-1');
    expect(uploads().last.files.single.resumeOffset, 700);
    // Everything was sent: the background session closed itself.
    expect(ref.read(sendProvider), isEmpty);
  });

  test('a send from the queue that cannot continue in time stays queued, and its next attempt starts at the offset', () async {
    // Shuttle send queue + resume: the queue runs its sends in the background. When the connection is lost and the receiver
    // stays unreachable, the file must come back as failed (the queue keeps it, no "Continue sending" is left open), and the
    // queue's next attempt (a new request, not naming the old session) starts where the receiver says its part ends.
    Never unreachable(PrepareUploadRequestDto _) => throw const RsHttpClientError.reqwest('connection refused');
    final receiver = _Receiver([
      (payload) => _accepted('remote-1', 'file-1', 'token-1', 0),
      unreachable,
      unreachable,
      unreachable,
      (payload) => _accepted('remote-2', 'file-1', 'token-2', 400),
    ]);
    uploadScripts = [
      () => [
        HttpUploadFileStartedEvent(fileId: 'file-1'),
        HttpUploadFileProgressEvent(fileId: 'file-1', progress: 0.4),
        HttpUploadFileFailedEvent(fileId: 'file-1', error: 'timed out', connectionLost: true),
      ],
      () => [HttpUploadFileFinishedEvent(fileId: 'file-1')],
    ];
    final ref = container(receiver);
    final sender = ref.notifier(sendProvider);
    const file = CrossFile(
      name: 'video.mp4',
      fileType: FileType.video,
      size: 1000,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: [1, 2, 3],
      lastModified: null,
      lastAccessed: null,
    );
    Future<QueueStep> attempt(String sessionId) async {
      sender.trackResult(sessionId);
      await sender.startSession(
        target: _createDevice(fingerprint: 'target'),
        files: [file],
        background: true,
        sessionId: sessionId,
        fileIds: ['file-1'],
        askPin: false,
      );
      final result = sender.takeResult(sessionId);
      final step = classifyQueueResult(result, insecureMessage: 'insecure', needsPinMessage: 'pin').step;
      // As the queue runner does: close its background session, recorded only when the batch is done
      if (ref.read(sendProvider)[sessionId] != null) sender.closeSession(sessionId, recordHistory: false);
      return step;
    }

    expect(await attempt('queued-1'), QueueStep.retry);
    expect(receiver.requests, hasLength(1 + continueDelays.length));
    expect(ref.read(sendProvider), isEmpty);
    expect(ref.read(sendResumeProvider).get('queued-1'), isNull);

    expect(await attempt('queued-2'), QueueStep.done);
    expect(receiver.requests.last.shuttleResume?.v, 1);
    expect(receiver.requests.last.shuttleResume?.resumeOf, isNull);
    expect(uploads().last.files.single.resumeOffset, 400);
  });

  test('a receiver without the extension (LocalSend) fails the file as before', () async {
    late String fileId;
    final receiver = _Receiver([
      (payload) {
        fileId = payload.files.keys.single;
        return PrepareUploadResult(
          statusCode: 200,
          response: PrepareUploadResponseDto(sessionId: 'remote-1', files: {fileId: 'token-1'}),
        );
      },
    ]);
    uploadScripts = [
      () => [HttpUploadFileFailedEvent(fileId: fileId, error: 'connection reset', connectionLost: true)],
    ];
    final ref = container(receiver);

    await send(ref);

    final sessionId = ref.read(sendProvider).keys.single;
    expect(receiver.requests, hasLength(1));
    expect(uploads().single.stopOnLostConnection, isFalse);
    expect(uploads().single.files.single.resumeOffset, isNull);
    expect(ref.read(sendProvider)[sessionId]!.status, SessionStatus.finishedWithErrors);
    expect(ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: fileId), FileStatus.failed);
  });

  test('a receiver that declines the continuation ends it', () async {
    late String fileId;
    final receiver = _Receiver([
      (payload) {
        fileId = payload.files.keys.single;
        return _accepted('remote-1', fileId, 'token-1', 0);
      },
      (payload) => throw const RsHttpClientError.statusCode(status: 403),
    ]);
    uploadScripts = [
      () => [HttpUploadFileFailedEvent(fileId: fileId, error: 'connection reset', connectionLost: true)],
    ];
    final ref = container(receiver);

    await send(ref);

    final sessionId = ref.read(sendProvider).keys.single;
    expect(receiver.requests, hasLength(2));
    expect(ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: fileId), FileStatus.failed);
    expect(ref.read(sendResumeProvider).get(sessionId)!.canContinue, isFalse);
  });
}

Device _createDevice({required String fingerprint}) {
  return Device(
    signalingId: null,
    ip: '192.168.1.2',
    version: '2.1',
    port: 53317,
    https: true,
    fingerprint: fingerprint,
    alias: 'Nice Banana',
    deviceModel: 'Pixel',
    deviceType: DeviceType.mobile,
    download: false,
    channels: [HttpChannel(host: '192.168.1.2', port: 53317, https: true)],
  );
}
