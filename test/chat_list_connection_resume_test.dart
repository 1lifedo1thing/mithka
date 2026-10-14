//
//  chat_list_connection_resume_test.dart
//
//  Regression for the chat-list header status sticking on "disconnected" after
//  the app comes back to the foreground or the list remounts.
//
//  The pinned TDLib (scripts/tdjson-manifest.json, 1.8.67) has no
//  `getConnectionState` request: it answers
//      error 400 "Failed to parse JSON object as TDLib request:
//                 Unknown class \"getConnectionState\""
//  The header used to ask for exactly that and mapped the failure to
//  `disconnected`. `updateConnectionState` is push-only and TDLib sends it once
//  per change, so a view that mounts after the account settled never heard it
//  again and the wrong label stuck for the rest of the session.
//
//  The fake transport below answers like the real library does and pushes the
//  state updates TDLib pushes, so these tests fail against the old header. The
//  cold-cache case (nothing reported yet) lives in
//  chat_list_connection_cold_cache_test.dart because TdClient.shared is a
//  process singleton whose cache survives between tests in one file.
//

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

import 'support/l10n_fixtures.dart';

void main() {
  final fixtures = L10nFixtures.load();
  final updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final requests = <String>[];

  setUpAll(() {
    fixtures.install();
    AppStrings.setLocale(const Locale('en'));
    // No account is touched: the transport answers locally and reproduces the
    // pinned TDLib's rejection of the request the header used to send.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request['@type'] as String? ?? '');
          return switch (request['@type']) {
            'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
            // Exactly what the pinned TDLib does with the request the header
            // used to send: TdClient turns an `error` reply into a throw.
            'getConnectionState' => throw TdError(<String, dynamic>{
              '@type': 'error',
              'code': 400,
              'message':
                  'Failed to parse JSON object as TDLib request: '
                  'Unknown class "getConnectionState"',
            }),
            _ => {'@type': 'ok'},
          };
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

  /// The state TDLib reports once, before the chat list exists.
  void pushConnectionState(String state) {
    updates.add({
      '@type': 'updateConnectionState',
      'state': {'@type': state},
    });
  }

  testWidgets('a mount after TDLib settled shows its last reported state', (
    tester,
  ) async {
    pushConnectionState('connectionStateReady');
    await _pumpChatList(tester);

    expect(_label(tester), 'online');
    expect(_dotColor(tester), AppTheme.onlineDot);
    await _dispose(tester);
  });

  testWidgets('the header follows the next pushed state', (tester) async {
    await _pumpChatList(tester);
    expect(_label(tester), 'online');

    pushConnectionState('connectionStateWaitingForNetwork');
    await tester.pump();
    expect(_label(tester), 'disconnected');

    pushConnectionState('connectionStateConnecting');
    await tester.pump();
    expect(_label(tester), 'connecting');

    // And the cached state survives a remount, which is what returning to the
    // app after the list was rebuilt used to lose.
    pushConnectionState('connectionStateReady');
    await tester.pump();
    expect(_label(tester), 'online');

    await _dispose(tester);
    await _pumpChatList(tester);
    expect(_label(tester), 'online');
    await _dispose(tester);
  });
}

String _label(WidgetTester tester) => tester
    .widget<Text>(find.byKey(ChatListConnectionStatusView.labelKey))
    .data!;

Color? _dotColor(WidgetTester tester) {
  final indicator = tester.widget<Container>(
    find.byKey(ChatListConnectionStatusView.indicatorKey),
  );
  return (indicator.decoration! as BoxDecoration).color;
}

Future<void> _pumpChatList(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'communitiesEnabled': false});
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        theme: ThemeData(extensions: [AppColors.light]),
        home: const Scaffold(body: ChatListView()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}
