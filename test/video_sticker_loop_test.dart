//
//  video_sticker_loop_test.dart
//
//  A video sticker must loop forever. FVP's MDK backend can ignore a
//  `setLooping` flag applied to an already-prepared WebM (wang-bin/fvp#394),
//  so the clip completes once and freezes on its last frame — in chats the
//  sticker then looks dead, and in the sticker panel it "plays too quickly"
//  (once through, then stops). The view replays completed stickers itself.
//

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/video_sticker_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
// Used only to install a deterministic fake for the public video_player API.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountSlot = 3;
  const fileId = 420042;
  const clipDuration = Duration(seconds: 2);
  late String stickerPath;
  late StreamController<Map<String, dynamic>> updates;
  late _FakeBackend backend;
  late _NonLoopingPlatform platform;
  late VideoPlayerPlatform previousPlatform;

  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('video-sticker-loop');
    stickerPath = '${dir.path}/sticker.webm';
    File(stickerPath).writeAsBytesSync(const [0x1A]);

    updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: accountSlot,
        query: (request) => backend.query(request),
        send: (request) async => backend.send(request),
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  setUp(() {
    backend = _FakeBackend(stickerPath);
    previousPlatform = VideoPlayerPlatform.instance;
    platform = _NonLoopingPlatform(clipDuration);
    VideoPlayerPlatform.instance = platform;
  });

  tearDown(() => VideoPlayerPlatform.instance = previousPlatform);

  Widget host() => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 140,
          height: 140,
          child: VideoStickerView(
            file: TdFileRef(id: fileId),
            fallback: TdFileRef(id: fileId + 1),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpUntilPlaying(WidgetTester tester) async {
    for (
      var attempt = 0;
      attempt < 100 && platform.playCalls.isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      platform.playCalls,
      hasLength(1),
      reason: 'the sticker never started playing',
    );
  }

  testWidgets(
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    'replays a completed sticker instead of freezing',
    (tester) async {
      await tester.pumpWidget(host());
      await pumpUntilPlaying(tester);
      expect(
        platform.setLoopingCalls,
        contains((1, true)),
        reason: 'the sticker must ask its backend for looping',
      );

      // The backend finished the clip instead of looping it: video_player
      // parks the value on the last frame (paused there) on its own, and the
      // sticker would sit frozen without the replay.
      platform.completeLastClip();
      await tester.pump();
      expect(platform.playCalls, hasLength(1));
      expect(platform.seekCalls, [clipDuration]);

      // Past the replay settle delay the view must rewind and play again.
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.seekCalls, [clipDuration, Duration.zero]);
      expect(platform.playCalls, hasLength(2));

      // And the next completion replays as well — the sticker loops forever.
      platform.completeLastClip();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.seekCalls, [
        clipDuration,
        Duration.zero,
        clipDuration,
        Duration.zero,
      ]);
      expect(platform.playCalls, hasLength(3));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    'a completion arriving right before dispose replays nothing',
    (tester) async {
      await tester.pumpWidget(host());
      await pumpUntilPlaying(tester);

      platform.completeLastClip();
      await tester.pump();
      // The replay is settled after a short delay; drop the surface before it.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.playCalls, hasLength(1));
    },
  );
}

class _FakeBackend {
  _FakeBackend(this.stickerPath);

  final String stickerPath;

  Future<Map<String, dynamic>> query(Map<String, dynamic> request) async {
    final type = request['@type'];
    if (type == 'getFile' || type == 'downloadFile') {
      return {
        '@type': 'file',
        'id': request['file_id'],
        'local': {
          'path': stickerPath,
          'is_downloading_active': false,
          'is_downloading_completed': true,
        },
      };
    }
    return {'@type': 'ok'};
  }

  Future<void> send(Map<String, dynamic> request) async {}
}

/// Models the fvp#394 backend: the loop flag is accepted but never honored —
/// a finished clip simply completes and holds its last frame. The test emits
/// the completion itself, like MDK does when the reader stops.
class _NonLoopingPlatform extends VideoPlayerPlatform {
  _NonLoopingPlatform(this.clipDuration);

  final Duration clipDuration;
  final Map<int, StreamController<VideoEvent>> _events = {};
  final List<int> playCalls = [];
  final List<int> pauseCalls = [];
  final List<Duration> seekCalls = [];
  final List<(int, bool)> setLoopingCalls = [];
  var _nextPlayerId = 1;
  int? _lastPlayerId;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    _lastPlayerId = playerId;
    _events[playerId] = StreamController<VideoEvent>.broadcast();
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    // The map owns this controller and dispose() closes it.
    // ignore: close_sinks
    final controller = _events[playerId]!;
    scheduleMicrotask(() {
      if (controller.isClosed) return;
      controller.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: clipDuration,
          size: const Size(512, 512),
        ),
      );
    });
    return controller.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls.add(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    setLoopingCalls.add((playerId, looping));
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCalls.add(position);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();

  void completeLastClip() {
    final playerId = _lastPlayerId;
    assert(playerId != null);
    _events[playerId]!.add(VideoEvent(eventType: VideoEventType.completed));
  }
}
