import 'dart:convert';

import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';

/// A text up to this size is sent as a message: it goes to the clipboard and into the history. A larger one is transferred as a text
/// file. This only limits the preview, never what is transferred.
///
/// LocalSend (since 1.19, where this file comes from) draws the line at 16 KB, because it lays out the whole message. Shuttle only lays
/// out the beginning ([messageExcerpt]), so a long article can still be pasted on the other device. The limit also keeps it below what
/// Android lets through to the clipboard (1 MB, in UTF-16).
const maxMessagePreviewBytes = 256 * 1024;

/// How much of a message is laid out at most. Laying out a paragraph takes time with its length, and without any spaces (encoded data,
/// minified code) with the square of it: 256 KB took 6 seconds, 1 MB took 98.
const _excerptLength = 8000;

/// How much of a message is laid out on a single line
const _labelLength = 300;

/// The text of [bytes], if it can be sent as a message
String? createMessagePreview(List<int>? bytes) {
  if (bytes == null || bytes.length > maxMessagePreviewBytes) {
    return null;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Binary or malformed text should still be transferable as a file.
    return null;
  }
}

bool isMessagePreviewWithinLimit(String preview) {
  // A UTF-16 code unit encodes to at most 3 UTF-8 bytes,
  // so only strings close to the limit need an encoded copy.
  if (preview.length > maxMessagePreviewBytes) {
    return false;
  }
  if (preview.length * 3 <= maxMessagePreviewBytes) {
    return true;
  }
  return utf8.encode(preview).length <= maxMessagePreviewBytes;
}

/// Returns true if [files] is a "message request": a single text file with its preview included.
///
/// Unlike [extractMessagePreview], this ignores the size of the preview. Older peers
/// embed text of any length, which is received as a file instead of shown inline,
/// but must still not be accepted automatically, as before.
///
/// Current senders omit the preview above [maxMessagePreviewBytes], so their large
/// text is indistinguishable from a regular `.txt` file and is treated as one.
bool isMessageRequestOf(Iterable<FileDto> files) {
  if (files.length != 1) {
    return false;
  }
  final file = files.first;
  return file.fileType == FileType.text && file.preview != null;
}

String? extractMessagePreview(Iterable<FileDto> files) {
  if (!isMessageRequestOf(files)) {
    return null;
  }
  final file = files.first;
  final preview = file.preview!;
  return file.size <= maxMessagePreviewBytes && isMessagePreviewWithinLimit(preview) ? preview : null;
}

/// The beginning of a message, for showing it in full size. Copying and opening always use the whole message.
String messageExcerpt(String message) => _start(message, _excerptLength);

/// Whether [messageExcerpt] leaves something out
bool isMessageExcerpt(String message) => message.length > _excerptLength;

/// The beginning of a message, for showing it on one line (or two)
String messageLabel(String message) => _start(message, _labelLength).replaceAll('\n', ' ');

/// [messageLabel] of a text that isn't decoded yet; only its beginning is
String messageLabelOf(List<int> bytes) {
  const enough = _labelLength * 4; // a character has 4 bytes at most
  return messageLabel(utf8.decode(bytes.length > enough ? bytes.sublist(0, enough) : bytes, allowMalformed: true));
}

String _start(String text, int length) {
  if (text.length <= length) return text;
  // Not between the two halves of an emoji
  final end = (text.codeUnitAt(length - 1) & 0xFC00) == 0xD800 ? length - 1 : length;
  return '${text.substring(0, end)}…';
}
