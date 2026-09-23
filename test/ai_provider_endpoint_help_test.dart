import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_endpoint_style.dart';
import 'package:mithka/settings/ai_settings_controller.dart';
import 'package:mithka/settings/ai_settings_view.dart';
import 'package:mithka/settings/apple_pcc_api.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
    for (final width in [390.0, 900.0]) {
      testWidgets(
        'full URL guidance stays visible for each API style ($locale, $width)',
        (tester) async {
          await _pumpEditor(tester, locale: locale, width: width);
          final endpointField = find.byType(TextField).at(1);
          const baseUrl = 'https://ai.example/custom/v1';
          await tester.enterText(endpointField, baseUrl);

          for (final style in AiEndpointStyle.values) {
            if (style != AiEndpointStyle.openAiChatCompletions) {
              await tester.ensureVisible(
                find.byKey(const ValueKey('aiEndpointStyleRow')),
              );
              await tester.tap(
                find.byKey(const ValueKey('aiEndpointStyleRow')),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.text(style.endpointSuffix));
              await tester.pumpAndSettle();
            }

            final context = tester.element(find.byType(AiProviderEditorView));
            final help = context.l10n.t(AppStringKeys.aiServerEndpointHelp, {
              'value1': style.exampleEndpoint,
            });
            expect(help, contains(style.exampleEndpoint));
            expect(help, contains(locale.languageCode == 'zh' ? '完整' : 'full'));
            final note = find.widgetWithText(SettingsNote, help);
            expect(note, findsOneWidget);
            await tester.ensureVisible(note);
            expect(find.text(help).hitTestable(), findsOneWidget);
            expect(help, isNot(contains('{value1}')));
            expect(
              tester.widget<TextField>(endpointField).controller!.text,
              baseUrl,
              reason: 'Selecting an API style must not complete a base URL.',
            );
            expect(
              tester.widget<TextField>(endpointField).decoration!.hintText,
              style.exampleEndpoint,
            );
            expect(tester.takeException(), isNull);
          }
        },
      );
    }

    testWidgets('base URLs are rejected with full URL guidance ($locale)', (
      tester,
    ) async {
      final settings = await _pumpEditor(tester, locale: locale);
      final endpointField = find.byType(TextField).at(1);
      final context = tester.element(find.byType(AiProviderEditorView));
      final saveLabel = AppStringKeys.aiSaveProvider.l10n(context);
      final error = AppStringKeys.aiInvalidEndpoint.l10n(context);
      expect(error, contains(locale.languageCode == 'zh' ? '完整' : 'full'));

      for (final baseUrl in ['https://ai.example', 'https://ai.example/v1']) {
        await tester.ensureVisible(endpointField);
        await tester.enterText(endpointField, baseUrl);
        await tester.ensureVisible(find.text(saveLabel));
        await tester.tap(find.text(saveLabel));
        await tester.pumpAndSettle();
        expect(settings.serverProviders, isEmpty);
        expect(find.text(error), findsOneWidget);
        expect(
          tester.widget<TextField>(endpointField).controller!.text,
          baseUrl,
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
      }

      const fullUrl = 'https://ai.example/custom/v1/chat/completions';
      await tester.ensureVisible(endpointField);
      await tester.enterText(endpointField, fullUrl);
      await tester.ensureVisible(find.text(saveLabel));
      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();
      expect(settings.serverProviders.single.endpoint, fullUrl);
      expect(find.byType(AiProviderEditorView), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });
  }
}

Future<AiSettingsController> _pumpEditor(
  WidgetTester tester, {
  required Locale locale,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final settings = AiSettingsController(
    preferences,
    pccApi: ApplePccApi(
      invokeMethod: (_, _) async => {
        'sdkAvailable': false,
        'available': false,
        'reason': 'unavailable',
      },
    ),
    secureRead: (_) async => null,
    secureWrite: (_, _) async {},
  );
  final theme = ThemeController(preferences);
  addTearDown(settings.dispose);
  addTearDown(theme.dispose);
  await settings.initialize();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: theme),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SizedBox(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(
    navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const AiProviderEditorView()),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}
