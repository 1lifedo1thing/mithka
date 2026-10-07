import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/group_management_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final requests = <Map<String, dynamic>>[];
  var basicUpgraded = false;
  Map<String, dynamic> selfStatus = {'@type': 'chatMemberStatusCreator'};

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
                'id': 42,
                'title': 'Group',
                'type': {'@type': 'chatTypeBasicGroup', 'basic_group_id': 10},
              };
            case 'getMe':
              return {'@type': 'user', 'id': 1};
            case 'getChatMember':
              return {'@type': 'chatMember', 'status': selfStatus};
            case 'getBasicGroup':
              return {
                '@type': 'basicGroup',
                'id': 10,
                'member_count': 3,
                'is_active': true,
                'upgraded_to_supergroup_id': basicUpgraded ? 77 : 0,
              };
            case 'upgradeBasicGroupChatToSupergroupChat':
              return {
                '@type': 'chat',
                'id': 99,
                'type': {'@type': 'chatTypeSupergroup', 'supergroup_id': 77},
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
          locale: const Locale('en'),
          theme: ThemeData(extensions: [AppColors.light]),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const GroupManagementView(chatId: 42, title: 'Group'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the creator of a plain basic group sees the upgrade entry', (
    tester,
  ) async {
    await pumpView(tester);
    await tester.scrollUntilVisible(
      find.text('Convert to supergroup'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Convert to supergroup'), findsOneWidget);
  });

  testWidgets('confirming posts the upgrade and pops with the new chat id', (
    tester,
  ) async {
    await pumpView(tester);
    await tester.scrollUntilVisible(
      find.text('Convert to supergroup'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    requests.clear();

    await tester.tap(find.text('Convert to supergroup'));
    await tester.pumpAndSettle();
    expect(find.text('Convert to supergroup?'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final upgrade = requests
        .where((r) => r['@type'] == 'upgradeBasicGroupChatToSupergroupChat')
        .toList();
    expect(upgrade, hasLength(1));
    expect(upgrade.single['chat_id'], 42);
  });

  testWidgets('an already-upgraded basic group hides the entry', (
    tester,
  ) async {
    basicUpgraded = true;
    await pumpView(tester);
    expect(find.text('Convert to supergroup'), findsNothing);
  });
}
