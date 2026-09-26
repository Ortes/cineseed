import 'package:cineseed/core/providers.dart';
import 'package:cineseed/features/library/library_screen.dart';
import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;

void main() {
  testWidgets('library shows per-film transfer metrics and library totals',
      (tester) async {
    // Ratios are uploaded / totalSize — the formula Transmission itself uses.
    // `downloadedEver` is deliberately 0 on the second film (a cross-seed, or
    // any torrent after a ratio reset) to prove it isn't the denominator.
    const torrents = [
      TorrentState(
        hashString: 'aaa',
        name: 'Film A',
        percentDone: 1,
        isFinished: true,
        totalSize: 4 * _gib,
        downloadedEver: 4 * _gib,
        uploadedEver: 2 * _gib,
        rateUpload: _mib,
      ),
      TorrentState(
        hashString: 'bbb',
        name: 'Film B',
        percentDone: 1,
        isFinished: true,
        totalSize: 6 * _gib,
        uploadedEver: 6 * _gib,
      ),
    ];

    await tester.pumpWidget(ProviderScope(
      overrides: [libraryProvider.overrideWith((ref) => Stream.value(torrents))],
      child: const MaterialApp(home: LibraryScreen()),
    ));
    await tester.pump(); // let the stream deliver

    // Per-film: up rate, bytes sent, ratio. Rates appear twice — once on the
    // film, once in the library totals (one film carries all the traffic).
    expect(find.text('1.00 MB/s'), findsNWidgets(2));
    expect(find.text('2.00 GB sent'), findsOneWidget);
    expect(find.text('6.00 GB sent'), findsOneWidget);
    expect(find.text('ratio 0.50'), findsOneWidget);
    expect(find.text('ratio 1.00'), findsOneWidget);
    // Nothing is downloading, so no down-rate metric clutters the tiles: the
    // only "0 B/s" is the totals bar's aggregate download rate.
    expect(find.text('0 B/s'), findsNWidgets(2)); // totals down + film B up
    expect(find.byIcon(Icons.south_rounded), findsOneWidget); // totals only

    // Totals: 8 GiB sent against 10 GiB of content → 0.80, bytes-weighted.
    expect(find.text('Total uploaded'), findsOneWidget);
    expect(find.text('8.00 GB'), findsOneWidget);
    expect(find.text('0.80'), findsOneWidget);
  });
}
