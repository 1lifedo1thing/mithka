import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/message_quote_selection_dialog.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform quotes a selected range without editing the source', (
      tester,
    ) async {
      MessageTextQuote? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform, extensions: [AppColors.light]),
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () async {
                result = await showGeneralDialog<MessageTextQuote>(
                  context: context,
                  pageBuilder: (_, _, _) => MessageQuoteSelectionDialog(
                    message: ChatMessage(
                      id: 7,
                      isOutgoing: false,
                      date: 1,
                      text: 'same same',
                      contentType: 'messageText',
                    ),
                    maxLength: 4,
                  ),
                );
              },
              child: const Text('Open quote'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open quote'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('message-quote-source')),
      );
      expect(field.readOnly, isTrue);
      expect(field.controller!.text, 'same same');
      final confirm = find.byKey(const ValueKey('message-quote-confirm'));
      await tester.tap(confirm);
      await tester.pump();
      expect(find.byType(MessageQuoteSelectionDialog), findsOneWidget);
      expect(result, isNull);

      field.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 9,
      );
      await tester.pump();
      expect(find.text('9 / 4'), findsOneWidget);
      expect(tester.widget<GestureDetector>(confirm).onTap, isNull);

      // Reverse selection must still use the second occurrence's exact offset.
      field.controller!.selection = const TextSelection(
        baseOffset: 9,
        extentOffset: 5,
      );
      await tester.pump();
      expect(find.text('4 / 4'), findsOneWidget);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(result!.text, 'same');
      expect(result!.position, 5);
      expect(find.byType(MessageQuoteSelectionDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
