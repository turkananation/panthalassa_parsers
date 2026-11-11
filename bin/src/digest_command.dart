/// `digest` — content-address files with the vault's SHA-256/384/512 path.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'console.dart';
import 'support.dart';

/// Content addresses one or more inputs without parsing them.
///
/// This is deliberately separate from `parse`: the digest describes the exact
/// input bytes, even for formats no parser recognises yet.
final class DigestCommand extends Command<void> {
  DigestCommand() {
    argParser
      ..addOption(
        'algo',
        allowed: ['all', 'sha256', 'sha384', 'sha512'],
        defaultsTo: 'all',
        valueHelp: 'name',
        help: 'Digest to print: all, sha256, sha384, or sha512.',
      )
      ..addOption(
        'expect',
        valueHelp: 'hex',
        help:
            'Compare the SHA-256 value with this hex digest (one input only). '
            'Exits 65 on mismatch.',
      )
      ..addFlag(
        'short',
        negatable: false,
        help: 'Abbreviate hashes in human output.',
      )
      ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.')
      ..addOption(
        'out',
        valueHelp: 'file',
        help: 'Write JSON output to a file (requires --json).',
      );
  }

  @override
  String get name => 'digest';

  @override
  String get description =>
      'Content-address files with SHA-256, SHA-384, and SHA-512.';

  @override
  String get invocation => 'panthalassa digest <file|->... [options]';

  @override
  String get usageFooter => usageExamples([
    '# All three digests for one file',
    'panthalassa digest report.pdf',
    '# The canonical vault document id only',
    'panthalassa digest report.pdf --algo sha256 --short',
    '# Verify an expected SHA-256 in a script',
    'panthalassa digest report.pdf --expect 4f9c... --json',
    '# Digest stdin without parsing it',
    'cat payload.bin | panthalassa digest -',
  ]);

  @override
  Future<void> run() async {
    final inputs = argResults!.rest;
    if (inputs.isEmpty) {
      usageException('Provide at least one input path (use "-" for stdin).');
    }
    final json = argResults!['json'] as bool;
    final out = argResults!['out'] as String?;
    if (out != null && !json) {
      usageException('--out is only valid together with --json.');
    }
    final expected = argResults!['expect'] as String?;
    if (expected != null && inputs.length != 1) {
      usageException('--expect accepts exactly one input path.');
    }
    if (expected != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expected)) {
      usageException('--expect must be a 64-character SHA-256 hex digest.');
    }

    const hasher = PqBytesContentHasher();
    final algo = argResults!['algo'] as String;
    final files = <Map<String, Object?>>[];
    var mismatch = false;

    for (final path in inputs) {
      final input = await readInput(path);
      final digest = hasher.digestFor(input.bytes);
      final match = expected == null
          ? null
          : digest.sha256.toLowerCase() == expected.toLowerCase();
      if (match == false) mismatch = true;
      files.add({
        'path': input.displayName,
        'byteLength': input.byteLength,
        'digest': _selectedDigest(digest, algo),
        if (match != null) 'expectedSha256': expected!.toLowerCase(),
        'match': ?match,
      });
    }

    if (json) {
      await emitJson({
        'algorithm': algo,
        'count': files.length,
        'files': files,
      }, out);
    } else {
      _writeHuman(files, algo);
    }

    if (mismatch) {
      if (!json) {
        console.failure('SHA-256 did not match --expect.');
      }
      exitCode = exitData;
    } else if (expected != null && !json) {
      console.success('SHA-256 matches --expect.');
    }
  }

  Map<String, String> _selectedDigest(ContentDigest digest, String algo) {
    if (algo == 'sha256') return {'sha256': digest.sha256};
    if (algo == 'sha384') return {'sha384': digest.sha384};
    if (algo == 'sha512') return {'sha512': digest.sha512};
    return digest.toJson().cast<String, String>();
  }

  void _writeHuman(List<Map<String, Object?>> files, String algo) {
    final short = argResults!['short'] as bool;
    console.section(
      'Content address${files.length == 1 ? '' : ' (${files.length} files)'}',
    );
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final path = file['path']! as String;
      if (files.length > 1) {
        console.info('\n  ${console.ansi.bold(path)}');
      } else {
        console.detail('file', path);
      }
      console.detail('size', formatBytes(file['byteLength']! as int), pad: 10);
      final digest = file['digest']! as Map<String, String>;
      for (final entry in digest.entries) {
        final value = short ? shortHash(entry.value) : entry.value;
        console.detail(entry.key, value, pad: 10);
      }
      if (file['match'] != null) {
        final matched = file['match']! as bool;
        final label = matched ? 'match' : 'mismatch';
        final styled = matched
            ? console.ansi.green(label)
            : console.ansi.brightRed(label);
        console.detail('expect', styled, pad: 10);
      }
    }
    if (algo == 'all' && !short) {
      console.hint(
        '\nSHA-256 is the canonical documentId; SHA-384/SHA-512 are carried '
        'for long-lived integrity evidence.',
      );
    } else if (algo == 'all') {
      console.hint('\nUse --json or omit --short for full hashes.');
    }
  }
}
