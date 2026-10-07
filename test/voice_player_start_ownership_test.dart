import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_sound/flutter_sound.dart' show PlayerState;
// The fake native stack extends the platform interface's method-channel
// implementation; it is a transitive dependency of flutter_sound.
// ignore: depend_on_referenced_packages
import 'package:flutter_sound_platform_interface/flutter_sound_player_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_sound_platform_interface/method_channel_flutter_sound_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/voice_audio.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_image_loader.dart';
import 'package:mithka/tdlib/td_models.dart';

// Direct platform-transport coverage for the two lifecycle defects from
// review: a start that survives its own cancellation (stop/dispose during
// the audio-session await still reaches the native player), and a retired
// session's late finish callback finishing the replacement track.
//
// The transport fake is the same trick as voice_player_native_recovery_test:
// outbound verbs are answered inline, reverse callbacks are fired on the
// session callback object, and the app's FlutterSoundPlayer (operation
// lock, completers, state machine) runs for real. The audio-session await
// — the point where a stop or dispose races the start — is held open by
// audioSessionActivationOverride without touching any other behavior.

enum _Behavior { ok, silent, error }

class _FakeNative {
  final behaviors = <String, List<_Behavior>>{};
  final calls = <String>[];

  _Behavior nextBehavior(String method) {
    final nth = calls.where((c) => c == method).length + 1;
    final list = behaviors[method];
    if (list == null || list.isEmpty) return _Behavior.ok;
    return list[(nth - 1).clamp(0, list.length - 1)];
  }

  void plan(String method, List<_Behavior> list) => behaviors[method] = list;
}

class _NativeFailure implements Exception {
  _NativeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class _FakePlatform extends MethodChannelFlutterSoundPlayer {
  _FakePlatform(this.native);

  final _FakeNative native;

  /// The per-instance session callbacks, in the order the platform served
  /// them. `callbacks.first` is therefore the oldest (possibly retired)
  /// native session.
  final callbacks = <FlutterSoundPlayerCallback>{};

  @override
  void setCallback() {}

  @override
  Future<void>? resetPlugin(FlutterSoundPlayerCallback callback) async {}

  Future<Object?> _serve(
    FlutterSoundPlayerCallback callback,
    String method,
  ) async {
    final behavior = native.nextBehavior(method);
    callbacks.add(callback);
    native.calls.add(method);
    switch (behavior) {
      case _Behavior.error:
        throw _NativeFailure('native $method failed');
      case _Behavior.silent:
        if (method == 'stopPlayer') {
          callback.stopPlayerCompleted(PlayerState.isStopped.index, true);
        }
        return switch (method) {
          'startPlayer' => PlayerState.isPlaying.index,
          _ => PlayerState.isStopped.index,
        };
      case _Behavior.ok:
        switch (method) {
          case 'openPlayer':
            callback.openPlayerCompleted(PlayerState.isStopped.index, true);
            return PlayerState.isStopped.index;
          case 'startPlayer':
            callback.startPlayerCompleted(
              PlayerState.isPlaying.index,
              true,
              60000,
            );
            return PlayerState.isPlaying.index;
          case 'stopPlayer':
            callback.stopPlayerCompleted(PlayerState.isStopped.index, true);
            return PlayerState.isStopped.index;
          default:
            return PlayerState.isStopped.index;
        }
    }
  }

  @override
  Future<int> invokeMethod(
    FlutterSoundPlayerCallback callback,
    String methodName,
    Map<String, dynamic> call,
  ) async => (await _serve(callback, methodName)) as int;

  @override
  Future<Map> invokeMethodMap(
    FlutterSoundPlayerCallback callback,
    String methodName,
    Map<String, dynamic> call,
  ) async => <String, dynamic>{};
}

const testFileIds = [910001, 910002, 910003];

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountSlot = 42;
  late _FakeNative native;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: accountSlot,
        query: (request) async => switch (request['@type']) {
          'downloadFile' || 'getFile' => fileJson(request['file_id'] as int),
          _ => <String, dynamic>{'@type': 'ok'},
        },
        send: (_) async {},
        updates: const Stream<Never>.empty(),
      ),
    );
  });

  setUp(() {
    native = _FakeNative();
    FlutterSoundPlayerPlatform.instance = _FakePlatform(native);
    VoicePlayer.nativeCallTimeout = const Duration(milliseconds: 40);
    VoicePlayer.maxStartAttempts = 3;
    for (final id in testFileIds) {
      TdFileCenter.shared.rememberForTest(
        accountSlot,
        id,
        '/tmp/mithka-ownership-$id',
      );
    }
  });

  tearDown(() {
    FlutterSoundPlayerPlatform.instance = MethodChannelFlutterSoundPlayer();
    VoicePlayer.nativeCallTimeout = const Duration(seconds: 15);
    VoicePlayer.maxStartAttempts = 3;
  });

  TdFileRef file(int id) => TdFileRef(id: id);

  int count(String method) => native.calls.where((c) => c == method).length;

  group('ownership after output preparation', () {
    test(
      'a stop during the session await cancels the start before the native player',
      () async {
        final voice = VoicePlayer();
        addTearDown(voice.dispose);

        final holdActivation = Completer<AudioSession?>();
        voice.audioSessionActivationOverride = () => holdActivation.future;

        final load = voice.toggleAudio(file(910001));
        await until(() => count('openPlayer') == 1);

        await voice.stop(); // While the start still awaits the session.
        expect(
          voice.isActive(file(910001)),
          isFalse,
          reason: 'stop unbinds the stopped track',
        );
        holdActivation.complete(null); // The cancelled start resumes here.
        await load;

        expect(
          count('startPlayer'),
          0,
          reason: 'a start for a stopped track must not reach the player',
        );
        expect(voice.isPlaying, isFalse);
        expect(voice.isLoading, isFalse);
      },
    );

    test(
      'disposing during the session await does not start native playback',
      () async {
        final voice = VoicePlayer();

        final holdActivation = Completer<AudioSession?>();
        voice.audioSessionActivationOverride = () => holdActivation.future;

        final load = voice.toggleAudio(file(910002));
        await until(() => count('openPlayer') == 1);

        voice.dispose();
        holdActivation.complete(null);
        await load;

        expect(
          count('startPlayer'),
          0,
          reason: 'native playback must not start for a disposed player',
        );
      },
    );
  });

  test(
    'a retired session late finish callback must not finish the replacement track',
    () async {
      final voice = VoicePlayer();
      addTearDown(voice.dispose);

      // Track A: the native start never reports completion, the timeout
      // retires its session and the load fails.
      native.plan('startPlayer', [_Behavior.silent, _Behavior.ok]);

      final failures = <int>[];
      voice.onFailed = (fileId, error) => failures.add(fileId);
      unawaited(voice.toggleAudio(file(910001)));
      await until(
        () => failures.isNotEmpty,
        timeout: const Duration(seconds: 8),
      );

      // Track B plays on a fresh native session.
      await voice.toggleAudio(file(910002));
      expect(voice.isPlaying, isTrue, reason: 'track B must be playing');
      final finished = <int>[];
      voice.onFinished = finished.add;

      // The retired session's platform delivers its late finish callback.
      (FlutterSoundPlayerPlatform.instance as _FakePlatform).callbacks.first
          .audioPlayerFinished(PlayerState.isPlaying.index);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        voice.isPlaying,
        isTrue,
        reason: 'a retired session must not stop the replacement track',
      );
      expect(finished, isEmpty, reason: 'no onFinished for track B');
      expect(voice.isActive(file(910002)), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

Map<String, dynamic> fileJson(int fileId) => <String, dynamic>{
  '@type': 'file',
  'id': fileId,
  'size': 1024,
  'local': <String, dynamic>{
    '@type': 'localFile',
    'path': '/tmp/mithka-ownership-$fileId',
    'is_downloading_completed': true,
  },
};
