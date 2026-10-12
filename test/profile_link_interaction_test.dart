import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/chat/internal_chat_link_router.dart';
import 'package:mithka/chat/link_handler.dart';
import 'package:mithka/chat/telegram_rich_text.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/profile/profile_link.dart';
import 'package:mithka/profile/profile_username_pill.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  final requests = <Map<String, dynamic>>[];
  late Future<Map<String, dynamic>> Function() searchReply;
  late ThemeController theme;
  final deepLinks = ChatDeepLinkController.shared;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          return switch (request['@type']) {
            'getInternalLinkType' => {
              '@type': 'internalLinkTypePublicChat',
              'chat_username': 'mithka',
            },
            'searchPublicChat' => searchReply(),
            'getChat' => {
              '@type': 'chat',
              'id': 42,
              'title': 'Synthetic public chat',
            },
            _ => {'@type': 'ok'},
          };
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  setUp(() async {
    requests.clear();
    deepLinks.consumePending();
    searchReply = () => Future.error(StateError('synthetic lookup failure'));
    SharedPreferences.setMockInitialValues({
      'linkOpenMode.v1': LinkOpenMode.askEveryTime.name,
    });
    theme = ThemeController(await SharedPreferences.getInstance());
  });

  tearDown(() {
    theme.dispose();
    deepLinks.consumePending();
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  Widget host(
    Widget Function(BuildContext) child, {
    TargetPlatform platform = TargetPlatform.macOS,
    InternalChatLinkTarget? source,
  }) {
    Widget body = Builder(builder: child);
    if (source != null) {
      body = InternalChatLinkScope(target: source, child: body);
    }
    return ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [AppLocalizations.delegate],
        theme: ThemeData(platform: platform, extensions: [AppColors.light]),
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: body),
        ),
      ),
    );
  }

  testWidgets('pill tap returns the normalized username once', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      host(
        (_) => ProfileUsernamePill(username: '  @@mithka  ', onTap: tapped.add),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('profileUsernamePill')));
    expect(tapped, ['mithka']);
    expect(requests, isEmpty);
  });

  testWidgets('parent long press still copies without opening the pill', (
    tester,
  ) async {
    var taps = 0;
    var copies = 0;
    await tester.pumpWidget(
      host(
        (_) => GestureDetector(
          onLongPress: () => copies++,
          child: ProfileUsernamePill(username: 'mithka', onTap: (_) => taps++),
        ),
      ),
    );
    await tester.longPress(find.byKey(const ValueKey('profileUsernamePill')));
    expect(copies, 1);
    expect(taps, 0);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets(
      'failed public lookup presents the chooser on ${platform.name}',
      (tester) async {
        await tester.pumpWidget(
          host(
            (context) => ProfileUsernamePill(
              username: '@mithka',
              onTap: (username) =>
                  unawaited(openLink(context, 'https://t.me/$username')),
            ),
            platform: platform,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('profileUsernamePill')));
        await tester.pumpAndSettle();
        expect(requests.map((r) => r['@type']), [
          'getInternalLinkType',
          'searchPublicChat',
        ]);
        expect(
          find.byKey(const ValueKey('link-browser-chooser')),
          findsOneWidget,
        );
        expect(deepLinks.consumePending(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('successful lookup stays in app without browser fallback', (
    tester,
  ) async {
    searchReply = () async => {'@type': 'chat', 'id': 42};
    await tester.pumpWidget(
      host(
        (context) => ProfileUsernamePill(
          username: 'mithka',
          onTap: (username) =>
              unawaited(openLink(context, 'https://t.me/$username')),
        ),
        source: InternalChatLinkTarget(
          chatId: 17,
          accountSlot: 0,
          openMessage: (_) async {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('profileUsernamePill')));
    await tester.pumpAndSettle();
    expect(deepLinks.consumePending()?.chatId, 42);
    expect(find.byKey(const ValueKey('link-browser-chooser')), findsNothing);
  });

  testWidgets('lookup failure after unmount cannot show a fallback', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    searchReply = () => pending.future;
    await tester.pumpWidget(
      host(
        (context) => ProfileUsernamePill(
          username: 'mithka',
          onTap: (username) =>
              unawaited(openLink(context, 'https://t.me/$username')),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('profileUsernamePill')));
    await tester.pump();
    expect(requests.last['@type'], 'searchPublicChat');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('synthetic lookup failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(deepLinks.consumePending(), isNull);
  });

  testWidgets('a real bio glyph tap reaches fallback after load and rebuild', (
    tester,
  ) async {
    Widget bioHost(String text) =>
        host((_) => TelegramRichText(key: const ValueKey('bio'), text: text));
    await tester.pumpWidget(bioHost(''));
    const bio = 'read https://t.me/mithka first';
    await tester.pumpWidget(bioHost(bio));
    await tester.pumpWidget(bioHost(bio));
    await tester.pumpWidget(bioHost(bio));
    await tester.pump();
    final rich = find
        .descendant(
          of: find.byKey(const ValueKey('bio')),
          matching: find.byType(RichText),
        )
        .first;
    final paragraph = tester.renderObject<RenderParagraph>(rich);
    final start = bio.indexOf('https://');
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 19),
    );
    expect(boxes, isNotEmpty);
    await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
    await tester.pumpAndSettle();
    expect(requests.map((r) => r['@type']), [
      'getInternalLinkType',
      'searchPublicChat',
    ]);
    expect(find.byKey(const ValueKey('link-browser-chooser')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'canonical profile links normalize a username or use the numeric id',
    () {
      expect(
        profileLinkForIdentity(usernames: ['  @@mithka  '], userId: 7),
        'https://t.me/mithka',
      );
      expect(profileLinkForIdentity(userId: 7), 'tg://user?id=7');
      expect(profileLinkForIdentity(), isNull);
    },
  );
}
