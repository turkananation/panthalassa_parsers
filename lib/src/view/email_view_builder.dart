import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// Email viewer for RFC 822/MIME messages.
///
/// The body is always treated as text; HTML parts are not rendered, so remote
/// trackers and scripts in an email never execute. Attachments are listed from
/// the parser's metadata and are not extracted unless the caller opted in.
final class EmailViewBuilder implements ViewBuilder {
  const EmailViewBuilder();

  @override
  String get id => 'email';

  @override
  bool supports(ParseResult result) => result.format == DocumentFormat.eml;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final title = viewerTitle(request);
    final subject = viewerString(result.metadata['subject']);
    final from = viewerString(result.metadata['from']);
    final to = viewerString(result.metadata['to']);
    final cc = viewerString(result.metadata['cc']);
    final date = viewerString(result.metadata['date']);
    final messageId = viewerString(result.metadata['messageId']);
    final sections = <ViewerSection>[];
    final notices = viewerWarnings(result);

    final body = result.text?.trim();
    if (body != null && body.isNotEmpty) {
      sections.add(ViewerTextSection(title: 'Message', text: body));
    } else {
      notices.add(
        const ViewerNotice(
          'No plain-text body was extracted from this message.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    }

    if (result.attachments.isNotEmpty) {
      sections.add(
        ViewerTableSection(
          title: 'Attachments',
          columns: const ['Name', 'Type', 'Size'],
          rows: [
            for (final attachment in result.attachments)
              [
                attachment.name ?? 'attachment',
                attachment.mediaType ?? 'application/octet-stream',
                attachment.size == null
                    ? ''
                    : formatViewerBytes(attachment.size!),
              ],
          ],
          totalRowCount: result.attachments.length,
          filterable: true,
        ),
      );
    }

    return ViewerDocument(
      title: title,
      formatLabel: result.format.label,
      subtitle: subject ?? result.format.label,
      facts: {
        ...viewerBaseFacts(request),
        'From': ?from,
        'To': ?to,
        'Cc': ?cc,
        'Date': ?date,
        'Subject': ?subject,
        'Message ID': ?messageId,
        if (result.attachments.isNotEmpty)
          'Attachments': '${result.attachments.length}',
      },
      sections: sections,
      notices: notices,
      footer: 'Panthalassa email viewer',
    );
  }
}
