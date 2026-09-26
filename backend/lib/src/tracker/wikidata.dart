import 'dart:convert';

import 'package:http/http.dart' as http;

/// AlloCiné film ids (Wikidata P1265) by TMDB movie id (P4947), for those of
/// [tmdbIds] Wikidata links both ways: about a third of recent films. One
/// SPARQL query, POSTed (a GET of many ids overflows the URL).
Future<Map<int, String>> allocineIds(
  Iterable<int> tmdbIds, {
  http.Client? client,
}) async {
  final values = tmdbIds.map((id) => '"$id"').join(' ');
  final res = await (client?.post ?? http.post)(
    Uri.https('query.wikidata.org', '/sparql'),
    // Wikidata asks every client to identify itself.
    headers: {
      'User-Agent': 'cineseed (https://github.com/Ortes/cineseed)',
      'Accept': 'application/sparql-results+json',
    },
    body: {
      'query':
          'SELECT ?tmdb ?allocine WHERE { VALUES ?tmdb { $values } '
          '?film wdt:P4947 ?tmdb; wdt:P1265 ?allocine. }',
    },
  );
  if (res.statusCode != 200) {
    throw Exception('Wikidata SPARQL → HTTP ${res.statusCode}');
  }
  final rows = (jsonDecode(res.body) as Map)['results']['bindings'] as List;
  return {
    for (final r in rows.cast<Map<String, dynamic>>())
      int.parse(r['tmdb']['value'] as String): r['allocine']['value'] as String,
  };
}
