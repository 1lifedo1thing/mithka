import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/chat/music_player_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ThemeController theme;
  final player = MusicPlayerController.shared;
  final deepLinks = ChatDeepLinkController.shared;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    theme = ThemeController(await SharedPreferences.getInstance());
    deepLinks.consumePending();
    final track = ChatMessage(
      id: 101,
      isOutgoing: false,
      text: '',
      date: 1,
      chatId: 202,
      senderName: 'Chat source',
      music: MessageMusic(
        title: 'Chat track',
        performer: 'Artist',
        duration: 200,
        file: TdFileRef(id: 303),
      ),
    );
    player
      ..current = track
      ..queue = [track]
      ..hidden = false
      ..collapsed = false;
    player.seekFraction(0);
  });

  tearDown(() {
    deepLinks.consumePending();
    player
      ..current = null
      ..queue = const []
      ..hidden = true
      ..collapsed = false;
    theme.dispose();
  });

  Future<void> pumpBar(WidgetTester tester) {
    return tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                AnimatedBuilder(
                  animation: player,
                  builder: (context, _) => const GlobalMusicPlayerBar(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('dragging the progress line seeks instead of swiping the bar', (
    tester,
  ) async {
    await pumpBar(tester);
    final bar = find.byKey(musicPlayerProgressKey);
    final rect = tester.getRect(bar);

    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.1, rect.center.dy),
    );
    await gesture.moveBy(Offset(rect.width * 0.2, 0));
    await gesture.moveBy(Offset(rect.width * 0.45, 0));
    await tester.pump();
    // The preview follows the finger before release without seeking yet.
    expect(player.position, Duration.zero);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(player.position.inSeconds, closeTo(150, 2));
    expect(player.collapsed, isFalse);
    expect(player.current, isNotNull);
    expect(deepLinks.consumePending(), isNull);
  });

  testWidgets('tapping the progress line seeks to that point', (tester) async {
    await pumpBar(tester);
    final rect = tester.getRect(find.byKey(musicPlayerProgressKey));

    await tester.tapAt(Offset(rect.left + rect.width * 0.25, rect.center.dy));
    await tester.pump();

    expect(player.position.inSeconds, closeTo(50, 1));
    expect(deepLinks.consumePending(), isNull);
  });
}
