import 'dart:async';
import 'dart:convert';

import 'package:f_videoplayer/f_videoplayer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/video_window_telemetry.dart';
import 'package:mithka/media/video_playback_reporting.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:video_player/video_player.dart';

void main() {
  late List<SentryEvent> events;
  late VideoFailureReporter reporter;
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 9, 22);
    events = [];
    reporter = VideoFailureReporter(
      enabled: () => true,
      capture: (event) async => events.add(event),
      now: () => now,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  VideoPlaybackDiagnostics session({
    VideoPlaybackLocation location = VideoPlaybackLocation.player,
    String? mimeType = 'video/mp4',
  }) => VideoPlaybackDiagnostics(
    location: location,
    mimeType: mimeType,
    reporter: reporter,
  );

  test(
    'recovery is silent; only terminal failure contains safe attempt history',
    () {
      final diagnostics = session();
      diagnostics.beginAttempt(
        source: VideoPlaybackSource.loopback,
        viewType: VideoViewType.textureView,
      );
      diagnostics.recordFailure(
        FVideoPlayerError(
          'Translated label',
          cause: PlatformException(
            code: 'VideoError',
            message:
                'SurfaceProducer failed for http://127.0.0.1/video/PRIVATE.mp4',
            details: {'file': '/private/PRIVATE.mp4'},
          ),
        ),
        stage: VideoFailureStage.initialization,
      );
      diagnostics.beginAttempt(
        source: VideoPlaybackSource.file,
        viewType: VideoViewType.platformView,
      );
      diagnostics.initialized();
      expect(events, isEmpty);
      diagnostics.recordFailure(
        'MediaCodec decoder failed: errorCode=4003 video/hevc PRIVATE',
        stage: VideoFailureStage.playback,
      );
      diagnostics.reportTerminal(
        streamRecoveries: 1,
        completedFileFallback: true,
      );
      final event = events.single;
      expect(event.tags, containsPair('video.reason', 'decoder'));
      expect(event.tags, containsPair('video.platform', 'android'));
      expect(event.tags, containsPair('video.source', 'file'));
      expect(event.tags, containsPair('video.view_type', 'platformView'));
      expect(event.exceptions!.single.mechanism!.handled, isTrue);
      expect(event.contexts['video_playback'], {
        'schema_version': 1,
        'mime_type': 'video/mp4',
        'attempts': 2,
        'ever_initialized': true,
        'stream_recoveries': 1,
        'completed_file_fallback': true,
        'failures': [
          {
            'attempt': 1,
            'source': 'loopback',
            'view_type': 'textureView',
            'stage': 'initialization',
            'reason': 'surface',
          },
          {
            'attempt': 2,
            'source': 'file',
            'view_type': 'platformView',
            'stage': 'playback',
            'reason': 'decoder',
            'native_code': 4003,
            'codec_hint': 'hevc',
          },
        ],
      });
      expect(jsonEncode(event.toJson()), isNot(contains('PRIVATE')));
      expect(event.throwable, isNull);
    },
  );

  test(
    'one report per selection, even after manual retries and time passing',
    () {
      final diagnostics = session();
      diagnostics.reportTerminal();
      now = now.add(const Duration(hours: 2));
      diagnostics.beginAttempt(
        source: VideoPlaybackSource.file,
        viewType: VideoViewType.platformView,
      );
      diagnostics.recordFailure(
        'decoder error',
        stage: VideoFailureStage.playback,
      );
      diagnostics.reportTerminal();
      expect(events, hasLength(1));
      expect(events.single.tags!['video.reason'], 'sourceUnavailable');
    },
  );

  test(
    'deduplicates bursts across widgets but retains distinct failure kinds',
    () {
      session().reportTerminal();
      session().reportTerminal();
      session(location: VideoPlaybackLocation.sticker).reportTerminal();
      expect(events, hasLength(2));
      now = now.add(const Duration(minutes: 10));
      session().reportTerminal();
      expect(events, hasLength(3));
    },
  );

  test(
    'global rolling-hour cap bounds volume even with different signatures',
    () {
      for (final location in VideoPlaybackLocation.values) {
        for (final stage in VideoFailureStage.values) {
          session(location: location)
            ..recordFailure('decoder failure', stage: stage)
            ..reportTerminal();
        }
      }
      expect(events, hasLength(20));
      session().reportTerminal();
      expect(events, hasLength(20));
      now = now.add(const Duration(hours: 1));
      session().reportTerminal();
      expect(events, hasLength(21));
    },
  );

  test(
    'disabled telemetry and capture failures never escape into playback',
    () async {
      final disabled = VideoFailureReporter(
        enabled: () => false,
        capture: (event) async => events.add(event),
      );
      VideoPlaybackDiagnostics(
        location: VideoPlaybackLocation.player,
        reporter: disabled,
      ).reportTerminal();
      expect(events, isEmpty);
      final broken = VideoFailureReporter(
        enabled: () => true,
        capture: (_) => throw StateError('offline'),
      );
      VideoPlaybackDiagnostics(
        location: VideoPlaybackLocation.player,
        reporter: broken,
      ).reportTerminal();
      await Future<void>.value();
    },
  );

  test(
    'history is bounded and an unrecognized MIME type is never transmitted',
    () {
      final diagnostics = session(mimeType: 'video/PRIVATE-TITLE');
      for (var i = 0; i < 30; i++) {
        diagnostics.beginAttempt(
          source: VideoPlaybackSource.file,
          viewType: VideoViewType.textureView,
        );
        diagnostics.recordFailure(
          TimeoutException('PRIVATE'),
          stage: VideoFailureStage.initialization,
        );
      }
      diagnostics.reportTerminal();
      final context = events.single.contexts['video_playback'] as Map;
      expect(context['failures'], hasLength(6));
      expect(context['attempts'], 30);
      expect(context['mime_type'], 'unknown');
      expect(events.single.tags!['video.reason'], 'timeout');
      expect(jsonEncode(events.single.toJson()), isNot(contains('PRIVATE')));
    },
  );

  test(
    'beforeSend removes ambient private data but retains device diagnostics',
    () {
      session().reportTerminal();
      final event = events.single;
      final device = SentryDevice.fromJson({
        'name': 'PRIVATE',
        'id': 'PRIVATE',
        'model': 'A142',
        'manufacturer': 'Nothing',
        'arch': 'arm64',
        'low_memory': true,
      });
      event.contexts.device = device;
      event.contexts.operatingSystem = SentryOperatingSystem(
        name: 'Android',
        version: '14',
        rawDescription: 'PRIVATE',
        kernelVersion: 'PRIVATE',
      );
      final app = SentryApp.fromJson({
        'app_identifier': 'ad.neko.mithka',
        'app_version': '1.5.3',
        'app_memory': 123456,
        'device_app_hash': 'PRIVATE',
        'view_names': ['PRIVATE'],
        'future_sdk_field': 'PRIVATE',
      });
      event.contexts.app = app;
      event.contexts.runtimes = [
        SentryRuntime.fromJson({
          'name': 'Dart',
          'version': '3.12.2',
          'raw_description': 'PRIVATE',
          'future_sdk_field': 'PRIVATE',
        }),
      ];
      event.contexts.gpu = SentryGpu.fromJson({
        'name': 'Adreno',
        'api_type': 'OpenGL ES',
        'future_sdk_field': 'PRIVATE',
      });
      event.contexts['chat'] = {'title': 'PRIVATE'};
      event.release = 'mithka@1.5.3';
      event.tags!['git.commit'] = 'abc123';
      event.tags!['chat_id'] = 'PRIVATE';
      event.user = SentryUser(id: 'PRIVATE', email: 'PRIVATE');
      event.request = SentryRequest(url: 'https://PRIVATE/video.mp4');
      event.breadcrumbs = [Breadcrumb(message: 'PRIVATE')];
      event.transaction = '/chat/PRIVATE/video';
      event.serverName = 'PRIVATE';
      // ignore: deprecated_member_use
      event.extra = {'source': 'PRIVATE'};
      sanitizeVideoPlaybackEvent(event);
      expect(jsonEncode(event.toJson()), isNot(contains('PRIVATE')));
      expect(event.contexts.device!.model, 'A142');
      expect(event.contexts.device!.lowMemory, isTrue);
      expect(event.contexts.operatingSystem!.version, '14');
      expect(event.contexts.app!.version, '1.5.3');
      expect(event.contexts.app!.appMemory, 123456);
      expect(event.contexts.runtimes.single.version, '3.12.2');
      expect(event.contexts.gpu!.name, 'Adreno');
      expect(event.release, 'mithka@1.5.3');
      expect(event.tags!['git.commit'], 'abc123');
      expect(event.transaction, 'video.playback');
      expect(
        device.name,
        'PRIVATE',
        reason: 'Do not mutate shared SDK context',
      );
      expect(app.deviceAppHash, 'PRIVATE');
      expect(app.viewNames, ['PRIVATE']);
    },
  );

  test('privacy filter leaves unrelated Sentry events unchanged', () {
    final event = SentryEvent(
      logger: 'other',
      transaction: 'original',
      breadcrumbs: [Breadcrumb(message: 'original')],
    );
    expect(sanitizeVideoPlaybackEvent(event), same(event));
    expect(event.breadcrumbs!.single.message, 'original');
    expect(event.transaction, 'original');
  });

  test('a URL query or platform details cannot become a native error code', () {
    session()
      ..recordFailure(
        PlatformException(
          code: 'VideoError',
          message: 'Decoder failed https://private.invalid/file?code=123456',
          details: 'errorCode=987654',
        ),
        stage: VideoFailureStage.initialization,
      )
      ..reportTerminal();
    final failure =
        events.single.contexts['video_playback']['failures'].single as Map;
    expect(failure.containsKey('native_code'), isFalse);
    expect(
      jsonEncode(events.single.toJson()),
      isNot(contains('private.invalid')),
    );
  });

  test(
    'detached hub leaves native scope and tracing owned by the main window',
    () async {
      final options = SentryFlutterOptions();
      configureVideoWindowTelemetry(options);
      expect(options.autoInitializeNativeSdk, isFalse);
      expect(options.enableScopeSync, isFalse);
      expect(options.enableNativeTraceSync, isFalse);
      expect(options.enableFramesTracking, isFalse);
      expect(options.enableAutoSessionTracking, isFalse);
      expect(options.enableAutoPerformanceTracing, isFalse);
      expect(options.tracesSampleRate, isNull);
      expect(options.tracesSampler, isNull);
      expect(options.sendDefaultPii, isFalse);
      expect(options.maxBreadcrumbs, 0);
      expect(await options.beforeSend!(SentryEvent(), Hint()), isNull);
      session(location: VideoPlaybackLocation.desktopWindow).reportTerminal();
      expect(await options.beforeSend!(events.single, Hint()), isNotNull);
    },
  );
}
