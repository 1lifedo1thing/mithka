import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  setUpAll(() {
    // Exercise the real folder UI without accessing a Telegram account.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets(
    'rail highlight follows the chat-list slide before it lands',
    (tester) async {
      await _pumpFolders(tester, updates);
      expect(_highlight(tester, null), closeTo(0.1, 0.001));
      expect(_highlight(tester, 1), 0);

      await tester.tap(find.byKey(const ValueKey('side-folder-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      final panes = tester.widget<ChatListFolderPanes>(
        find.byType(ChatListFolderPanes),
      );
      final progress = panes.offset.value.abs() / panes.width;
      expect(progress, allOf(greaterThan(0), lessThan(1)));
      expect(panes.peek, isNotNull);
      expect(_highlight(tester, 1), closeTo(0.1 * progress, 0.001));
      expect(_highlight(tester, null), closeTo(0.1 * (1 - progress), 0.001));

      // Interrupt the first slide: the next target must animate immediately too.
      await tester.tap(find.byKey(const ValueKey('side-folder-2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(_highlight(tester, 2), greaterThan(0));
      expect(_highlight(tester, 1), lessThan(0.1));
      await tester.pumpAndSettle();
      expect(_highlight(tester, 2), closeTo(0.1, 0.001));
      expect(_highlight(tester, 1), 0);
      expect(
        tester
            .widget<ChatFolderRail>(find.byType(ChatFolderRail))
            .selectedFolderId,
        2,
      );
      await _disposeFolders(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'partially visible folder scrolls into view during the list slide',
    (tester) async {
      await _pumpFolders(tester, updates);
      final rail = find.byType(ChatFolderRail);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: rail, matching: find.byType(Scrollable)),
      );
      final viewport = tester.getRect(rail);
      final target = find.byKey(const ValueKey('side-folder-3'));
      expect(tester.getRect(target).bottom, greaterThan(viewport.bottom));
      expect(tester.getRect(target).top, lessThan(viewport.bottom));
      await tester.tapAt(Offset(viewport.center.dx, viewport.bottom - 4));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(scrollable.position.pixels, greaterThan(0));
      expect(
        tester
            .widget<ChatListFolderPanes>(find.byType(ChatListFolderPanes))
            .peek,
        isNotNull,
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(target).bottom,
        lessThanOrEqualTo(viewport.bottom + 1),
      );
      await _disposeFolders(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'reduced motion switches the rail and list together',
    (tester) async {
      await _pumpFolders(tester, updates, reducedMotion: true);
      await tester.tap(find.byKey(const ValueKey('side-folder-1')));
      await tester.pump();
      await tester.pump();
      expect(_highlight(tester, 1), closeTo(0.1, 0.001));
      expect(
        tester
            .widget<ChatListFolderPanes>(find.byType(ChatListFolderPanes))
            .peek,
        isNull,
      );
      await _disposeFolders(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
  testWidgets(
    'canceling a folder drag restores the original rail highlight',
    (tester) async {
      await _pumpFolders(tester, updates);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ChatListFolderPanes)),
      );
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(_highlight(tester, 1), greaterThan(0));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_highlight(tester, 1), 0);
      expect(_highlight(tester, null), closeTo(0.1, 0.001));
      expect(
        tester
            .widget<ChatFolderRail>(find.byType(ChatFolderRail))
            .selectedFolderId,
        isNull,
      );
      await _disposeFolders(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

double _highlight(WidgetTester tester, int? folderId) {
  final tile = tester.widget<Container>(
    find.byKey(ValueKey('side-folder-${folderId ?? 'all'}')),
  );
  return (tile.decoration! as BoxDecoration).color?.a ?? 0;
}

Future<void> _pumpFolders(
  WidgetTester tester,
  StreamController<Map<String, dynamic>> updates, {
  bool reducedMotion = false,
}) async {
  SharedPreferences.setMockInitialValues({'communitiesEnabled': false});
  final theme = ThemeController(await SharedPreferences.getInstance());
  theme.chatListSwipeMode = ChatListSwipeMode.switchFolders;
  final controller = ChatListController();
  addTearDown(theme.dispose);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 90,
                height: 210,
                child: ValueListenableBuilder<Widget?>(
                  valueListenable: controller.sideFolders,
                  builder: (_, child, _) => child ?? const SizedBox.shrink(),
                ),
              ),
              Expanded(
                child: ChatListView(
                  controller: controller,
                  desktopSidebar: true,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  updates.add({
    '@type': 'updateChatFolders',
    'chat_folders': [
      for (var id = 1; id <= 8; id++) {'id': id, 'title': 'Folder $id'},
    ],
  });
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _disposeFolders(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}
