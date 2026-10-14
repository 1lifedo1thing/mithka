import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/message_action_menu.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  L10nFixtures.load().install();

  final linkAction = find.byKey(
    const ValueKey('message-action-copyMessageLink'),
  );

  Future<MessageAction?> tapWhenAllowed(
    WidgetTester tester, {
    required bool allowCopyMessageLink,
  }) async {
    MessageAction? selected;
    SharedPreferences.setMockInitialValues({});
    final translation = TranslationController(
      await SharedPreferences.getInstance(),
    );
    addTearDown(translation.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: translation,
        child: MaterialApp(
          home: Scaffold(
            body: MessageActionMenu(
              message: ChatMessage(
                id: 7,
                isOutgoing: false,
                text: 'hello',
                date: 1,
                contentType: 'messageText',
              ),
              isPinned: false,
              allowCopyMessageLink: allowCopyMessageLink,
              onSelect: (action) => selected = action,
            ),
          ),
        ),
      ),
    );
    if (linkAction.evaluate().isNotEmpty) {
      await tester.tap(linkAction);
    }
    return selected;
  }

  testWidgets('copy-message-link action is opt-in per message', (tester) async {
    expect(await tapWhenAllowed(tester, allowCopyMessageLink: false), isNull);
    expect(linkAction, findsNothing);

    expect(
      await tapWhenAllowed(tester, allowCopyMessageLink: true),
      MessageAction.copyMessageLink,
    );
    expect(linkAction, findsOneWidget);
  });

  test(
    'the action label renders in every locale within the grid budget',
    () async {
      for (final locale in AppLocalizations.supportedLocales) {
        await AppStrings.ensureLoaded(locale);
        final localeKey = AppLocalizations.localeKeyFor(locale);
        final label = AppStrings.tForLocale(
          localeKey,
          MessageAction.copyMessageLink.label,
        );
        expect(
          label,
          isNot(MessageAction.copyMessageLink.label),
          reason: '${locale.toLanguageTag()} must carry a real translation',
        );
        expect(
          MessageActionMenu.gridLabel(label).runes.length,
          lessThanOrEqualTo(MessageActionMenu.maxGridLabelCharacters),
          reason: '${locale.toLanguageTag()}: $label',
        );
      }
    },
  );
}
