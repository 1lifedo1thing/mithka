//
//  tablet_glass_bar_native_fallback_test.dart
//
//  The system glass bar (NativeBottomTabBar) is a window-bottom bar: UIKit
//  paints its selection capsule against its own slot metrics, so hosting it
//  in a tablet split shell's narrow sidebar column misplaces the highlight
//  over the tabs. The split shell must draw the app-owned glass bar, whose
//  indicator follows the real tab slots; the compact phone bar keeps the
//  system glass.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/app/liquid_glass_bottom_bar.dart';
import 'package:mithka/app/main_tab_view.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });
  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => _response(request),
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  testWidgets('iOS split shell draws the app glass bar, not the system bar', (
    tester,
  ) async {
    await onIOS(() async {
      await _pumpShell(tester, const Size(900, 800));
      // The system bar would render its selection capsule against the window
      // bottom bar's own metrics; only the app-owned bar follows the sidebar's
      // tab slots.
      expect(find.byType(LiquidGlassBottomBar), findsOneWidget);
      expect(find.byKey(const ValueKey('native-bottom-tab-bar')), findsNothing);
      final indicator = find.byKey(const ValueKey('liquid-glass-selection'));
      expect(indicator, findsOneWidget);
      // The indicator covers exactly the first tab slot of the sidebar column.
      final slots = find.byKey(const ValueKey('bottom-tab-0'));
      expect(tester.getRect(indicator), tester.getRect(slots));
      await _dispose(tester);
    });
  });

  testWidgets('compact iOS window keeps the system glass bar', (tester) async {
    await onIOS(() async {
      final native = _MockNativeBar();
      await native.install(tester);
      addTearDown(native.dispose);
      await _pumpShell(tester, const Size(390, 844));
      expect(
        find.byKey(const ValueKey('native-bottom-tab-bar')),
        findsOneWidget,
      );
      expect(find.byType(LiquidGlassBottomBar), findsNothing);
      await _dispose(tester);
    });
  });
}

/// Records the platform view creation and answers the per-bar channel, the
/// way the native UIKit bar does under flutter test.
class _MockNativeBar {
  int? _viewId;
  TestDefaultBinaryMessenger? _messenger;

  Future<void> install(WidgetTester tester) async {
    _messenger = tester.binding.defaultBinaryMessenger;
    _messenger!.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map;
        _viewId = arguments['id'] as int;
        _messenger!.setMockMethodCallHandler(
          MethodChannel('mithka/native_bottom_bar/$_viewId'),
          (call) async => null,
        );
      }
      return null;
    });
  }

  void dispose() {
    _messenger?.setMockMethodCallHandler(SystemChannels.platform_views, null);
    if (_viewId != null) {
      _messenger?.setMockMethodCallHandler(
        MethodChannel('mithka/native_bottom_bar/$_viewId'),
        null,
      );
    }
  }
}

/// Runs [body] with iOS as the target platform, clearing the override before
/// the test body returns (the framework asserts it is unset at teardown).
Future<void> onIOS(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({
    'showChannelsTab': true,
    'showMomentsTab': true,
    'communitiesEnabled': false,
    'liquidGlassBottomBar': true,
  });
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final accounts = AccountStore(prefs);
  final auth = AuthManager();
  final translation = TranslationController(prefs);
  final drawer = dc.DrawerController();
  final deepLinks = ChatDeepLinkController.shared;
  deepLinks.consumePending();

  addTearDown(theme.dispose);
  addTearDown(accounts.dispose);
  addTearDown(translation.dispose);
  addTearDown(drawer.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<AppLocaleController>.value(
          value: AppLocaleController(prefs),
        ),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<AuthManager>.value(value: auth),
        ChangeNotifierProvider<TranslationController>.value(value: translation),
        ChangeNotifierProvider<ChatDeepLinkController>.value(value: deepLinks),
        ChangeNotifierProvider<dc.DrawerController>.value(value: drawer),
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
        theme: ThemeData(
          brightness: Brightness.light,
          extensions: [AppColors.light],
        ),
        home: const MainSplitRootView(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Chat-list cache warming uses delayed no-op guards after disposal.
  await tester.pump(const Duration(seconds: 6));
}

Map<String, dynamic> _response(Map<String, dynamic> request) =>
    switch (request['@type']) {
      'getChats' => {'@type': 'chats', 'chat_ids': <int>[]},
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
      'getConnectionState' => {'@type': 'connectionStateReady'},
      _ => {'@type': 'ok'},
    };
