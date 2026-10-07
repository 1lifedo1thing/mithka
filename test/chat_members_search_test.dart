import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_members_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final requests = <Map<String, dynamic>>[];
  final Map<String, int> memberCounts = {};
  List<Map<String, dynamic>> membersPayload = [];
  var basicGroup = false;

  setUp(() {
    basicGroup = false;
  });

  List<Map<String, dynamic>> member(int id, String name) => [
    {
      '@type': 'chatMember',
      'member_id': {'@type': 'messageSenderUser', 'user_id': id},
      'status': {'@type': 'chatMemberStatusMember'},
    },
  ];

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(Map.of(request));
          switch (request['@type']) {
            case 'getChat':
              return {
                '@type': 'chat',
                'id': 10,
                'type': basicGroup
                    ? {'@type': 'chatTypeBasicGroup', 'basic_group_id': 30}
                    : {'@type': 'chatTypeSupergroup', 'supergroup_id': 20},
              };
            case 'getMe':
              return {'@type': 'user', 'id': 1, 'first_name': 'Me'};
            case 'getChatMember':
              return {
                '@type': 'chatMember',
                'status': {'@type': 'chatMemberStatusMember'},
              };
            case 'getSupergroupFullInfo':
              return {
                '@type': 'supergroupFullInfo',
                'member_count': memberCounts['full'] ?? 1,
              };
            case 'getSupergroupMembers':
              return {
                '@type': 'chatMembers',
                'member_count': membersPayload.length,
                'members': membersPayload,
              };
            case 'getBasicGroupFullInfo':
              return {'@type': 'basicGroupFullInfo', 'members': membersPayload};
            case 'searchChatMembers':
              return {
                '@type': 'chatMembers',
                'member_count': membersPayload.length,
                'members': membersPayload,
              };
            case 'getUser':
              final id = request['user_id'] as int;
              return {
                '@type': 'user',
                'id': id,
                'first_name': 'User$id',
                'last_name': '',
              };
            default:
              return {'@type': 'ok'};
          }
        },
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });

  tearDownAll(TdClient.shared.closeProxy);

  Future<void> pumpView(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatMembersView(chatId: 10, title: 'Group'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('typing a query switches to searchChatMembers', (tester) async {
    membersPayload = member(42, 'Alice');
    await pumpView(tester);
    expect(find.byKey(const ValueKey('chat-members-search')), findsOneWidget);
    expect(find.text('User42'), findsOneWidget);

    requests.clear();
    await tester.enterText(
      find.byKey(const ValueKey('settings-search-field')),
      'ali',
    );
    // debounce
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final search = requests
        .where((r) => r['@type'] == 'searchChatMembers')
        .toList();
    expect(search, isNotEmpty);
    expect(search.last['query'], 'ali');
    expect(search.last['filter']['@type'], 'chatMembersFilterMembers');
  });

  testWidgets('a full first page offers more and scrolling loads it', (
    tester,
  ) async {
    // 200 on the first page (>= page size) -> hasMore.
    membersPayload = [
      for (var i = 0; i < 200; i++)
        {
          '@type': 'chatMember',
          'member_id': {'@type': 'messageSenderUser', 'user_id': 1000 + i},
          'status': {'@type': 'chatMemberStatusMember'},
        },
    ];
    await pumpView(tester);
    expect(find.text('User1000'), findsOneWidget);
    expect(find.text('User1999'), findsNothing);

    requests.clear();
    // Second page: one fresh user.
    membersPayload = [
      {
        '@type': 'chatMember',
        'member_id': {'@type': 'messageSenderUser', 'user_id': 5000},
        'status': {'@type': 'chatMemberStatusMember'},
      },
    ];
    // Walk to the bottom with fixed-duration drags (no fling bounce) so
    // extentAfter drops under the load-more threshold.
    final list = find.byType(ListView).first;
    for (var i = 0; i < 60; i++) {
      await tester.timedDrag(
        list,
        const Offset(0, -400),
        const Duration(milliseconds: 200),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final paged = requests
        .where((r) => r['@type'] == 'getSupergroupMembers')
        .toList();
    expect(paged, isNotEmpty);
    expect(paged.last['offset'], 200);
    expect(find.text('User5000'), findsOneWidget);
  });

  testWidgets('a short member list shows the empty state for a dead query', (
    tester,
  ) async {
    membersPayload = member(42, 'Alice');
    await pumpView(tester);

    membersPayload = [];
    await tester.enterText(
      find.byKey(const ValueKey('settings-search-field')),
      'zzz',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('No members found'), findsOneWidget);
  });

  testWidgets('a progressive second page appends each member once', (
    tester,
  ) async {
    // 200 on the first page -> hasMore; the second page returns 13
    // users, which crosses the every-12th progressive repaint. The old
    // code appended the whole batch again at the end (225 rows); the
    // final count must be exactly 213.
    membersPayload = [
      for (var i = 0; i < 200; i++)
        {
          '@type': 'chatMember',
          'member_id': {'@type': 'messageSenderUser', 'user_id': 1000 + i},
          'status': {'@type': 'chatMemberStatusMember'},
        },
    ];
    await pumpView(tester);

    requests.clear();
    membersPayload = [
      for (var i = 0; i < 13; i++)
        {
          '@type': 'chatMember',
          'member_id': {'@type': 'messageSenderUser', 'user_id': 2000 + i},
          'status': {'@type': 'chatMemberStatusMember'},
        },
    ];
    final list = find.byType(ListView).first;
    for (var i = 0; i < 60; i++) {
      await tester.timedDrag(
        list,
        const Offset(0, -400),
        const Duration(milliseconds: 200),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final paged = requests
        .where((r) => r['@type'] == 'getSupergroupMembers')
        .toList();
    expect(paged.last['offset'], 200);
    // 200 first-page rows + exactly 13 second-page rows. The old double
    // append produced 225. Rows are sorted by name after resolution, so
    // the visible row for User200x sits between the first-page users
    // alphabetically — the list's own child count is the source of truth.
    final listWidget = tester.widget<ListView>(list);
    expect(listWidget.semanticChildCount, 213);
  });

  testWidgets('typing filters the basic-group list locally', (tester) async {
    basicGroup = true;
    membersPayload = [
      {
        '@type': 'chatMember',
        'member_id': {'@type': 'messageSenderUser', 'user_id': 42},
        'status': {'@type': 'chatMemberStatusMember'},
      },
      {
        '@type': 'chatMember',
        'member_id': {'@type': 'messageSenderUser', 'user_id': 43},
        'status': {'@type': 'chatMemberStatusMember'},
      },
    ];
    await pumpView(tester);
    expect(find.text('User42'), findsOneWidget);
    expect(find.text('User43'), findsOneWidget);

    requests.clear();
    await tester.enterText(
      find.byKey(const ValueKey('settings-search-field')),
      '43',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    // The nonmatching member is filtered out locally — no refetch, no
    // searchChatMembers round trip for a list already in memory.
    expect(find.text('User43'), findsOneWidget);
    expect(find.text('User42'), findsNothing);
    expect(requests.where((r) => r['@type'] == 'searchChatMembers'), isEmpty);
    expect(
      requests.where((r) => r['@type'] == 'getBasicGroupFullInfo'),
      isEmpty,
    );
  });
}
