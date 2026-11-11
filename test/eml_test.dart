import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List _eml(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final registry = ParserRegistry.standard();

  group('EML', () {
    test('detects strict header block', () {
      final r = registry.parse(
        _eml('''
From: sender@example.com
To: recipient@example.com
Subject: Hello
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

This is the body.
'''),
      );
      expect(r.format, DocumentFormat.eml);
      expect(r.metadata['from'], 'sender@example.com');
      expect(r.metadata['to'], 'recipient@example.com');
      expect(r.metadata['subject'], 'Hello');
      expect(r.text, contains('This is the body.'));
      expect(r.documentId, r.digest!.sha256);
      expect(r.sha512, hasLength(128));
    });

    test('unfolds folded headers', () {
      final r = registry.parse(
        _eml('''
From: sender@example.com
To: recipient@example.com
Subject: Very
 long subject
MIME-Version: 1.0

Body
'''),
      );
      expect(r.metadata['subject'], 'Very long subject');
    });

    test('plain text body', () {
      final r = registry.parse(
        _eml('''
From: a@b.com
To: c@d.com
Subject: test
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Hello world
'''),
      );
      expect(r.text, 'Hello world');
    });

    test('multipart with plain and html', () {
      final boundary = 'boundary123';
      final r = registry.parse(
        _eml('''
From: a@b.com
To: c@d.com
Subject: multipart
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="$boundary"

--$boundary
Content-Type: text/plain; charset=utf-8

Plain text body

--$boundary
Content-Type: text/html; charset=utf-8

<html><body><p>HTML body</p></body></html>

--$boundary--
'''),
      );
      expect(r.text, contains('Plain text body'));
    });

    test('base64 encoded attachment', () {
      final payload = base64Encode(utf8.encode('attachment content'));
      final r = registry.parse(
        _eml('''
From: a@b.com
To: c@d.com
Subject: with attachment
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="b1"

--b1
Content-Type: text/plain; charset=utf-8

See attached.

--b1
Content-Type: application/octet-stream
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="data.txt"

$payload

--b1--
'''),
        options: const ParseOptions(includeAttachments: true),
      );
      expect(r.format, DocumentFormat.eml);
      expect(r.attachments, isNotEmpty);
      expect(r.attachments.first.name, 'data.txt');
      expect(r.attachments.first.digest, isNotNull);
      expect(r.text, contains('See attached.'));
    });

    test('quoted-printable body', () {
      final r = registry.parse(
        _eml('''
From: a@b.com
To: c@d.com
Subject: =?UTF-8?Q?Caf=C3=A9?=
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Hello=C0=A0World
'''),
      );
      expect(r.metadata['subject'], 'Café');
    });

    test('hints route .eml to eml', () {
      final r = registry.parse(
        _eml('''
From: a@b.com
To: c@d.com
Subject: x
MIME-Version: 1.0

body
'''),
        hints: const DocumentHints(filename: 'note.eml'),
      );
      expect(r.format, DocumentFormat.eml);
    });

    test('rejects non-email text', () {
      expect(
        () => registry.parse(utf8.encode('just plain text with no headers')),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });
  });
}
