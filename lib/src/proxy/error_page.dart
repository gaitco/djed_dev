import 'dart:convert';

import '../sites.dart';

const _escaper = HtmlEscape(HtmlEscapeMode.unknown);

String escapeHtml(String text) => _escaper.convert(text);

String _page(String title, String body) =>
    '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    '<title>${escapeHtml(title)}</title>'
    '<style>body{font-family:system-ui,sans-serif;max-width:44rem;margin:4rem auto;padding:0 1rem;color:#222}'
    'h1{font-size:1.5rem}pre{background:#f4f5fa;padding:1rem;overflow:auto;border-radius:.4rem}'
    'a{color:#2a3154}li{margin:.3rem 0}footer{margin-top:3rem;opacity:.6;font-size:.85rem}</style></head>'
    '<body>$body<footer>djed</footer></body></html>';

String notFoundPage(String host, List<Site> sites, String tld) {
  final list = sites.isEmpty
      ? '<p>No sites are registered. Run <code>djed park</code> in a directory of apps, or <code>djed link</code> inside one.</p>'
      : '<ul>${sites.map((s) => '<li><a href="https://${escapeHtml(s.name)}.$tld">${escapeHtml(s.name)}.$tld</a> <small>${escapeHtml(s.path)}</small></li>').join()}</ul>';
  return _page(
    'No site for $host',
    '<h1>No site answers to <code>${escapeHtml(host)}</code></h1>$list',
  );
}

String badGatewayPage(Site site, String reason, String logTail) => _page(
  '${site.name} is not responding',
  '<h1><code>${escapeHtml(site.name)}</code> is not responding</h1>'
      '<p>${escapeHtml(reason)}</p>'
      '<p>Directory: <code>${escapeHtml(site.path)}</code></p>'
      '<h2>Log</h2><pre>${escapeHtml(logTail.isEmpty ? '(empty)' : logTail)}</pre>'
      '<p>Reload after fixing the app; <code>djed log ${escapeHtml(site.name)}</code> shows the full log.</p>',
);
