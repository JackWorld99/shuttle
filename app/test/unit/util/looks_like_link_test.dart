import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/shareme/send_text_sheet.dart' show looksLikeLink;

// Shuttle security: only http / https URLs with a host count as a "link" and get an "Open" button.

void main() {
  test('regular URLs: links', () {
    expect(looksLikeLink('https://github.com/localsend/localsend'), isTrue);
    expect(looksLikeLink('http://192.168.9.168:53317/'), isTrue);
    expect(looksLikeLink('  HTTPS://Example.com/a?b=c  '), isTrue);
  });

  test('other schemes: not links (no "Open")', () {
    expect(looksLikeLink(r'file://192.168.1.5/share/x'), isFalse); // may leak login credentials on Windows
    expect(looksLikeLink(r'smb://192.168.1.5/share'), isFalse);
    expect(looksLikeLink('javascript:alert(1)'), isFalse);
    expect(looksLikeLink('ms-settings:privacy'), isFalse); // would launch another program
    expect(looksLikeLink('intent://scan/#Intent;scheme=zxing;end'), isFalse);
  });

  test('text that is not a URL: not a link', () {
    expect(looksLikeLink('20261113－1549－0006'), isFalse);
    expect(looksLikeLink('https://example.com 后面还有字'), isFalse);
    expect(looksLikeLink('https://'), isFalse);
  });
}
