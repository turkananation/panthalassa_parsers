import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';
import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import 'xml_support.dart';

/// Parser for ISO 20022 financial messages (pain/pacs/camt/etc.) in their XML
/// serialization, recognised by the ISO 20022 namespace
/// (`urn:iso:std:iso:20022:tech:xsd:<message>`).
///
/// Extraction surfaces the group header, initiating/instructing/instructed
/// parties, debtor/creditor accounts, transaction rows, balances, and monetary
/// amounts grouped by currency. The message definition identifier is recovered
/// from the namespace and kept alongside the business-area element name.
final class Iso20022Parser
    implements DocumentParser, OptionAwareDocumentParser {
  const Iso20022Parser();

  static const _namespaceRoot = 'urn:iso:std:iso:20022';
  static const _maxTransactions = 5000;
  static const _maxAmounts = 5000;
  static final _messageId = RegExp(
    r'urn:iso:std:iso:20022:tech:xsd:([A-Za-z]+\.\d+\.\d+\.\d+)',
  );

  static const _amountNames = {
    'amt',
    'instdamt',
    'intrbksttlmamt',
    'ttlamt',
    'eqvtamt',
    'ctrlsum',
    'txamt',
    'bal',
  };

  static const _transactionNames = {
    'cdttrftxinf',
    'dbtrtrftxinf',
    'txinf',
    'ntry',
  };

  @override
  DocumentFormat get format => DocumentFormat.iso20022;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = XmlSupport.peek(bytes, 4096);
    if (prefix == null || !XmlSupport.looksXml(prefix)) return false;
    return prefix.contains(_namespaceRoot);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) =>
      parseWithOptions(bytes, hasher: hasher);

  @override
  ParseResult parseWithOptions(
    Uint8List bytes, {
    required ContentHasher hasher,
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final digest = hasher.digestFor(bytes);
    final doc = XmlSupport.parse(bytes);
    final root = doc.rootElement;
    final prefix = XmlSupport.peek(bytes, 4096) ?? '';
    final messageDefinition = _messageId.firstMatch(prefix)?.group(1);
    final businessArea = root.childElements.firstOrNull?.localName;
    final warnings = <ParseWarning>[];
    final metadata = <String, Object?>{
      'rootElement': root.localName,
      'messageDefinition': ?messageDefinition,
      if (messageDefinition != null)
        'messageFamily': messageDefinition.split('.').first,
      'businessArea': ?businessArea,
    };

    final groupHeader = _first(root, 'GrpHdr');
    if (groupHeader != null) {
      _readGroupHeader(groupHeader, metadata);
    } else {
      warnings.add(
        const ParseWarning(
          'iso20022.group_header_missing',
          'message has no GrpHdr element',
        ),
      );
    }
    _readParties(root, metadata);
    _readSettlement(root, metadata);

    final transactions = <_Transaction>[];
    for (final element in root.descendants.whereType<XmlElement>()) {
      if (transactions.length >= _maxTransactions) {
        warnings.add(
          const ParseWarning(
            'iso20022.transaction_limit',
            'transaction count exceeded the extraction limit',
          ),
        );
        break;
      }
      if (!_transactionNames.contains(element.name.local.toLowerCase())) {
        continue;
      }
      final transaction = _readTransaction(element);
      if (transaction != null) transactions.add(transaction);
    }

    final amounts = <Map<String, Object?>>[];
    final totals = <String, double>{};
    var unparsedAmounts = 0;
    for (final element in root.descendants.whereType<XmlElement>()) {
      if (amounts.length >= _maxAmounts) break;
      final local = element.name.local.toLowerCase();
      final isAmount =
          _amountNames.contains(local) ||
          (local.endsWith('amt') && local.length > 3);
      if (!isAmount) continue;
      final raw = element.innerText.trim();
      if (raw.isEmpty) continue;
      final currency =
          element.getAttribute('Ccy') ??
          element.getAttribute('currency') ??
          element.getAttribute('ccy');
      final value = double.tryParse(raw.replaceAll(',', ''));
      if (value == null) {
        unparsedAmounts++;
        continue;
      }
      amounts.add({
        'name': element.name.local,
        'value': raw,
        'currency': ?currency,
        'numericValue': value,
      });
      if (currency != null) {
        totals[currency] = (totals[currency] ?? 0) + value;
      }
    }
    if (amounts.isNotEmpty) {
      metadata['amounts'] = amounts;
      metadata['amountsByCurrency'] = totals;
      metadata['currencies'] = totals.keys.toList()..sort();
    }
    if (unparsedAmounts > 0) {
      warnings.add(
        ParseWarning(
          'iso20022.amount_unparsed',
          '$unparsedAmounts amount value(s) were not numeric',
        ),
      );
    }
    if (transactions.isNotEmpty) {
      metadata['transactionCount'] = transactions.length;
    }

    final transactionRows = <List<String>>[];
    for (final transaction in transactions) {
      transactionRows.add(transaction.toRow());
    }
    final tables = <DocumentTable>[];
    if (options.includeTables && transactionRows.isNotEmpty) {
      tables.add(
        DocumentTable(
          name: 'transactions',
          rows: [
            [
              'type',
              'endToEndId',
              'amount',
              'currency',
              'debtor',
              'creditor',
              'remittance',
            ],
            ...transactionRows.take(options.limits.maxTableRows),
          ],
        ),
      );
    }
    if (options.includeTables && amounts.isNotEmpty) {
      tables.add(
        DocumentTable(
          name: 'amounts',
          rows: [
            ['name', 'value', 'currency'],
            for (final amount in amounts.take(options.limits.maxTableRows))
              [
                '${amount['name']}',
                '${amount['value']}',
                '${amount['currency'] ?? ''}',
              ],
          ],
        ),
      );
    }

    final summary = StringBuffer();
    void line(String label, Object? value) {
      if (value == null) return;
      final text = '$value'.trim();
      if (text.isEmpty) return;
      summary.writeln('$label: $text');
    }

    line('Message definition', messageDefinition);
    line('Business area', businessArea);
    line('Message ID', metadata['messageId']);
    line('Creation date/time', metadata['creationDateTime']);
    line('Number of transactions', metadata['numberOfTransactions']);
    line('Control sum', metadata['controlSum']);
    line('Initiating party', metadata['initiatingParty']);
    line('Debtor', metadata['debtor']);
    line('Debtor account', metadata['debtorAccount']);
    line('Creditor', metadata['creditor']);
    line('Creditor account', metadata['creditorAccount']);
    line('Settlement date', metadata['settlementDate']);
    for (final entry
        in totals.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      line('Total ${entry.key}', entry.value);
    }
    for (final transaction in transactions.take(1000)) {
      summary.writeln(transaction.toText());
    }

    var text = summary.toString().trimRight();
    final extracted = XmlSupport.extractText(root);
    if (extracted.isNotBlank) {
      text = '$text\n$extracted';
    }
    if (text.length > options.limits.maxTextCharacters) {
      text = text.substring(0, options.limits.maxTextCharacters);
      warnings.add(
        ParseWarning(
          'iso20022.text_truncated',
          'text exceeded ${options.limits.maxTextCharacters} characters',
        ),
      );
    }

    final outline = <OutlineEntry>[
      if (groupHeader != null)
        const OutlineEntry(title: 'Group header', level: 1),
      if (transactions.isNotEmpty)
        const OutlineEntry(title: 'Transactions', level: 1),
      if (amounts.isNotEmpty) const OutlineEntry(title: 'Amounts', level: 1),
    ];

    final blocks = <TextBlock>[
      for (final entry in outline)
        TextBlock(
          spans: [TextSpan(entry.title)],
          style: 'heading',
          level: entry.level,
        ),
      for (final lineText in summary.toString().split('\n'))
        if (lineText.trim().isNotEmpty)
          TextBlock(spans: [TextSpan(lineText.trim())], style: 'paragraph'),
    ];

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: text.isBlank ? null : text,
      warnings: warnings,
      structuredText: options.includeStructuredText
          ? StructuredText([TextPage(index: 0, blocks: blocks)])
          : null,
      outline: options.includeOutline ? outline : const [],
      tables: tables,
      parserVersion: parserVersion,
    );
  }

  // --- header / parties -----------------------------------------------------

  static void _readGroupHeader(
    XmlElement groupHeader,
    Map<String, Object?> metadata,
  ) {
    metadata['messageId'] = _text(groupHeader, 'MsgId');
    metadata['creationDateTime'] = _text(groupHeader, 'CreDtTm');
    metadata['numberOfTransactions'] = _text(groupHeader, 'NbOfTxs');
    metadata['controlSum'] = _text(groupHeader, 'CtrlSum');
    metadata['initiatingParty'] = _nestedText(groupHeader, 'InitgPty', 'Nm');
    metadata['instructingAgentBic'] = _pathText(groupHeader, [
      'InstgAgt',
      'FinInstnId',
      'BICFI',
    ]);
    metadata['instructedAgentBic'] = _pathText(groupHeader, [
      'InstdAgt',
      'FinInstnId',
      'BICFI',
    ]);
  }

  static void _readParties(XmlElement root, Map<String, Object?> metadata) {
    metadata['debtor'] =
        _nestedText(root, 'Dbtr', 'Nm') ?? _nestedText(root, 'UltmtDbtr', 'Nm');
    metadata['debtorAccount'] =
        _pathText(root, ['DbtrAcct', 'Id', 'IBAN']) ??
        _pathText(root, ['DbtrAcct', 'Id', 'Othr', 'Id']);
    metadata['creditor'] =
        _nestedText(root, 'Cdtr', 'Nm') ?? _nestedText(root, 'UltmtCdtr', 'Nm');
    metadata['creditorAccount'] =
        _pathText(root, ['CdtrAcct', 'Id', 'IBAN']) ??
        _pathText(root, ['CdtrAcct', 'Id', 'Othr', 'Id']);
  }

  static void _readSettlement(XmlElement root, Map<String, Object?> metadata) {
    metadata['settlementDate'] =
        _text(root, 'IntrBkSttlmDt') ??
        _text(root, 'SttlmDt') ??
        _text(root, 'ReqdExctnDt');
    metadata['settlementMethod'] =
        _text(root, 'PmtMtd') ?? _text(root, 'SttlmMtd');
  }

  static _Transaction? _readTransaction(XmlElement element) {
    final local = element.name.local.toLowerCase();
    final amountElement = _findAmount(element);
    final amount = amountElement?.innerText.trim();
    final currency =
        amountElement?.getAttribute('Ccy') ??
        amountElement?.getAttribute('currency');
    final endToEndId =
        _pathText(element, ['PmtId', 'EndToEndId']) ??
        _text(element, 'EndToEndId');
    final txId =
        _pathText(element, ['PmtId', 'TxId']) ??
        _text(element, 'TxId') ??
        _text(element, 'NtryRef');
    final debtor = _nestedText(element, 'Dbtr', 'Nm');
    final creditor = _nestedText(element, 'Cdtr', 'Nm');
    final remittance = _text(element, 'Ustrd') ?? _text(element, 'AddtlRmtInf');
    final status = _text(element, 'Sts') ?? _text(element, 'CdtDbtInd');

    if (amount == null &&
        endToEndId == null &&
        txId == null &&
        debtor == null &&
        creditor == null &&
        remittance == null) {
      return null;
    }
    return _Transaction(
      type: local,
      amount: amount,
      currency: currency,
      endToEndId: endToEndId ?? txId,
      debtor: debtor,
      creditor: creditor,
      remittance: remittance,
      status: status,
    );
  }

  static XmlElement? _findAmount(XmlElement element) {
    for (final child in element.descendants.whereType<XmlElement>()) {
      final local = child.name.local.toLowerCase();
      if (_amountNames.contains(local) ||
          (local.endsWith('amt') && local.length > 3)) {
        return child;
      }
    }
    return null;
  }

  static String? _text(XmlElement parent, String local) {
    for (final element in parent.descendants.whereType<XmlElement>()) {
      if (element.name.local == local) {
        final value = element.innerText.trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  static String? _nestedText(XmlElement parent, String child, String leaf) {
    final element = parent.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == child)
        .firstOrNull;
    return element == null ? null : _text(element, leaf);
  }

  static String? _pathText(XmlElement root, List<String> path) {
    XmlElement current = root;
    for (final local in path) {
      XmlElement? next;
      for (final element in current.descendants.whereType<XmlElement>()) {
        if (element.name.local == local) {
          next = element;
          break;
        }
      }
      if (next == null) return null;
      current = next;
    }
    final value = current.innerText.trim();
    return value.isEmpty ? null : value;
  }

  static XmlElement? _first(XmlElement root, String local) {
    for (final element in root.descendants.whereType<XmlElement>()) {
      if (element.name.local == local) return element;
    }
    return null;
  }
}

final class _Transaction {
  const _Transaction({
    required this.type,
    this.amount,
    this.currency,
    this.endToEndId,
    this.debtor,
    this.creditor,
    this.remittance,
    this.status,
  });

  final String type;
  final String? amount;
  final String? currency;
  final String? endToEndId;
  final String? debtor;
  final String? creditor;
  final String? remittance;
  final String? status;

  List<String> toRow() => [
    type,
    endToEndId ?? '',
    amount ?? '',
    currency ?? '',
    debtor ?? '',
    creditor ?? '',
    remittance ?? '',
  ];

  String toText() {
    final parts = <String>[
      type,
      if (endToEndId != null) 'id=$endToEndId',
      if (amount != null) 'amount=$amount ${currency ?? ''}'.trim(),
      if (debtor != null) 'debtor=$debtor',
      if (creditor != null) 'creditor=$creditor',
      if (status != null) 'status=$status',
      if (remittance != null) 'remittance=$remittance',
    ];
    return parts.join(' | ');
  }
}
