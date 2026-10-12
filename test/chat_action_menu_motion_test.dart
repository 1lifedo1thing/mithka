import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view.dart'
    show ChatView, clearChatMemoryCaches;
import 'package:mithka/chat/emoji_store.dart';
import 'package:mithka/chat/message_action_menu_presentation.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

/// The long-press action overlay's motion, end to end: the HUD fades and
/// scales in out of the pressed message, and the same motion plays in reverse
/// on the way out instead of the surfaces vanishing on the dismissal frame.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  L10nFixtures.load().install();

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getChat' => {
            '@type': 'chat',
            'id': 42,
            'title': 'Motion test',
            'type': {'@type': 'chatTypePrivate', 'user_id': 2},
            'last_read_inbox_message_id': 78,
            'unread_count': 0,
            'permissions': {'can_send_basic_messages': true},
          },
          'getUser' || 'getMe' => {
            '@type': 'user',
            'id': request['user_id'] ?? 1,
            'first_name': 'Test',
            'type': {'@type': 'userTypeRegular'},
          },
          'getChatHistory' => {
            '@type': 'messages',
            'total_count': 1,
            'messages': [
              {
                '@type': 'message',
                'id': 78,
                'chat_id': 42,
                'date': 1785862260,
                'sender_id': {'@type': 'messageSenderUser', 'user_id': 2},
                'content': {
                  '@type': 'messageText',
                  'text': {
                    '@type': 'formattedText',
                    'text': 'long press me',
                    'entities': [],
                  },
                },
              },
            ],
          },
          'getMessageAvailableReactions' => {
            '@type': 'availableReactions',
            'top_reactions': [
              {
                '@type': 'availableReaction',
                'type': {'@type': 'reactionTypeEmoji', 'emoji': '👍'},
                'needs_premium': false,
              },
            ],
            'recent_reactions': <Map<String, dynamic>>[],
            'popular_reactions': <Map<String, dynamic>>[],
            'allow_custom_emoji': false,
            'are_tags': false,
            'unavailability_reason': null,
          },
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  late ThemeController theme;
  late TranslationController translation;

  setUp(() async {
    clearChatMemoryCaches();
    SharedPreferences.setMockInitialValues({'openChatsAtLatest': true});
    final preferences = await SharedPreferences.getInstance();
    theme = ThemeController(preferences);
    translation = TranslationController(preferences);
    AppStrings.setLocale(const Locale('en'));
  });
  tearDown(() {
    theme.dispose();
    translation.dispose();
  });

  Widget app() => MultiProvider(
    providers: [
      ChangeNotifierProvider<ThemeController>.value(value: theme),
      ChangeNotifierProvider<TranslationController>.value(value: translation),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      locale: const Locale('en'),
      localizationsDelegates: const [AppLocalizations.delegate],
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ChatView(chatId: 42, title: 'Motion test'),
    ),
  );

  final presentation = find.byKey(MessageActionMenuPresentation.rootKey);
  final menuSurface = find.byKey(const ValueKey('message-action-menu-surface'));
  final dismissLayer = find.byKey(
    const ValueKey('message-action-dismiss-layer'),
  );

  double opacityOf(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.descendant(
          of: presentation,
          matching: find.byType(FadeTransition),
        ),
      )
      .opacity
      .value;

  final messageText = find.text('long press me', findRichText: true);

  testWidgets('the action overlay animates in and back out', (tester) async {
    await tester.pumpWidget(app());
    for (
      var frame = 0;
      frame < 40 && messageText.hitTestable().evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(messageText, findsOneWidget);
    await tester.pumpAndSettle();
    expect(presentation, findsNothing);

    await tester.longPress(messageText);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(presentation, findsOneWidget);
    expect(menuSurface, findsOneWidget);
    // Mid-entrance: the HUD is arriving, not yet settled.
    expect(opacityOf(tester), greaterThan(0));
    expect(opacityOf(tester), lessThan(1));

    await tester.pumpAndSettle();
    expect(opacityOf(tester), 1);

    await tester.tap(dismissLayer);
    // One frame to let the dismiss setState land, then part-way into the
    // reverse: the closing overlay replays its snapshot through the exit
    // instead of unmounting on the dismissal frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(presentation, findsOneWidget);
    expect(menuSurface, findsOneWidget);
    expect(opacityOf(tester), lessThan(1));

    await tester.pumpAndSettle();
    expect(presentation, findsNothing);
    expect(menuSurface, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing expanded reactions survives an emoji-store update', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.longPress(messageText);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-reaction-expand')));
    await tester.pumpAndSettle();
    final expanded = find.byKey(const ValueKey('expanded-reaction-emoji:👍'));
    expect(expanded, findsOneWidget);
    await tester.tapAt(
      tester.getRect(dismissLayer).bottomLeft + const Offset(4, -4),
    );
    await tester.pump();
    expect(expanded, findsOneWidget);
    // Simulate emoji-pack metadata arriving during the closing transition.
    // ignore: invalid_use_of_protected_member
    EmojiStore.shared.notifyListeners();
    await tester.pump(const Duration(milliseconds: 30));
    expect(expanded, findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a reaction tap closes through the same exit', (tester) async {
    await tester.pumpWidget(app());
    for (
      var frame = 0;
      frame < 40 && messageText.hitTestable().evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(messageText, findsOneWidget);
    await tester.pumpAndSettle();

    await tester.longPress(messageText);
    await tester.pumpAndSettle();
    final quickBar = find.byKey(const ValueKey('quick-reaction-bar'));
    expect(quickBar, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-reaction-emoji:👍')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Both surfaces stay mounted through the reverse; the bar is replayed
    // from the snapshot even though the live target is already cleared.
    expect(presentation, findsOneWidget);
    expect(quickBar, findsOneWidget);
    expect(opacityOf(tester), lessThan(1));

    await tester.pumpAndSettle();
    expect(presentation, findsNothing);
    expect(quickBar, findsNothing);
  });
}
