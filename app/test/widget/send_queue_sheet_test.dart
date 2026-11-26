import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart';
import 'package:localsend_app/widget/shareme/send_queue_sheet.dart';
import 'package:localsend_app/widget/shareme/send_target_sheet.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

const _phone = 'phone-fp';
const _pc = 'pc-fp';

class _Store extends Fake implements PersistenceService {
  List<QueuedSend> queue;

  _Store(this.queue);

  @override
  List<QueuedSend> getSendQueue() => queue;

  @override
  Future<void> setSendQueue(List<QueuedSend> entries) async => queue = entries;
}

class _NoSends extends SendNotifier {
  @override
  Map<String, SendSessionState> init() => {};
}

SendTabVm _vm({required List<FavoriteDevice> favorites, required List<Device> nearby}) => SendTabVm(
  sendMode: SendMode.single,
  selectedFiles: const [],
  localIps: const [],
  nearbyDevices: nearby,
  favoriteDevices: favorites,
  onTapAddress: (_) async {},
  onTapFavorite: (_) async {},
  onTapSendMode: (_, _) async {},
  onTapDevice: (_, _) async {},
  onTapDeviceMultiSend: (_, _) async {},
);

final _phoneFavorite = FavoriteDevice.fromValues(fingerprint: _phone, ip: '192.168.1.5', port: 53317, alias: '小米手机');
final _pcFavorite = FavoriteDevice.fromValues(fingerprint: _pc, ip: '192.168.1.9', port: 53317, alias: '书房电脑');

const _pcOnline = Device(
  signalingId: null,
  ip: '192.168.1.9',
  version: '2.1',
  port: 53317,
  https: true,
  fingerprint: _pc,
  alias: '书房电脑',
  deviceModel: null,
  deviceType: DeviceType.desktop,
  download: false,
  channels: [],
);

QueuedSend _entry(String id, List<QueuedFile> files) =>
    QueuedSend(id: id, targetFingerprint: _phone, targetAlias: '小米手机', createdAt: DateTime.now().toUtc(), files: files);

QueuedFile _photo(String name, int size) => QueuedFile(
  id: name,
  fileName: name,
  fileType: FileType.image,
  size: size,
  path: null,
  ownedCopy: false,
  assetId: null,
  isMessage: false,
  preview: null,
  lastModified: null,
  lastAccessed: null,
);

const _link = QueuedFile(
  id: 'link',
  fileName: 'link.txt',
  fileType: FileType.text,
  size: 20,
  path: null,
  ownedCopy: true,
  assetId: null,
  isMessage: true,
  preview: 'https://example.com/a',
  lastModified: null,
  lastAccessed: null,
);

Widget _app(_Store store, SendTabVm vm, Widget child) => RefenaScope(
  overrides: [
    persistenceProvider.overrideWithValue(store),
    sendProvider.overrideWithNotifier((ref) => _NoSends()),
    sendTabVmProvider.overrideWithBuilder((ref) => vm),
  ],
  child: MaterialApp(
    theme: ThemeData(extensions: const [ShareMeColors.light]),
    home: Scaffold(body: child),
  ),
);

void main() {
  // zh-CN is a deferred library: load it before the tests read Chinese text
  setUpAll(() async => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('"Waiting for X" lists each batch; Cancel removes one, Cancel all the rest', (tester) async {
    final store = _Store([
      _entry('photos', [_photo('IMG_1.jpg', 3 * 1024 * 1024), _photo('IMG_2.jpg', 1024 * 1024)]),
      _entry('link', [_link]),
    ]);
    await tester.pumpWidget(
      _app(store, _vm(favorites: [_phoneFavorite], nearby: const []), const SendQueueSheet(fingerprint: _phone)),
    );
    await tester.pump();

    expect(find.text('待发给 小米手机'), findsOneWidget);
    expect(find.text('小米手机 现在不在线，上线后自动发。'), findsOneWidget);
    expect(find.text('IMG_1.jpg 等 2 项'), findsOneWidget);
    expect(find.textContaining('4.0 MB · '), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);
    expect(find.textContaining('链接 · '), findsOneWidget);
    expect(find.text('现在试一次'), findsOneWidget);
    expect(find.text('再加一些'), findsOneWidget, reason: 'offline: more can be queued');

    await tester.tap(find.byTooltip('取消').first);
    await tester.pump();
    final container = tester.element(find.byType(SendQueueSheet)).ref;
    expect(container.read(sendQueueProvider).map((e) => e.id), ['link']);

    await tester.tap(find.text('全部取消'));
    await tester.pump();
    expect(container.read(sendQueueProvider), isEmpty);
    await tester.pump(const Duration(seconds: 5)); // let the save and the button animations finish
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with nothing waiting it explains what happens and offers to pick something', (tester) async {
    await tester.pumpWidget(_app(_Store([]), _vm(favorites: [_phoneFavorite], nearby: const []), const SendQueueSheet(fingerprint: _phone)));
    await tester.pump();
    expect(find.text('小米手机 现在不在线。选好要发的，它上线后自动发过去。'), findsOneWidget);
    expect(find.text('选要发的'), findsOneWidget);
    expect(find.text('全部取消'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"Send to": an offline "my device" can be picked and says it goes out once it is back', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _app(
        _Store([]),
        _vm(favorites: [_pcFavorite, _phoneFavorite], nearby: const [_pcOnline]),
        SendTargetList(selected: null, onSelect: picked.add),
      ),
    );
    await tester.pump();
    expect(find.text('不在线 · 上线后自动发'), findsOneWidget);
    await tester.tap(find.text('小米手机'));
    expect(picked, [_phone]);

    final vm = _vm(favorites: [_pcFavorite, _phoneFavorite], nearby: const [_pcOnline]);
    expect(sendTargetDevice(vm, _phone), isNull, reason: 'not online');
    final offline = offlineMineTarget(vm, _phone)!;
    expect(offline.ip, '192.168.1.5');
    expect(offline.alias, '小米手机');
    expect(offlineMineTarget(vm, 'stranger'), isNull, reason: 'only "my devices" can be queued for');
    await tester.pumpWidget(const SizedBox());
  });
}
