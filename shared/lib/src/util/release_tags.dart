/// Tags extracted from a scene/release filename. All fields nullable — only
/// what the title actually contains is populated.
class ReleaseTags {
  final String? language; // MULTI.VFF, VFF, VFQ, VOSTFR, MULTI...
  final String? resolution; // 480p / 720p / 1080p / 2160p
  final String?
  source; // BluRay / WEB-DL / WEBRip / HDLight / Remux / BDMV / ISO
  final String? codec; // H.264 / H.265 / x264 / x265 / AV1
  final String? audio; // AAC / AC3 / EAC3 / DTS / DTS-HD / TrueHD / Atmos
  final String? channels; // 5.1 / 7.1 / 2.0
  final String? hdr; // HDR10 / DV.HDR10 / DV
  final String? group; // -SenSei, -NOTAG, etc.

  const ReleaseTags({
    this.language,
    this.resolution,
    this.source,
    this.codec,
    this.audio,
    this.channels,
    this.hdr,
    this.group,
  });

  /// Ordered list of non-null tags, ready for chip rendering.
  List<String> get chips => [
    ?language,
    ?resolution,
    ?source,
    ?hdr,
    if (audio != null) channels != null ? '$audio $channels' : audio!,
    ?codec,
  ];

  static final _resRe = RegExp(
    r'\b(2160p|1080p|720p|480p)\b',
    caseSensitive: false,
  );
  static final _sourceRe = RegExp(
    r'\b(BluRay|BDRip|BRRip|BDMV|Remux|WEB-?DL|WEB-?Rip|HDLight|HDRip|HDTV|DVDRip|ISO|4KLight)\b',
    caseSensitive: false,
  );
  static final _codecRe = RegExp(
    r'\b(x265|x264|H\.?265|H\.?264|HEVC|AV1)\b',
    caseSensitive: false,
  );
  static final _audioRe = RegExp(
    r'\b(EAC3|E-AC-?3|AC3|AC-?3|AAC|TrueHD|Atmos|DTS-?HD(?:[. -]MA)?|DTS|FLAC|MP3|Opus)\b',
    caseSensitive: false,
  );
  static final _channelsRe = RegExp(
    r'(?<![\d.])(7\.1|5\.1|2\.0|2\.1)(?![\d.])',
  );
  static final _hdrRe = RegExp(
    r'\b(DV\.HDR10|HDR10\+|HDR10|HDR|DV|DoVi|Dolby Vision)\b',
    caseSensitive: false,
  );
  static final _langRe = RegExp(
    r'\b(MULTI\.?(?:VFF|VFI|VFQ|VF2|VF)?|TrueFrench|VFF|VFI|VFQ|VOSTFR|VF2|VF)\b',
    caseSensitive: false,
  );
  static final _groupRe = RegExp(r'-([A-Za-z0-9_]+?)(?:\.\w{2,4})?$');

  /// Year of release, if found in the title.
  static final _yearRe = RegExp(r'(?<!\d)(19\d{2}|20\d{2})(?!\d)');

  factory ReleaseTags.parse(String title) {
    String? hit(RegExp re) => re.firstMatch(title)?.group(0);
    return ReleaseTags(
      language: hit(_langRe)?.toUpperCase(),
      resolution: hit(_resRe)?.toLowerCase(),
      source: _normalizeSource(hit(_sourceRe)),
      codec: _normalizeCodec(hit(_codecRe)),
      audio: _normalizeAudio(hit(_audioRe)),
      channels: hit(_channelsRe),
      hdr: _normalizeHdr(hit(_hdrRe)),
      group: _groupRe.firstMatch(title)?.group(1),
    );
  }

  static String? _normalizeSource(String? s) {
    if (s == null) return null;
    final u = s.toUpperCase().replaceAll('-', '');
    return switch (u) {
      'BLURAY' => 'BluRay',
      'BDRIP' || 'BRRIP' => 'BDRip',
      'BDMV' => 'BDMV',
      'REMUX' => 'Remux',
      'WEBDL' => 'WEB-DL',
      'WEBRIP' => 'WEBRip',
      'HDLIGHT' => 'HDLight',
      'HDRIP' => 'HDRip',
      'HDTV' => 'HDTV',
      'DVDRIP' => 'DVDRip',
      'ISO' => 'ISO',
      '4KLIGHT' => '4KLight',
      _ => s,
    };
  }

  static String? _normalizeCodec(String? s) {
    if (s == null) return null;
    final u = s.toUpperCase().replaceAll('.', '');
    return switch (u) {
      'X265' => 'x265',
      'X264' => 'x264',
      'H265' || 'HEVC' => 'H.265',
      'H264' => 'H.264',
      'AV1' => 'AV1',
      _ => s,
    };
  }

  static String? _normalizeAudio(String? s) {
    if (s == null) return null;
    final u = s.toUpperCase().replaceAll('-', '').replaceAll(' ', '');
    if (u.startsWith('DTSHD')) return 'DTS-HD';
    return switch (u) {
      'EAC3' => 'EAC3',
      'AC3' => 'AC3',
      'AAC' => 'AAC',
      'TRUEHD' => 'TrueHD',
      'ATMOS' => 'Atmos',
      'DTS' => 'DTS',
      'FLAC' => 'FLAC',
      'MP3' => 'MP3',
      'OPUS' => 'Opus',
      _ => s,
    };
  }

  static String? _normalizeHdr(String? s) {
    if (s == null) return null;
    final u = s.toUpperCase().replaceAll(' ', '');
    return switch (u) {
      'HDR10' => 'HDR10',
      'HDR10+' => 'HDR10+',
      'HDR' => 'HDR',
      'DV' || 'DOVI' || 'DOLBYVISION' => 'DV',
      'DV.HDR10' => 'DV.HDR10',
      _ => s,
    };
  }

  /// Tries to parse "Spider.Man.2.2004.MULTI..." → ("Spider Man 2", 2004).
  static ({String name, int? year}) cleanTitle(String raw) {
    final yearMatch = _yearRe.firstMatch(raw);
    final cutoff = yearMatch?.start ?? raw.length;
    var head = raw.substring(0, cutoff);
    head = head.replaceAll(RegExp(r'[._]+'), ' ').trim();
    head = head.replaceAll(RegExp(r'\s+'), ' ');
    return (
      name: head.isEmpty ? raw : head,
      year: yearMatch == null ? null : int.tryParse(yearMatch.group(1)!),
    );
  }
}
