import 'dart:async';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/settings_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/sent_history_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/notification_strings.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' show PrepareUploadRequestDto, PrepareUploadResponseDto, ProtocolType;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

// Shuttle send queue: what the queue relies on in the send provider — chosen session / file IDs, the end result of a send
// (also after it closed itself), no PIN dialog for unattended sends, and background sends recorded as delivered.

class _SyncState extends Fake implements SyncState {}

class _Settings extends Fake implements SettingsState {
  @override
  bool get createChecksums => false;

  @override
  bool get https => true;

  @override
  SendMode get sendMode => SendMode.multiple;
}

class _TestSettingsService extends SettingsService {
  _TestSettingsService(super.persistence);

  @override
  SettingsState init() => _Settings();
}

class _History extends MockPersistenceService {
  List<SentHistoryEntry> saved = [];

  @override
  bool isSaveToHistory() => true;

  @override
  List<SentHistoryEntry> getSentHistory() => saved;

  @override
  Future<void> setSentHistory(List<SentHistoryEntry> entries) async => saved = entries;
}

class _CancellationToken extends Fake implements RsCancellationToken {
  @override
  void cancel() {}
}

class _RustLibApi extends Fake implements RustLibApi {
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() => _CancellationToken();
}

/// Answers prepare-upload with [answer]
class _HttpClient extends Fake implements RsHttpClient {
  final Future<PrepareUploadResult> Function(PrepareUploadRequestDto payload) answer;
  int calls = 0;

  _HttpClient(this.answer);

  @override
  Future<PrepareUploadResult> prepareUpload({
    required ProtocolType protocol,
    required String ip,
    required int port,
    required PrepareUploadRequestDto payload,
    String? publicKey,
    String? pin,
    required RsCancellationToken cancelToken,
  }) {
    calls++;
    return answer(payload);
  }
}

class _HttpClientCollection extends Fake implements HttpClientCollection {
  final RsHttpClient client;

  _HttpClientCollection(this.client);

  @override
  RsHttpClient pinnedTo(String fingerprint, {int? timeoutMs}) => client;
}

RefenaContainer _container(RsHttpClient client, PersistenceService persistence) => RefenaContainer(
  overrides: [
    persistenceProvider.overrideWithValue(persistence),
    settingsProvider.overrideWithNotifier((ref) => _TestSettingsService(persistence)),
    httpProvider.overrideWithBuilder((_) => _HttpClientCollection(client)),
    deviceFullInfoProvider.overrideWithBuilder((_) => _device('self')),
    parentIsolateProvider.overrideWithReducer(
      notifier: (_) => IsolateController(initialState: ParentIsolateState.initial(_SyncState())),
      reducer: {
        // Every file is uploaded at once
        IsolateHttpUploadFilesAction: (state) => (
          state,
          IsolateHttpUploadActionResult(
            taskId: 1,
            events: Stream.fromIterable([
              HttpUploadFileStartedEvent(fileId: 'f1'),
              HttpUploadFileFinishedEvent(fileId: 'f1'),
            ]),
          ),
        ),
      },
    ),
  ],
);

const _photo = CrossFile(
  name: 'a.jpg',
  fileType: FileType.image,
  size: 3,
  thumbnail: null,
  asset: null,
  path: null,
  bytes: [1, 2, 3],
  lastModified: null,
  lastAccessed: null,
);

void main() {
  setUpAll(() {
    RustLib.initMock(api: _RustLibApi());
    TransferNotification.init(notificationStrings); // as in preInit (the notification itself does nothing off Android)
  });

  test('a background send that delivers everything is recorded as delivered, and its result can still be read', () async {
    final history = _History();
    final client = _HttpClient(
      (payload) async => PrepareUploadResult(
        statusCode: 200,
        response: PrepareUploadResponseDto(sessionId: 'remote', files: {for (final id in payload.files.keys) id: 'token-$id'}),
      ),
    );
    final ref = _container(client, history);
    final sender = ref.notifier(sendProvider);

    sender.trackResult('s1');
    final id = await sender.startSession(target: _device('target'), files: [_photo], background: true, sessionId: 's1', fileIds: ['f1']);

    expect(id, 's1');
    expect(ref.read(sendProvider), isEmpty, reason: 'a successful background send closes itself');
    expect(ref.read(sentHistoryProvider).single.result, SentHistoryResult.delivered, reason: 'it used to say "you canceled"');
    final result = sender.takeResult('s1')!;
    expect(result.state.status, SessionStatus.finished);
    expect(result.statuses, {'f1': FileStatus.finished});
    expect(sender.takeResult('s1'), isNull, reason: 'taken once');
  });

  test('an unattended send to a device that wants a PIN stops instead of opening the PIN dialog', () async {
    final client = _HttpClient((_) => Future.error(const RsHttpClientError.statusCode(status: 401)));
    final ref = _container(client, _History());
    final sender = ref.notifier(sendProvider);

    sender.trackResult('s2');
    await sender.startSession(target: _device('target'), files: [_photo], background: true, sessionId: 's2', askPin: false);

    expect(client.calls, 1);
    final result = sender.takeResult('s2')!;
    expect(result.state.status, SessionStatus.finishedWithErrors);
    expect(result.state.errorMessage, needsPinMessage);
  });

  test('closing without recording leaves the history alone, and the result is kept for the queue', () async {
    final history = _History();
    final client = _HttpClient((_) => Future.error(const RsHttpClientError.statusCode(status: 409)));
    final ref = _container(client, history);
    final sender = ref.notifier(sendProvider);

    sender.trackResult('s3');
    await sender.startSession(target: _device('target'), files: [_photo], background: true, sessionId: 's3');
    sender.closeSession('s3', recordHistory: false);

    expect(ref.read(sendProvider), isEmpty);
    expect(ref.read(sentHistoryProvider), isEmpty);
    expect(sender.takeResult('s3')!.state.status, SessionStatus.recipientBusy);
  });
}

Device _device(String fingerprint) => Device(
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
