/// A time-limited presigned S3 URL the `<video>` element fetches directly.
class StreamLink {
  final String url;

  const StreamLink(this.url);

  factory StreamLink.fromJson(Map<String, dynamic> json) =>
      StreamLink(json['url'] as String? ?? '');

  Map<String, dynamic> toJson() => {'url': url};
}
