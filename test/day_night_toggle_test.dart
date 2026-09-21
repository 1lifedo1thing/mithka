import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/app/main_tab_view.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/profile/profile_view.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // Keep theme interaction tests entirely off the real Telegram account.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  for (final desktop in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets('${desktop ? 'desktop' : 'profile'} toggles automatic '
          '${brightness.name} to its opposite and back on consecutive taps', (
        tester,
      ) async {
        final controller = await _pumpSwitch(
          tester,
          desktop: desktop,
          brightness: brightness,
          platformBrightness: brightness,
        );
        final target = desktop
            ? find.byKey(const ValueKey('desktop-theme-toggle-button'))
            : find.byTooltip(
                AppStrings.t(
                  brightness == Brightness.dark
                      ? AppStringKeys.profileDayMode
                      : AppStringKeys.profileNightMode,
                ),
              );
        expect(controller.mode, AppearanceMode.system);
        expect(target, findsOneWidget);
        await tester.tap(target);
        expect(
          controller.mode,
          brightness == Brightness.dark
              ? AppearanceMode.light
              : AppearanceMode.dark,
        );
        // No frame in between: the callback and animated Theme still refer to
        // the previous brightness, but a second click must reverse the choice.
        await tester.tap(target);
        expect(
          controller.mode,
          brightness == Brightness.dark
              ? AppearanceMode.dark
              : AppearanceMode.light,
        );
        final restored = ThemeController(await SharedPreferences.getInstance());
        expect(restored.mode, controller.mode);
        restored.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        // Let the desktop chat list's deferred cache warm-up finish against
        // the mock transport after disposing the app.
        await tester.pump(const Duration(seconds: 6));
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'automatic profile switch follows displayed ${brightness.name}, not a changed OS value',
      (tester) async {
        final controller = await _pumpSwitch(
          tester,
          desktop: false,
          brightness: brightness,
          platformBrightness: brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
        );
        final target = find.byTooltip(
          AppStrings.t(
            brightness == Brightness.dark
                ? AppStringKeys.profileDayMode
                : AppStringKeys.profileNightMode,
          ),
        );
        expect(target, findsOneWidget);
        await tester.tap(target);
        expect(
          controller.mode,
          brightness == Brightness.dark
              ? AppearanceMode.light
              : AppearanceMode.dark,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}

Future<ThemeController> _pumpSwitch(
  WidgetTester tester, {
  required bool desktop,
  required Brightness brightness,
  required Brightness platformBrightness,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({
    'showMomentsTab': false,
    'communitiesEnabled': false,
  });
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final accounts = AccountStore(prefs);
  final auth = AuthManager();
  final translation = TranslationController(prefs);
  final locale = AppLocaleController(prefs);
  final drawer = dc.DrawerController();
  final deepLinks = ChatDeepLinkController.shared..consumePending();
  for (final controller in [
    theme,
    accounts,
    auth,
    translation,
    locale,
    drawer,
  ]) {
    addTearDown(controller.dispose);
  }
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<AuthManager>.value(value: auth),
        ChangeNotifierProvider<TranslationController>.value(value: translation),
        ChangeNotifierProvider<AppLocaleController>.value(value: locale),
        ChangeNotifierProvider<ChatDeepLinkController>.value(value: deepLinks),
        ChangeNotifierProvider<dc.DrawerController>.value(value: drawer),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: brightness,
          extensions: [
            brightness == Brightness.dark ? AppColors.dark : AppColors.light,
          ],
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            platformBrightness: platformBrightness,
            // Keep the empty-pane wordmark inside its fixed-width pane with
            // Flutter tests' unusually wide Ahem font.
            textScaler: const TextScaler.linear(0.8),
          ),
          child: child!,
        ),
        home: desktop
            ? const MainSplitRootView()
            : const Scaffold(body: ProfileView()),
      ),
    ),
  );
  await tester.pump();
  return theme;
}
