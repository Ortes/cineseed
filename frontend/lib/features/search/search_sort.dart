import 'package:cineseed_shared/cineseed_shared.dart';

/// Sortable column on a release list (search results, film detail page).
enum SortKey { age, size, seeders, name }

/// Returns a new list sorted by [key]; [desc] flips the comparator.
List<TorrentResult> sortReleases(
  List<TorrentResult> list,
  SortKey key,
  bool desc,
) {
  final copy = [...list];
  int cmp(TorrentResult a, TorrentResult b) {
    switch (key) {
      case SortKey.age:
        final ad = a.pubDate, bd = b.pubDate;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad); // newer = "smaller age"
      case SortKey.size:
        return a.size.compareTo(b.size);
      case SortKey.seeders:
        return a.seeders.compareTo(b.seeders);
      case SortKey.name:
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }
  }

  copy.sort((a, b) => desc ? cmp(b, a) : cmp(a, b));
  return copy;
}
