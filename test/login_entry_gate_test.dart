import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/content_view.dart' show ContentView, SplashView;
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/auth/login_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/proxy_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

/// The shared TdClient, re-pointed at a fake transport. The singleton is
/// configured exactly once per process (configureProxy throws on a second
/// call), so every test in this file shares one fake that the individual
/// tests re-program through the [fakeProxies]/[fakeConnectionState] setters.
final TdClient _td = TdClient.shared;
final StreamController<Map<String, dynamic>> _tdUpdates =
    StreamController<Map<String, dynamic>>.broadcast();
var _fakeAuthState = const <String, dynamic>{
  '@type': 'authorizationStateWaitPhoneNumber',
};

/// Holds the state read open until the test releases it, so the reload's
/// intermediate frame can be observed while the read is genuinely in flight.
Completer<void>? _holdStateRead;

void _installFakeTdlib() {
  if (_tdProxyConfigured) return;
  _tdProxyConfigured = true;
  _td.configureProxy(
    TdClientProxyTransport(
      accountSlot: 0,
      query: (request) async {
        final type = request['@type'];
        if (type == 'getAuthorizationState') {
          final hold = _holdStateRead;
          if (hold != null) await hold.future;
          return _fakeAuthState;
        }
        return switch (type) {
          'getMe' => {
            '@type': 'user',
            'id': 1,
            'first_name': 'Gate',
            'phone_number': '15550001111',
          },
          'getOption' => {
            '@type': 'optionValueBoolean',
            'name': request['name'],
            'value': false,
          },
          _ => {'@type': 'ok'},
        };
      },
      send: (_) async {},
      updates: _tdUpdates.stream,
    ),
  );
}

bool _tdProxyConfigured = false;

/// A real AuthManager whose TDLib reads are answered by the fake transport,
/// so reloadAuthState exercises the actual state machine end to end.
AuthManager _realAuth() {
  _installFakeTdlib();
  return AuthManager();
}

Future<void> _pumpGate(
  WidgetTester tester,
  AuthManager auth,
  AccountStore accounts,
) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<AuthManager>.value(value: auth),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        home: const ContentView(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(() => L10nFixtures.load().install());

  group('auth gate surfaces', () {
    testWidgets('a cold start still paints the splash', (tester) async {
      // Guard test: passes before and after the fix by design — startup keeps
      // the splash, only the reload path changed.
      SharedPreferences.setMockInitialValues({});
      final accounts = AccountStore(await SharedPreferences.getInstance());
      final auth = _realAuth();
      addTearDown(accounts.dispose);
      addTearDown(auth.dispose);
      await _pumpGate(tester, auth, accounts);
      expect(find.byType(SplashView), findsOneWidget);
      expect(find.byType(LoginView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('reloading the client from the login never shows the splash', (
      tester,
    ) async {
      // Failing-first: reloadAuthState published AuthInitializing — which the
      // gate maps to SplashView — for every re-read, including the one behind
      // 添加账号, so the login surface flashed the full-screen splash for the
      // whole crossfade. Drives the real reload from a settled login screen,
      // the same starting point the add-account flow has.
      SharedPreferences.setMockInitialValues({});
      final accounts = AccountStore(await SharedPreferences.getInstance());
      final auth = _realAuth();
      addTearDown(accounts.dispose);
      addTearDown(auth.dispose);
      await _pumpGate(tester, auth, accounts);
      // The login flow reaches the screen through the same reload the
      // add-account path uses; run it once to settle on the phone step —
      // the login surface, where the flow starts.
      auth.reloadAuthState();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SplashView), findsNothing);
      expect(find.byType(LoginView), findsOneWidget);

      // Re-entering the flow (the user backed out and tapped 添加账号 again)
      // reloads the client again from the login surface. The read is held
      // open, so the observed frame is the real intermediate state, not a
      // race against the fake's microtask answer.
      _holdStateRead = Completer<void>();
      auth.reloadAuthState();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SplashView), findsNothing);
      expect(find.byType(LoginView), findsOneWidget);

      _holdStateRead!.complete();
      _holdStateRead = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LoginView), findsOneWidget);
      expect(find.byType(SplashView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('login proxy shortcut', () {
    // The login surface and the sidebar share ProxyStatusController. The
    // shared singleton is configured once per process by
    // profile_proxy_button_test.dart's setUpAll — this file only needs the
    // fake transport to exist, and reads whatever the controller last held.
    testWidgets('the login page reuses the sidebar proxy button', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final accounts = AccountStore(await SharedPreferences.getInstance());
      final theme = ThemeController(await SharedPreferences.getInstance());
      final auth = _realAuth();
      auth.reloadAuthState(); // resolves to the phone step on the unconfigured client
      addTearDown(accounts.dispose);
      addTearDown(theme.dispose);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AccountStore>.value(value: accounts),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<AuthManager>.value(value: auth),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(extensions: [AppColors.light]),
            home: const LoginView(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // Same widget the sidebar uses — the shared keys must be present.
      expect(
        find.byKey(const ValueKey('profile-proxy-button')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('profile-proxy-icon')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('tapping the shortcut opens the 代理 page, not the editor', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final accounts = AccountStore(await SharedPreferences.getInstance());
      final theme = ThemeController(await SharedPreferences.getInstance());
      final auth = _realAuth();
      auth.reloadAuthState(); // resolves to the phone step on the unconfigured client
      addTearDown(accounts.dispose);
      addTearDown(theme.dispose);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AccountStore>.value(value: accounts),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<AuthManager>.value(value: auth),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(extensions: [AppColors.light]),
            home: const LoginView(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('profile-proxy-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ProxyView), findsOneWidget);
      expect(find.byType(ProxyEditView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
