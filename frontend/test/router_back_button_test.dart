@TestOn('browser')
library;

import 'package:cineseed/router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('router sub-pages nest under the library', () {
    // Deep-linking (or reloading) straight onto a sub-page must resolve to a
    // route chain that already has the library beneath it. That is what makes
    // Navigator.canPop() true on a direct load, so the AppBar's back arrow
    // appears and pops to the library — the regression reported when /watch/:hash
    // was a top-level sibling route (chain length 1, no back arrow).
    int depth(String location) =>
        router.configuration.findMatch(Uri.parse(location)).routes.length;

    test('/ is the root (no parent)', () {
      expect(depth('/'), 1);
    });

    test('/watch/:hash sits on top of the library', () {
      expect(depth('/watch/abc123'), 2);
    });

    test('/film/:tmdbId sits on top of the library', () {
      expect(depth('/film/42'), 2);
    });

    test('/search sits on top of the library', () {
      expect(depth('/search'), 2);
    });
  });
}
