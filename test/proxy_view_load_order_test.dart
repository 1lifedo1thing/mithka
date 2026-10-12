import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/proxy_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

Map<String, dynamic> _proxies(int id, String host) => {
  '@type': 'proxies',
  'proxies': [
    {
      '@type': 'proxy',
      'id': id,
      'server': host,
      'port': 1080,
      'is_enabled': false,
      'type': {'@type': 'proxyTypeSocks5', 'username': '', 'password': ''},
    },
  ],
};

void main() {
  L10nFixtures.load().install();
  testWidgets('an older read cannot overwrite the proxy wake-up read', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    final old = Completer<Map<String, dynamic>>();
    final updates = StreamController<Map<String, dynamic>>.broadcast();
    var reads = 0;
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (r) async => r['@type'] == 'getProxies'
            ? (++reads == 1 ? old.future : _proxies(88, 'latest.invalid'))
            : {'@type': 'ok'},
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    addTearDown(() async {
      await TdClient.shared.closeProxy();
      await updates.close();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: [AppColors.light]),
          home: const ProxyView(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    updates.add({
      '@type': 'updateConnectionState',
      'state': {'@type': 'connectionStateReady'},
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('latest.invalid'), findsOneWidget);
    old.complete(_proxies(77, 'stale.invalid'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('latest.invalid'), findsOneWidget);
    expect(find.textContaining('stale.invalid'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
