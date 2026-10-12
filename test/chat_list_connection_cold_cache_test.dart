//
//  chat_list_connection_cold_cache_test.dart
//
//  Companion to chat_list_connection_resume_test.dart. TDLib pushes
//  `updateConnectionState` exactly once per change (verified against the
//  pinned 1.8.67 build), so there is a window — the start of a session, before
//  the client's parameters are set — where no state has been reported yet.
//
//  The header used to fill that window by sending `getConnectionState`, a
//  request the pinned TDLib rejects with "Unknown class", and mapped the
//  rejection to `disconnected`. An unreported state must instead read as
//  `connecting`: claiming the account is disconnected is a claim TDLib never
//  made, and it is what stuck for the rest of the session.
//
//  Separate file because TdClient.shared is a process singleton and a state
//  pushed by another test would leak into the cold cache this one needs.
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

  testWidgets('nothing reported yet reads as connecting, not disconnected', (
    tester,
  ) async {
    await _pumpChatList(tester);

    expect(
      tester
          .widget<Text>(find.byKey(ChatListConnectionStatusView.labelKey))
          .data,
      'connecting',
    );
    expect(
      find.descendant(
        of: find.byKey(ChatListConnectionStatusView.indicatorKey),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    // The pinned TDLib cannot answer a connection-state question, so asking it
    // per mount only produced a failure that used to be rendered as
    // "disconnected".
    expect(requests, isNot(contains('getConnectionState')));
    expect(requests, isNot(contains('getCurrentState')));

    await _dispose(tester);
  });
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
