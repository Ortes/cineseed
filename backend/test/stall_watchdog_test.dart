import 'dart:async';

import 'package:cineseed_backend/src/storage/stall_watchdog.dart';
import 'package:test/test.dart';

const _timeout = Duration(milliseconds: 100);

void main() {
  group('awaitProgress', () {
    test('passes a transfer that completes through untouched', () async {
      final seen = <int>[];
      await awaitProgress(
        stallTimeout: _timeout,
        what: 'upload',
        onProgress: seen.add,
        run: (progress) async {
          progress(10);
          progress(20);
        },
      );
      expect(seen, [10, 20]);
    });

    test('propagates the transfer\'s own failure as-is', () {
      expect(
        awaitProgress(
          stallTimeout: _timeout,
          what: 'upload',
          run: (_) async => throw StateError('connection refused'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    // The production failure: S3 took a whole 64 MiB part, acknowledged every
    // byte, then never sent a response — leaving a future that never completes.
    test('fails a transfer that accepts everything then goes silent', () {
      expect(
        awaitProgress(
          stallTimeout: _timeout,
          what: 'S3 upload of film.mkv',
          run: (progress) {
            progress(64 * 1024 * 1024);
            return Completer<void>().future; // never completes, ever
          },
        ),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('S3 upload of film.mkv'),
          ),
        ),
      );
    });

    test(
      'never cuts off a slow transfer that keeps reporting progress',
      () async {
        var sent = 0;
        await awaitProgress(
          stallTimeout: _timeout,
          what: 'upload',
          run: (progress) async {
            // Ten quiet stretches, each most of the stall budget: far longer than
            // the timeout in total, but never silent for it.
            for (var i = 0; i < 10; i++) {
              await Future<void>.delayed(_timeout ~/ 2);
              progress(sent += 1024);
            }
          },
        );
        expect(sent, 10240);
      },
    );

    test(
      'drops progress from a transfer that wakes up after being abandoned',
      () async {
        final wokeUp = Completer<void>();
        final seen = <int>[];
        late void Function(int) report;

        await expectLater(
          awaitProgress(
            stallTimeout: _timeout,
            what: 'upload',
            onProgress: seen.add,
            run: (progress) {
              report = progress;
              return wokeUp.future;
            },
          ),
          throwsA(isA<TimeoutException>()),
        );

        expect(seen, isEmpty);
        report(999); // the abandoned transfer, reporting long after we gave up
        wokeUp.complete();
        expect(seen, isEmpty, reason: 'a retry owns this transfer now');
      },
    );
  });
}
