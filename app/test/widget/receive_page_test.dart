import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/pages/receive_page.dart' show ReceivePageVm;
import 'package:localsend_app/pages/shareme_receive_page.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

const _sender = Device(
  signalingId: null,
  ip: '192.168.1.2',
  version: '2.1',
  port: 53317,
  https: true,
  fingerprint: 'fingerprint',
  alias: 'Living room',
  deviceModel: null,
  deviceType: DeviceType.desktop,
  download: false,
  channels: [],
);

const _file = FileDto(
  id: '1',
  fileName: 'photo.jpg',
  size: 1000,
  fileType: FileType.image,
  hash: null,
  preview: null,
  metadata: null,
);

class _NoDevices extends MockPersistenceService {
  @override
  List<FavoriteDevice> getFavorites() => [];

  @override
  List<PairedRecord> getPairedRecords() => [];
}

void main() {
  testWidgets('stays as it was while it closes, after the request is gone', (tester) async {
    final persistence = _NoDevices();
    var accepted = 0;

    final status = StateProvider<SessionStatus?>((ref) => SessionStatus.waiting);
    final vm = ViewProvider<ReceivePageVm>((ref) {
      final s = ref.watch(status);
      // As in ReceiveController: without a session there is nothing left to show
      return ReceivePageVm(
        status: s,
        sender: s == null ? Device.empty : _sender,
        showSenderInfo: true,
        files: s == null ? const [] : const [_file],
        message: null,
        onAccept: () => accepted++,
        onDecline: () {},
        onClose: () {},
      );
    });
    final scope = RefenaScope(
      overrides: [persistenceProvider.overrideWithValue(persistence)],
      child: MaterialApp(
        theme: ThemeData(extensions: const [ShareMeColors.light]),
        home: SmReceivePage(vm),
      ),
    );
    await tester.pumpWidget(scope);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Living room'), findsOneWidget);
    await tester.tap(find.text(t.shareme.receive.accept));
    expect(accepted, 1);

    final context = tester.element(find.byType(SmReceivePage));
    context.ref.notifier(status).setState((_) => null);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Living room'), findsOneWidget);
    // Nothing can be answered any more
    await tester.tap(find.text(t.shareme.receive.accept), warnIfMissed: false);
    expect(accepted, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
