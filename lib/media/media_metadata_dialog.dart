//
//  media_metadata_dialog.dart
//
//  The 媒体信息 dialog behind a viewer's menu entry: a compact table of the
//  message's media facts. Codec and frame rate are read from the downloaded
//  file in the background and slide in when the probe lands.
//

import 'dart:async';

import 'package:flutter/material.dart';

import '../components/app_dialog.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'media_metadata.dart';
import 'mp4_metadata_probe.dart';

/// Opens the metadata dialog for the media a viewer is showing.
Future<void> showMediaMetadataDialog(
  BuildContext context,
  MediaMetadata metadata,
) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppStrings.t(AppStringKeys.mediaMetadataTitle),
    barrierColor: Colors.black.withValues(alpha: 0.52),
    transitionDuration: AppMotion.duration(context, AppMotion.responsive),
    transitionBuilder: AppMotion.dialogTransition,
    pageBuilder: (dialogContext, _, _) =>
        MediaMetadataDialog(metadata: metadata),
  );
}

class MediaMetadataDialog extends StatefulWidget {
  const MediaMetadataDialog({super.key, required this.metadata});

  final MediaMetadata metadata;

  @override
  State<MediaMetadataDialog> createState() => _MediaMetadataDialogState();
}

class _MediaMetadataDialogState extends State<MediaMetadataDialog> {
  Mp4VideoTrack? _track;

  @override
  void initState() {
    super.initState();
    final path = widget.metadata.localPath;
    final isVideo = switch (widget.metadata.kind) {
      MediaMetadataKind.video ||
      MediaMetadataKind.animation ||
      MediaMetadataKind.videoNote => true,
      _ => false,
    };
    if (path == null || !isVideo) return;
    unawaited(
      probeMp4VideoTrack(path, cancelled: () => !mounted).then((track) {
        if (!mounted || track == null) return;
        setState(() => _track = track);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.metadata.entries(track: _track);
    return AppDialogSurface(
      title: AppStrings.t(AppStringKeys.mediaMetadataTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < entries.length; index++) ...[
            _MetadataRow(entry: entries[index]),
            if (index < entries.length - 1) const InsetDivider(leadingInset: 0),
          ],
        ],
      ),
      actions: [
        AppDialogAction(
          label: AppStrings.t(AppStringKeys.confirmOk),
          primary: true,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.entry});

  final MediaMetadataEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(
            AppStrings.t(entry.labelKey),
            style: AppTextStyle.footnote(c.textTertiary),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              entry.valueIsKey ? AppStrings.t(entry.value) : entry.value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote(c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
