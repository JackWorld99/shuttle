import 'dart:convert';

import 'package:localsend_app/util/message_preview.dart';
import 'package:test/test.dart';

void main() {
  test('short UTF-8 messages are decoded without changing the contents', () {
    for (final text in ['', 'Hello', '你好 👋\nhttps://localsend.org']) {
      expect(createMessagePreview(utf8.encode(text)), text);
    }
  });

  test('the inline limit is measured in bytes, including for CJK and emoji', () {
    expect(createMessagePreview(utf8.encode('a' * maxMessagePreviewBytes))?.length, maxMessagePreviewBytes);
    expect(createMessagePreview(utf8.encode('a' * (maxMessagePreviewBytes + 1))), isNull);
    expect(createMessagePreview(utf8.encode('中' * 90000)), isNull);
    expect(createMessagePreview(utf8.encode('👋' * 70000)), isNull);
  });

  test('missing and malformed data are transferred without an inline preview', () {
    expect(createMessagePreview(null), isNull);
    expect(createMessagePreview([0xff, 0xfe]), isNull);
  });

  test('only the beginning of a long text is laid out', () {
    expect(messageLabel('Hello\nworld'), 'Hello world');
    expect(messageLabel('a' * 100000), '${'a' * 300}…');
    expect(messageExcerpt('short'), 'short');
    expect(isMessageExcerpt('short'), isFalse);
    expect(messageExcerpt('中' * 100000), '${'中' * 8000}…');
    expect(isMessageExcerpt('中' * 100000), isTrue);
  });

  test('a text is not cut in the middle of an emoji', () {
    final label = messageLabel('a${'👋' * 1000}');
    expect(label, 'a${'👋' * 149}…');
    expect(label.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);
  });

  test('the label of bytes is the label of the text', () {
    for (final text in ['', 'Hello', 'a' * 100000, '中' * 1000, 'a${'👋' * 1000}']) {
      expect(messageLabelOf(utf8.encode(text)), messageLabel(text), reason: '${text.length} code units');
    }
  });

  test('the cheap length check agrees with the encoded length', () {
    for (final text in ['a' * maxMessagePreviewBytes, '中' * 87381, '中' * 87382, '👋' * 65536, '👋' * 65537]) {
      expect(isMessagePreviewWithinLimit(text), utf8.encode(text).length <= maxMessagePreviewBytes, reason: '${text.length} code units');
    }
  });
}
