/// Bytes → human-readable size ("3.5 GB"). Returns "—" for 0/negative.
String fmtSize(int bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(size < 10 && i > 0 ? 2 : 1)} ${units[i]}';
}

/// Bytes/s → human-readable rate ("1.20 MB/s"). Returns "0 B/s" when idle, so a
/// live speed readout keeps its shape instead of blanking out between ticks.
String fmtRate(int bytesPerSecond) =>
    bytesPerSecond <= 0 ? '0 B/s' : '${fmtSize(bytesPerSecond)}/s';

/// Bytes → human-readable size, spelling zero out as "0 B" instead of the "—"
/// [fmtSize] uses. For a counter that legitimately sits at zero — an upload
/// total right after a ratio reset — a dash would read as "unknown".
String fmtBytes(int bytes) => bytes <= 0 ? '0 B' : fmtSize(bytes);

/// Share ratio → two decimals, "—" when there's nothing to divide by.
String fmtRatio(double? ratio) => ratio == null ? '—' : ratio.toStringAsFixed(2);

/// DateTime → short relative age ("3 d", "2 mo", "1 y").
String fmtAge(DateTime? d) {
  if (d == null) return '—';
  final diff = DateTime.now().difference(d);
  if (diff.inDays >= 365) return '${diff.inDays ~/ 365} y';
  if (diff.inDays >= 30) return '${diff.inDays ~/ 30} mo';
  if (diff.inDays >= 7) return '${diff.inDays ~/ 7} w';
  if (diff.inDays >= 1) return '${diff.inDays} d';
  if (diff.inHours >= 1) return '${diff.inHours} h';
  return '${diff.inMinutes.clamp(1, 59)} m';
}
