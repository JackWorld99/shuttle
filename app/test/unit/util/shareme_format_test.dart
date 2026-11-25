import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/shareme_format.dart';

/// What is said about a running transfer
void main() {
  const speed = 12.3 * 1024 * 1024;

  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  test('time left is short: seconds, then minutes and seconds', () {
    expect(formatLeft(const Duration(seconds: 7)), '7 s');
    expect(formatLeft(const Duration(seconds: 67)), '1 min 7 s');
  });

  test('the pace only says what is known', () {
    expect(formatPace(left: null, speed: 0), '');
    expect(formatPace(left: null, speed: speed), '12.3 MB/s');
    expect(formatPace(left: const Duration(seconds: 7), speed: speed), endsWith(' · 12.3 MB/s'));
    expect(formatPace(left: const Duration(seconds: 7), speed: speed), contains('7 s'));
  });

  test('"0 s left" is never shown', () {
    expect(formatPace(left: Duration.zero, speed: speed), '12.3 MB/s');
    expect(formatPace(left: const Duration(milliseconds: 900), speed: speed), '12.3 MB/s');
  });
}
