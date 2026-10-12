import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/full_image_viewer.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/media/media_metadata.dart';
import 'package:mithka/media/media_metadata_dialog.dart';
import 'package:mithka/media/mp4_metadata_probe.dart';
import 'package:mithka/settings/general_settings_view.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mp4_fixtures.dart';

ChatMessage _message({
  required String contentType,
  String? text,
  TdFileRef? image,
  TdFileRef? video,
  int? width,
  int? height,
  int? duration,
  int? size,
}) {
  return ChatMessage(
    id: 1,
    isOutgoing: false,
    date: 1,
    text: text ?? '',
    contentType: contentType,
    image: image,
    imageWidth: width,
    imageHeight: height,
    video: video,
    videoDuration: duration,
    videoFileSize: size,
  );
}

/// The rows a metadata sheet would show, keyed by their label.
Map<String, String> _rows(MediaMetadata metadata, {Mp4VideoTrack? track}) => {
  for (final entry in metadata.entries(track: track))
    entry.labelKey: entry.value,
};

Future<ThemeController> _pump(
  WidgetTester tester,
  Widget home, {
  Map<String, Object> preferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: Brightness.light,
          extensions: [AppColors.light],
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
  return theme;
}

/// A real 1x1 PNG on disk, so the viewer has something to decode.
File _writeImage() {
  final directory = Directory.systemTemp.createTempSync(
    'mithka-media-metadata-test-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  return File('${directory.path}/photo.png')..writeAsBytesSync(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42uNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );
}

/// Opens the metadata sheet on tap, so a test can drive the dialog without a
/// whole viewer around it.
class _MetadataSheetButton extends StatelessWidget {
  const _MetadataSheetButton({required this.metadata});

  final MediaMetadata metadata;

  @override
  Widget build(BuildContext context) => Center(
    child: GestureDetector(
      onTap: () => unawaited(showMediaMetadataDialog(context, metadata)),
      child: const Text('open sheet'),
    ),
  );
}

void main() {
  test('a photo carries its resolution, size and mime', () {
    final metadata = MediaMetadata.fromMessage(
      _message(
        contentType: 'messagePhoto',
        width: 1280,
        height: 1920,
        image: TdFileRef(id: 5, size: 4096, mimeType: 'image/jpeg'),
      ),
    );

    final rows = _rows(metadata);
    expect(
      rows[AppStringKeys.mediaMetadataType],
      AppStringKeys.downloadsMediaPhoto,
    );
    expect(rows[AppStringKeys.mediaMetadataResolution], '1280 × 1920');
    expect(rows[AppStringKeys.mediaMetadataSize], '4.0 KB');
    expect(rows[AppStringKeys.mediaMetadataMime], 'image/jpeg');
    // A photo has no track to probe, so the codec row stays out.
    expect(rows.containsKey(AppStringKeys.mediaMetadataCodec), isFalse);
    expect(rows.containsKey(AppStringKeys.mediaMetadataFrameRate), isFalse);
  });

  test('a video takes the codec and frame rate from the file probe', () {
    final metadata = MediaMetadata.fromMessage(
      _message(
        contentType: 'messageVideo',
        width: 1920,
        height: 1080,
        duration: 10,
        size: 1250000,
        video: TdFileRef(
          id: 6,
          size: 1250000,
          fileName: 'clip.mp4',
          mimeType: 'video/mp4',
        ),
      ),
    );

    final rows = _rows(
      metadata,
      track: const Mp4VideoTrack(codec: 'HEVC', frameRate: 23.976),
    );
    expect(
      rows[AppStringKeys.mediaMetadataType],
      AppStringKeys.downloadsMediaVideo,
    );
    expect(rows[AppStringKeys.mediaMetadataName], 'clip.mp4');
    expect(rows[AppStringKeys.mediaMetadataResolution], '1920 × 1080');
    expect(rows[AppStringKeys.mediaMetadataDuration], '0:10');
    expect(rows[AppStringKeys.mediaMetadataSize], '1.2 MB');
    expect(rows[AppStringKeys.mediaMetadataCodec], 'HEVC');
    expect(rows[AppStringKeys.mediaMetadataFrameRate], '24.0 fps');
    expect(rows[AppStringKeys.mediaMetadataBitrate], '1.00 Mbps');
  });

  test('without a probe only the codec and frame rate rows are missing', () {
    final metadata = MediaMetadata.fromMessage(
      _message(
        contentType: 'messageVideo',
        width: 640,
        height: 360,
        duration: 5,
        size: 500,
      ),
    );

    final rows = _rows(metadata);
    expect(rows.containsKey(AppStringKeys.mediaMetadataCodec), isFalse);
    expect(rows.containsKey(AppStringKeys.mediaMetadataFrameRate), isFalse);
    // Bitrate comes from TDLib's own size and duration, not from the file.
    expect(rows[AppStringKeys.mediaMetadataBitrate], '800 bps');
  });

  test('empty or unknown media still names its kind', () {
    final rows = _rows(
      MediaMetadata.fromMessage(
        _message(contentType: 'messageText', text: 'hi'),
      ),
    );
    expect(
      rows[AppStringKeys.mediaMetadataType],
      AppStringKeys.downloadsMediaTelegramMedia,
    );
    expect(rows.length, 1);
  });

  test('a player item reads what the player already holds', () {
    final metadata = MediaMetadata.fromVideoFile(
      TdFileRef(id: 9, size: 2048, fileName: 'clip.mp4', mimeType: 'video/mp4'),
      width: 720,
      height: 1280,
      durationSeconds: 4,
      playerPath: '/tmp/clip.mp4',
      playerOpenedLocalFile: true,
    );

    final rows = _rows(metadata);
    expect(
      rows[AppStringKeys.mediaMetadataType],
      AppStringKeys.downloadsMediaVideo,
    );
    expect(rows[AppStringKeys.mediaMetadataName], 'clip.mp4');
    expect(rows[AppStringKeys.mediaMetadataResolution], '720 × 1280');
    expect(rows[AppStringKeys.mediaMetadataDuration], '0:04');
    expect(rows[AppStringKeys.mediaMetadataSize], '2.0 KB');
    expect(rows[AppStringKeys.mediaMetadataMime], 'video/mp4');
    // The probe only runs on a file that is wholly on disk.
    expect(metadata.localPath, '/tmp/clip.mp4');
  });

  test('a streaming player hands the probe nothing', () {
    // The player keeps its loopback URI in the same field as a local path. A
    // probe fed that would open a file named after a URL.
    final streaming = MediaMetadata.fromVideoFile(
      TdFileRef(id: 9),
      playerPath: 'http://127.0.0.1:43210/clip.mp4',
    );
    expect(streaming.localPath, isNull);

    // TDLib's own path is the fallback, and it is set on completion alone.
    final downloaded = MediaMetadata.fromVideoFile(
      TdFileRef(id: 9, localPath: '/tmp/clip.mp4'),
      playerPath: 'http://127.0.0.1:43210/clip.mp4',
    );
    expect(downloaded.localPath, '/tmp/clip.mp4');
  });

  test('listFor respects the preference', () {
    final messages = [
      _message(contentType: 'messagePhoto', width: 1, height: 1),
    ];
    expect(MediaMetadata.listFor(messages, enabled: false), isEmpty);
    expect(MediaMetadata.listFor(messages, enabled: true), hasLength(1));
  });

  test('formatting helpers', () {
    expect(formatMediaByteSize(512), '512 B');
    expect(formatMediaByteSize(1536), '1.5 KB');
    expect(formatMediaByteSize(5 * 1024 * 1024), '5.0 MB');
    expect(formatMediaDuration(59), '0:59');
    expect(formatMediaDuration(60), '1:00');
    expect(formatMediaDuration(3671), '1:01:11');
    expect(formatMediaBitrate(900), '900 bps');
    expect(formatMediaBitrate(1200), '1 Kbps');
    expect(formatMediaBitrate(1234567), '1.23 Mbps');
  });

  testWidgets(
    'the viewer menu offers the sheet and the sheet renders the facts',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final image = _writeImage();
      final item = TdFileRef(
        id: 7,
        localPath: image.path,
        size: 4096,
        mimeType: 'image/jpeg',
      );

      await _pump(
        tester,
        FullImageViewer(
          items: [item],
          metadata: [
            MediaMetadata.fromMessage(
              _message(
                contentType: 'messagePhoto',
                width: 1280,
                height: 1920,
                image: item,
              ),
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(const ValueKey('image-viewer-more')));
      await tester.pump(const Duration(milliseconds: 50));
      final action = find.byKey(const ValueKey('image-viewer-action-metadata'));
      expect(action, findsOneWidget);

      await tester.tap(action);
      // The viewer never goes quiet (its chrome animates), so drive the dialog
      // transition by hand instead of waiting for a settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MediaMetadataDialog), findsOneWidget);
      expect(find.text('1280 × 1920'), findsOneWidget);
      expect(find.text('4.0 KB'), findsOneWidget);
      expect(find.text('image/jpeg'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a gallery without facts keeps the metadata row out of the menu',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final image = _writeImage();

      await _pump(
        tester,
        FullImageViewer(items: [TdFileRef(id: 8, localPath: image.path)]),
      );

      await tester.tap(find.byKey(const ValueKey('image-viewer-more')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey('image-viewer-actions-menu')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('image-viewer-action-metadata')),
        findsNothing,
      );

      debugDefaultTargetPlatformOverride = null;
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('a half-written file gives the sheet no codec row', (
    tester,
  ) async {
    // What a partial download looks like: a moov whose declared size runs past
    // the bytes that arrived. The probe must fail closed on it rather than read
    // whatever follows.
    final whole = isoConcat([
      isoBox('ftyp', [...'isom'.codeUnits, ...isoU32(0)]),
      isoBox('moov', List<int>.filled(96, 0)),
    ]);
    final path = writeTempMediaFileSync(
      whole.sublist(0, whole.length - 64),
      name: 'partial.mp4',
    );

    await _pump(
      tester,
      Builder(
        builder: (context) => _MetadataSheetButton(
          metadata: MediaMetadata(
            kind: MediaMetadataKind.video,
            localPath: path,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(_MetadataSheetButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MediaMetadataDialog), findsOneWidget);
    // The probe reads a real file, which only progresses on the real event
    // loop; it finds nothing to report.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final codecLabel = AppStrings.t(AppStringKeys.mediaMetadataCodec);
    expect(find.text(codecLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dismissed sheet ignores the probe that lands after it', (
    tester,
  ) async {
    // A moov that is a wall of filler, so the walk is still running when the
    // sheet goes away.
    final hostile = writeTempMediaFileSync(
      isoConcat([
        isoBox('ftyp', [...'isom'.codeUnits, ...isoU32(0)]),
        isoBox(
          'moov',
          isoConcat([
            for (var index = 0; index < 2048; index++) isoBox('free', const []),
          ]),
        ),
      ]),
      name: 'hostile.mp4',
    );

    await _pump(
      tester,
      Builder(
        builder: (context) => _MetadataSheetButton(
          metadata: MediaMetadata(
            kind: MediaMetadataKind.video,
            localPath: hostile,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(_MetadataSheetButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MediaMetadataDialog), findsOneWidget);

    // Dismiss while the traversal is in flight.
    Navigator.of(tester.element(find.byType(MediaMetadataDialog))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MediaMetadataDialog), findsNothing);

    // Now let it land: the state is gone, so a setState would throw.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(debugMp4ProbeReadCount, lessThan(600));
  });

  testWidgets('the settings switch flips the stored preference', (
    tester,
  ) async {
    final theme = await _pump(tester, const ChatBehaviorSettingsView());
    expect(theme.mediaMetadataEnabled, isTrue);

    final row = find.byKey(const ValueKey('chat-behavior-media-metadata'));
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await tester.pump();

    expect(theme.mediaMetadataEnabled, isFalse);
    final stored = await SharedPreferences.getInstance();
    expect(stored.getBool('mediaMetadataEnabled'), isFalse);

    // A later surface reads the same stored choice back.
    final restored = ThemeController(stored);
    addTearDown(restored.dispose);
    expect(restored.mediaMetadataEnabled, isFalse);
  });
}
