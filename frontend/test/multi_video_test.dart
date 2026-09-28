@TestOn('browser')
library;

import 'package:cineseed/core/providers.dart';
import 'package:cineseed/features/library/library_screen.dart';
import 'package:cineseed/features/player/watch_screen.dart';
import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:web/web.dart' as web;

const _pack = 'aaaa';

/// A complete-series pack: two season folders plus a top-level extra.
const _packFiles = TorrentFiles(
  name: 'Show.S01-S02',
  percentDone: 0.5,
  files: [
    TorrentFileInfo(index: 0, name: 'Show.S01-S02/Show.Bonus.mkv'),
    TorrentFileInfo(index: 1, name: 'Show.S01-S02/Season 1/Show.S01E01.mkv'),
    TorrentFileInfo(index: 2, name: 'Show.S01-S02/Season 1/Show.S01E02.mkv'),
    TorrentFileInfo(index: 4, name: 'Show.S01-S02/Season 2/Show.S02E01.mkv'),
    TorrentFileInfo(index: 5, name: 'Show.S01-S02/Season 2/Show.S02E02.mkv'),
  ],
);

void main() {
  setUp(() => web.window.localStorage.removeItem(Watched.storageKey));

  test('a file\'s folder is its path below the torrent\'s own directory', () {
    expect(_packFiles.files[0].folder, '');
    expect(_packFiles.files[1].folder, 'Season 1');
    expect(const TorrentFileInfo(index: 0, name: 'Film.mkv').folder, '');
    expect(const TorrentFileInfo(index: 0, name: 'P/a/b/E.mkv').folder, 'a/b');
  });

  test('a folder holding one file joins its parent\'s group', () {
    // Every episode in its own folder, under season folders.
    const files = TorrentFiles(
      files: [
        TorrentFileInfo(index: 0, name: 'P/S01/S01E01/S01E01.mkv'),
        TorrentFileInfo(index: 1, name: 'P/S01/S01E02/S01E02.mkv'),
        TorrentFileInfo(index: 2, name: 'P/S02/S02E01/S02E01.mkv'),
        TorrentFileInfo(index: 3, name: 'P/S02/S02E02/S02E02.mkv'),
        TorrentFileInfo(index: 4, name: 'P/Extras/Making.Of.mkv'),
      ],
    );
    expect(files.byFolder.map((k, v) => MapEntry(k, v.length)), {
      'S01': 2,
      'S02': 2,
      '': 1,
    });
  });

  testWidgets('a pack\'s library card opens its list, not one of its files', (
    tester,
  ) async {
    const torrents = [
      TorrentState(
        hashString: 'bbbb',
        name: 'Film',
        percentDone: 0.5,
        playable: true,
        videoCount: 1,
      ),
      TorrentState(
        hashString: _pack,
        name: 'Show.S01-S02',
        percentDone: 0.5,
        playable: true,
        videoCount: 5,
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith((ref) => Stream.value(torrents)),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pump();

    expect(find.textContaining('5 videos'), findsOneWidget);
    // Copy-link, download and the watched mark are the film's only.
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(find.byTooltip('Mark as watched'), findsOneWidget);
    expect(find.byTooltip('Choose a video'), findsOneWidget);
  });

  testWidgets('the file list groups by folder and counts watched files', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          torrentFilesProvider(
            _pack,
          ).overrideWith((ref) => Stream.value(_packFiles)),
        ],
        child: const MaterialApp(home: WatchScreen(hash: _pack)),
      ),
    );
    await tester.pump();

    // Top-level files first with no header, then each folder under its own.
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Show.Bonus.mkv'), lessThan(y('Season 1')));
    expect(y('Season 1'), lessThan(y('Show.S01E01.mkv')));
    expect(y('Show.S01E02.mkv'), lessThan(y('Season 2')));
    expect(y('Season 2'), lessThan(y('Show.S02E01.mkv')));
    expect(find.textContaining('watched'), findsNothing);

    await tester.tap(find.byTooltip('Mark as watched').at(1)); // S01E01
    await tester.pump();

    expect(find.textContaining('1 watched'), findsOneWidget);
    expect(
      web.window.localStorage.getItem(Watched.storageKey),
      contains('$_pack.1'),
    );
  });
}
