import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/archived_chats_view.dart';
import 'package:mithka/chats/chat_row_view.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/date_text.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('macOS archive rows use secondary click without a swipe tray', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    final chat = ChatSummary(
      id: 12,
      title: 'Archived group',
      lastMessage: 'A message',
      lastMessageId: 11,
      date: 1,
      unreadCount: 0,
      order: 1,
      isMuted: false,
    );
    var selections = 0;
    var unarchives = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: ArchivedChatsView(
            chats: [chat],
            onChatSelected: (_) => selections++,
            onUnarchive: (_) => unarchives++,
          ),
        ),
      ),
    );
    final row = find.byType(ChatRowView);
    final before = tester.getTopLeft(row);
    expect(
      tester.getSize(row).height,
      AppMetric.chatListRowHeight(TargetPlatform.macOS),
    );
    expect(find.byKey(const ValueKey('archived-chat-unarchive')), findsNothing);
    for (final kind in [
      PointerDeviceKind.mouse,
      PointerDeviceKind.trackpad,
      PointerDeviceKind.touch,
    ]) {
      final drag = await tester.startGesture(tester.getCenter(row), kind: kind);
      await drag.moveBy(const Offset(-130, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(row), before);
      expect(
        find.byKey(const ValueKey('archived-chat-unarchive')),
        findsNothing,
      );
    }
    expect(unarchives, 0);
    await tester.tap(row);
    await tester.pump();
    expect(selections, 1);

    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.down(tester.getCenter(row));
    await secondary.up();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('desktop-row-action-menu')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('desktop-row-action-unarchive')),
    );
    await tester.pumpAndSettle();
    expect(unarchives, 1);
    expect(selections, 1);
    expect(find.byKey(const ValueKey('desktop-row-action-menu')), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('group assistant row keeps badge on icon and metadata at right', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final theme = ThemeController(prefs);
      addTearDown(theme.dispose);
      final date = DateTime(2026, 7, 12, 9, 8).millisecondsSinceEpoch ~/ 1000;
      final archived = [
        ChatSummary(
          id: 1,
          title: 'Archived group',
          lastMessage: 'Latest message',
          lastMessageId: 10,
          date: date,
          unreadCount: 105,
          order: 1,
          isMuted: true,
        ),
      ];

      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeController>.value(
          value: theme,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 390,
                child: ArchivedChatsRow(archived: archived),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(UnreadBadge), findsOneWidget);
      final sharedRowFinder = find.descendant(
        of: find.byType(ArchivedChatsRow),
        matching: find.byType(ChatRowView),
      );
      expect(sharedRowFinder, findsOneWidget);
      final sharedRow = tester.widget<ChatRowView>(sharedRowFinder);
      expect(sharedRow.chat.unreadCount, 105);
      expect(sharedRow.chat.isMuted, isTrue);
      expect(sharedRow.chat.lastSender, 'Archived group');
      expect(sharedRow.chat.lastMessage, 'Latest message');
      expect(
        tester.getSize(find.byType(ArchivedChatsRow)).height,
        AppMetric.chatListRowHeight(TargetPlatform.macOS),
      );
      expect(
        find.byKey(const ValueKey('archived-chats-avatar')),
        findsOneWidget,
      );
      expect(find.text('99+'), findsOneWidget);
      expect(find.text(DateText.listLabel(date)), findsOneWidget);
      final icons = tester.widgetList<AppIcon>(find.byType(AppIcon)).toList();
      expect(
        icons.any((icon) => icon.icon == HeroAppIcons.solidMessage),
        isTrue,
      );
      expect(icons.any((icon) => icon.icon == HeroAppIcons.bellSlash), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('archive pane delegates chat selection without pushing a route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);
    final chat = ChatSummary(
      id: 9,
      title: 'Archived group',
      lastMessage: 'A message',
      lastMessageId: 11,
      date: 1,
      unreadCount: 0,
      order: 1,
      isMuted: false,
    );
    ChatSummary? selected;

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: ArchivedChatsView(
            chats: [chat],
            onChatSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    final archiveView = find.byType(ArchivedChatsView);
    expect(Navigator.of(tester.element(archiveView)).canPop(), isFalse);
    await tester.tap(find.text('Archived group'));
    await tester.pump();

    expect(selected, same(chat));
    expect(archiveView, findsOneWidget);
    expect(Navigator.of(tester.element(archiveView)).canPop(), isFalse);
  });

  testWidgets('clearing a badge drops the counter without reopening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);
    final chat = ChatSummary(
      id: 9,
      title: 'Archived group',
      lastMessage: 'A message',
      lastMessageId: 11,
      date: 1,
      unreadCount: 4,
      order: 1,
      isMuted: false,
    );
    // Stands in for the chat list model: clearing mutates the summary and
    // notifies, exactly as ChatListViewModel.markRead does.
    final updates = ChangeNotifier();
    addTearDown(updates.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: LiveArchivedChatsView(
            updates: updates,
            chatsProvider: () => [chat],
            onClearUnread: (value) {
              value.unreadCount = 0;
              updates.notifyListeners();
            },
          ),
        ),
      ),
    );
    expect(find.text('4'), findsOneWidget);

    // The badge clears on a drag, not a tap.
    await tester.drag(find.byType(UnreadBadge), const Offset(60, 0));
    await tester.pump();
    expect(chat.unreadCount, 0);

    // The badge hides itself for the 180ms it spends breaking, so the question
    // is what is on screen once that resets: without a rebuild the row still
    // holds the old count and the counter comes straight back.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('4'), findsNothing);
  });

  testWidgets('archive pane marks only the active chat row as selected', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);
    final chats = [
      ChatSummary(
        id: 9,
        title: 'Active archived group',
        lastMessage: 'A message',
        lastMessageId: 11,
        date: 1,
        unreadCount: 0,
        order: 2,
        isMuted: false,
      ),
      ChatSummary(
        id: 10,
        title: 'Other archived group',
        lastMessage: 'Another message',
        lastMessageId: 12,
        date: 1,
        unreadCount: 0,
        order: 1,
        isMuted: false,
      ),
    ];

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: ArchivedChatsView(chats: chats, selectedChatId: 9),
        ),
      ),
    );

    final rows = tester
        .widgetList<ChatRowView>(find.byType(ChatRowView))
        .toList();
    expect(rows, hasLength(2));
    expect(rows.singleWhere((row) => row.chat.id == 9).selected, isTrue);
    expect(rows.singleWhere((row) => row.chat.id == 10).selected, isFalse);
  });

  testWidgets('archived chat exposes a swipe action to unarchive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);
    final chat = ChatSummary(
      id: 12,
      title: 'Archived group',
      lastMessage: 'A message',
      lastMessageId: 11,
      date: 1,
      unreadCount: 0,
      order: 1,
      isMuted: false,
    );
    var unarchived = false;

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: ArchivedChatsView(
            chats: [chat],
            onUnarchive: (_) => unarchived = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('archived-chat-unarchive')), findsNothing);
    final rowHeight = tester.getSize(find.byType(ChatRowView)).height;
    await tester.drag(find.text('Archived group'), const Offset(-100, 0));
    await tester.pump();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('archived-chat-unarchive')))
          .height,
      rowHeight,
    );
    await tester.tap(find.byKey(const ValueKey('archived-chat-unarchive')));
    expect(unarchived, isTrue);
  });
}
