import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';
import 'json_support.dart';

/// Parser for W3C Verifiable Credentials and Presentations in either of their
/// standard serializations: JSON-LD (`application/vc+ld+json`) and compact JWT
/// (`application/vc+jwt`, with the credential under the `vc`/`vp` claim).
final class VerifiableCredentialParser implements DocumentParser {
  const VerifiableCredentialParser();

  static const _vcMarkers = [
    'VerifiableCredential',
    'VerifiablePresentation',
    'www.w3.org/2018/credentials',
    'www.w3.org/ns/credentials',
  ];

  @override
  DocumentFormat get format => DocumentFormat.verifiableCredential;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = JsonSupport.peek(bytes, 8192);
    if (prefix == null) return false;
    final trimmed = prefix.trimLeft();

    if (JsonSupport.looksJson(trimmed)) {
      return _vcMarkers.any(prefix.contains);
    }
    // JWT form: validate shape on the whole token, then inspect the payload.
    final whole = JsonSupport.peek(bytes, 1 << 20)?.trim();
    if (whole != null && JsonSupport.jwtShape.hasMatch(whole)) {
      final payload = JsonSupport.decodeJwtSegment(whole.split('.')[1]);
      return payload != null &&
          (payload.containsKey('vc') ||
              payload.containsKey('vp') ||
              payload['type'].toString().contains('VerifiableCredential'));
    }
    return false;
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final whole = JsonSupport.peek(bytes, 1 << 20)?.trim() ?? '';
    final isJwt = !JsonSupport.looksJson(whole) &&
        JsonSupport.jwtShape.hasMatch(whole);
    return isJwt
        ? _parseJwt(bytes, whole, hasher)
        : _parseJsonLd(bytes, hasher);
  }

  ParseResult _parseJsonLd(Uint8List bytes, ContentHasher hasher) {
    final List<Object?> records;
    try {
      (records, _) = JsonSupport.decode(bytes);
    } on FormatException catch (e) {
      throw MalformedDocumentException('invalid VC JSON-LD: ${e.message}');
    }
    final cred = records.first;
    if (cred is! Map) {
      throw const MalformedDocumentException('VC is not a JSON object');
    }

    final text = StringBuffer();
    JsonSupport.collectText(cred, text);
    final body = text.toString().trimRight();

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'serialization': 'json-ld',
        if (cred['type'] != null) 'type': cred['type'],
        if (cred['issuer'] != null) 'issuer': _issuer(cred['issuer']),
        if (cred['issuanceDate'] != null) 'issuanceDate': cred['issuanceDate'],
        if (cred['validFrom'] != null) 'validFrom': cred['validFrom'],
        'hasProof': cred.containsKey('proof'),
      },
      text: body.isEmpty ? null : body,
      warnings: const [],
    );
  }

  ParseResult _parseJwt(Uint8List bytes, String token, ContentHasher hasher) {
    final parts = token.split('.');
    final header = JsonSupport.decodeJwtSegment(parts[0]);
    final payload = JsonSupport.decodeJwtSegment(parts[1]);
    if (payload == null) {
      throw const MalformedDocumentException('VC-JWT payload is not valid JSON');
    }

    final text = StringBuffer();
    JsonSupport.collectText(payload, text);
    final body = text.toString().trimRight();

    final vc = payload['vc'] ?? payload['vp'];
    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'serialization': 'jwt',
        if (header != null && header['alg'] != null) 'alg': header['alg'],
        if (payload['iss'] != null) 'issuer': payload['iss'],
        if (payload['sub'] != null) 'subject': payload['sub'],
        if (vc is Map && vc['type'] != null) 'type': vc['type'],
        'signed': parts.length == 3 && parts[2].isNotEmpty,
      },
      text: body.isEmpty ? null : body,
      warnings: const [],
    );
  }

  Object? _issuer(Object? issuer) =>
      issuer is Map ? issuer['id'] ?? issuer : issuer;
}
