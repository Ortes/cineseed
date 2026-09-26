/// Live HLS from MKV files over HTTP Range (S3 presigned URLs) or local disk.
///
/// Give [HlsSessionManager] a [MediaSourceResolver] that maps your stream ids
/// to an [HttpMediaSource] or a [FileMediaSource]; video is stream-copied into
/// keyframe-exact fMP4 segments, only audio the browser can't decode is
/// transcoded.
library;

export 'src/hls_playlists.dart';
export 'src/hls_session.dart';
export 'src/local_range_server.dart';
export 'src/log.dart';
export 'src/media_source.dart';
export 'src/mkv_cues.dart';
export 'src/mp4_boxes.dart';
export 'src/probe.dart';
export 'src/producer_manager.dart';
export 'src/s3_range_proxy.dart';
export 'src/segment_producer.dart';
export 'src/segment_ref.dart';
export 'src/segments.dart';
export 'src/transcode_pool.dart';
