//
//  media_metadata.dart
//
//  What a viewer can say about the file it is showing. Size, resolution,
//  duration and MIME come from the TDLib message; codec and frame rate are
//  probed from the downloaded file by the sheet itself (mp4_metadata_probe).
//

import '../l10n/app_localizations.dart';
import '../tdlib/td_models.dart';
import 'mp4_metadata_probe.dart';

/// The kind a metadata sheet names first.
enum MediaMetadataKind {
  photo,
  video,
  animation,
  videoNote,
  voice,
  audio,
  sticker,
  document,
  other;

  /// Localization key for the kind's display name.
  String get labelKey => switch (this) {
    MediaMetadataKind.photo => AppStringKeys.downloadsMediaPhoto,
    MediaMetadataKind.video => AppStringKeys.downloadsMediaVideo,
    MediaMetadataKind.animation => AppStringKeys.downloadsMediaAnimation,
    MediaMetadataKind.videoNote => AppStringKeys.downloadsMediaVideoMessage,
    MediaMetadataKind.voice => AppStringKeys.downloadsMediaVoiceMessage,
    MediaMetadataKind.audio => AppStringKeys.composerAudio,
    MediaMetadataKind.sticker => AppStringKeys.tdMessageSticker,
    MediaMetadataKind.document => AppStringKeys.topicPostContentFile,
    MediaMetadataKind.other => AppStringKeys.downloadsMediaTelegramMedia,
  };
}

/// One row of the sheet: a localization key for the label and the value as
/// text. A kind row sets [valueIsKey] so the UI localizes it too.
class MediaMetadataEntry {
  const MediaMetadataEntry(
    this.labelKey,
    this.value, {
    this.valueIsKey = false,
  });

  final String labelKey;
  final String value;
  final bool valueIsKey;
}

/// The media facts behind one gallery item or video, already flattened.
class MediaMetadata {
  const MediaMetadata({
    required this.kind,
    this.fileName,
    this.mimeType,
    this.width,
    this.height,
    this.durationSeconds,
    this.sizeBytes,
    this.localPath,
  });

  final MediaMetadataKind kind;
  final String? fileName;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? durationSeconds;
  final int? sizeBytes;

  /// Non-null only when the whole file is on disk (TDLib reports `local.path`
  /// once `is_downloading_completed`), so the codec/frame-rate probe never reads
  /// a partial download or a player's stream URI. [MediaMetadata.fromVideoFile]
  /// is what enforces that for the player.
  final String? localPath;

  factory MediaMetadata.fromMessage(ChatMessage message) {
    final video = message.video;
    final voice = message.voice;
    final music = message.music;
    final document = message.document;
    switch (message.contentType ?? '') {
      case 'messagePhoto':
        final image = message.image;
        return MediaMetadata(
          kind: MediaMetadataKind.photo,
          width: message.imageWidth,
          height: message.imageHeight,
          sizeBytes: image?.size,
          mimeType: image?.mimeType,
          localPath: image?.localPath,
        );
      case 'messageVideo' || 'messageAnimation' || 'messageVideoNote':
        final isAnimation = message.contentType == 'messageAnimation';
        final isVideoNote = message.contentType == 'messageVideoNote';
        return MediaMetadata(
          kind: isAnimation
              ? MediaMetadataKind.animation
              : isVideoNote
              ? MediaMetadataKind.videoNote
              : MediaMetadataKind.video,
          width: message.imageWidth,
          height: message.imageHeight,
          durationSeconds: message.videoDuration,
          sizeBytes: video?.size ?? message.videoFileSize,
          fileName: video?.fileName,
          mimeType: video?.mimeType,
          localPath: video?.localPath,
        );
      case 'messageVoiceNote':
        return MediaMetadata(
          kind: MediaMetadataKind.voice,
          durationSeconds: voice?.duration,
          sizeBytes: voice?.file?.size,
          fileName: voice?.file?.fileName,
          mimeType: voice?.file?.mimeType,
          localPath: voice?.file?.localPath,
        );
      case 'messageAudio':
        return MediaMetadata(
          kind: MediaMetadataKind.audio,
          durationSeconds: music == null
              ? null
              : (music.duration > 0 ? music.duration : null),
          sizeBytes: music?.file?.size,
          fileName: music?.file?.fileName,
          mimeType: music?.file?.mimeType,
          localPath: music?.file?.localPath,
        );
      case 'messageSticker':
        final sticker = message.animatedSticker ?? message.videoSticker;
        return MediaMetadata(
          kind: MediaMetadataKind.sticker,
          width: message.imageWidth,
          height: message.imageHeight,
          sizeBytes: sticker?.size ?? message.image?.size,
          mimeType: sticker?.mimeType ?? message.image?.mimeType,
          localPath: sticker?.localPath ?? message.image?.localPath,
        );
      case 'messageDocument':
        return MediaMetadata(
          kind: MediaMetadataKind.document,
          sizeBytes: document?.file?.size ?? document?.size,
          fileName: document?.fileName,
          mimeType: document?.file?.mimeType,
          localPath: document?.file?.localPath,
        );
      default:
        return const MediaMetadata(kind: MediaMetadataKind.other);
    }
  }

  /// The viewer's metadata for a video playback item. The player's queue only
  /// keeps the file and its dimensions, so the kind is always video — an
  /// animation that opens the player reads the same from its message.
  ///
  /// A player keeps its loopback stream URI in the same field as a local path,
  /// so it says which one it holds: [playerOpenedLocalFile] is true only once it
  /// has a completed file on disk, and only then does [playerPath] become the
  /// path to probe. Otherwise [TdFileRef.localPath] decides, which TDLib sets on
  /// completion alone — a streaming or half-downloaded video contributes
  /// nothing, and the codec row simply stays out.
  factory MediaMetadata.fromVideoFile(
    TdFileRef video, {
    int? width,
    int? height,
    int? durationSeconds,
    String? playerPath,
    bool playerOpenedLocalFile = false,
  }) {
    return MediaMetadata(
      kind: MediaMetadataKind.video,
      width: width,
      height: height,
      durationSeconds: durationSeconds,
      sizeBytes: video.size,
      fileName: video.fileName,
      mimeType: video.mimeType,
      localPath: playerOpenedLocalFile ? playerPath : video.localPath,
    );
  }

  /// The rows to show, in order. Labels are localization keys; [track] carries
  /// what the file probe read (null while it runs or when it finds nothing).
  List<MediaMetadataEntry> entries({Mp4VideoTrack? track}) {
    final entries = <MediaMetadataEntry>[
      MediaMetadataEntry(
        AppStringKeys.mediaMetadataType,
        kind.labelKey,
        valueIsKey: true,
      ),
    ];
    final fileName = this.fileName;
    if (fileName != null && fileName.isNotEmpty) {
      entries.add(
        MediaMetadataEntry(AppStringKeys.mediaMetadataName, fileName),
      );
    }
    final width = this.width;
    final height = this.height;
    if (width != null && height != null && width > 0 && height > 0) {
      entries.add(
        MediaMetadataEntry(
          AppStringKeys.mediaMetadataResolution,
          '$width × $height',
        ),
      );
    }
    final duration = durationSeconds;
    if (duration != null && duration > 0) {
      entries.add(
        MediaMetadataEntry(
          AppStringKeys.mediaMetadataDuration,
          formatMediaDuration(duration),
        ),
      );
    }
    final size = sizeBytes;
    if (size != null && size > 0) {
      entries.add(
        MediaMetadataEntry(
          AppStringKeys.mediaMetadataSize,
          formatMediaByteSize(size),
        ),
      );
    }
    final frameRate = track?.frameRate;
    if (frameRate != null && frameRate > 0) {
      entries.add(
        MediaMetadataEntry(
          AppStringKeys.mediaMetadataFrameRate,
          '${frameRate.toStringAsFixed(1)} fps',
        ),
      );
    }
    if (size != null && size > 0 && duration != null && duration > 0) {
      entries.add(
        MediaMetadataEntry(
          AppStringKeys.mediaMetadataBitrate,
          formatMediaBitrate(size * 8.0 / duration),
        ),
      );
    }
    final codec = track?.codec;
    if (codec != null && codec.isNotEmpty) {
      entries.add(MediaMetadataEntry(AppStringKeys.mediaMetadataCodec, codec));
    }
    final mimeType = this.mimeType;
    if (mimeType != null && mimeType.isNotEmpty) {
      entries.add(
        MediaMetadataEntry(AppStringKeys.mediaMetadataMime, mimeType),
      );
    }
    return entries;
  }

  /// Metadata for a gallery's messages, or an empty list when the reader
  /// turned the metadata row off.
  static List<MediaMetadata?> listFor(
    Iterable<ChatMessage> messages, {
    required bool enabled,
  }) {
    if (!enabled) return const [];
    return [for (final message in messages) MediaMetadata.fromMessage(message)];
  }
}

/// B/KB/MB/…, one decimal, the same scale the storage views use.
String formatMediaByteSize(int bytes) {
  final clamped = bytes < 0 ? 0 : bytes;
  if (clamped < 1024) return '$clamped B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = clamped.toDouble();
  var index = -1;
  do {
    size /= 1024;
    index++;
  } while (size >= 1024 && index < units.length - 1);
  return '${size.toStringAsFixed(1)} ${units[index]}';
}

/// `m:ss` below an hour, `h:mm:ss` above it.
String formatMediaDuration(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final rest = total % 60;
  final paddedMinutes = minutes.toString().padLeft(2, '0');
  final paddedSeconds = rest.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:$paddedMinutes:$paddedSeconds'
      : '$minutes:$paddedSeconds';
}

/// Whole Kbps below a megabit, two-decimal Mbps above it.
String formatMediaBitrate(double bitsPerSecond) {
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
  }
  if (bitsPerSecond >= 1000) {
    return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
  }
  final clamped = bitsPerSecond < 0 ? 0.0 : bitsPerSecond;
  return '${clamped.toStringAsFixed(0)} bps';
}
