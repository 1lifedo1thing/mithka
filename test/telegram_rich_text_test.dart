import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/custom_emoji.dart';
import 'package:mithka/chat/message_bubble.dart';
import 'package:mithka/chat/telegram_rich_text.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Iterable<TextSpan> _textSpans(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _textSpans(child);
  }
}

void main() {
  testWidgets('links are colored without adding an underline', (tester) async {
    const text = 'site https://example.com manual';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TelegramRichText(
            text: text,
            entities: [
              MessageTextEntity(
                offset: 0,
                length: 4,
                type: 'textEntityTypeTextUrl',
                url: 'https://example.com/site',
              ),
              MessageTextEntity(
                offset: 25,
                length: 6,
                type: 'textEntityTypeUnderline',
              ),
            ],
          ),
        ),
      ),
    );

    final richText = tester.widget<RichText>(find.byType(RichText));
    final spans = _textSpans(richText.text).toList();
    final entityLink = spans.singleWhere((span) => span.text == 'site');
    final autoLink = spans.singleWhere(
      (span) => span.text == 'https://example.com',
    );
    final explicitUnderline = spans.singleWhere(
      (span) => span.text == 'manual',
    );

    expect(entityLink.style?.decoration, isNot(TextDecoration.underline));
    expect(autoLink.style?.decoration, isNot(TextDecoration.underline));
    expect(explicitUnderline.style?.decoration, TextDecoration.underline);
  });

  testWidgets('custom emoji stays hidden until its spoiler is revealed', (
    tester,
  ) async {
    const text = '🙂';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TelegramRichText(
            text: text,
            entities: [
              MessageTextEntity(
                offset: 0,
                length: 2,
                type: 'textEntityTypeSpoiler',
              ),
              MessageTextEntity(
                offset: 0,
                length: 2,
                type: 'textEntityTypeCustomEmoji',
                customEmojiId: 123,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CustomEmojiView), findsNothing);
    final richText = tester.widget<RichText>(find.byType(RichText));
    final spoiler = _textSpans(
      richText.text,
    ).singleWhere((span) => span.text == text);
    (spoiler.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();

    expect(find.byType(CustomEmojiView), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('selection copies a custom emoji fallback as message text', (
    tester,
  ) async {
    const text = 'A🙂B';
    final selectionKey = GlobalKey<SelectionAreaState>();
    String? selectedText;
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            key: selectionKey,
            onSelectionChanged: (content) {
              selectedText = content?.plainText;
            },
            child: const TelegramRichText(
              text: text,
              entities: [
                MessageTextEntity(
                  offset: 1,
                  length: 2,
                  type: 'textEntityTypeCustomEmoji',
                  customEmojiId: 456,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    selectionKey.currentState!.selectableRegion.selectAll(
      SelectionChangedCause.keyboard,
    );
    await tester.pump();
    expect(selectedText, text);

    Actions.invoke(
      tester.element(find.byType(TelegramRichText)),
      CopySelectionTextIntent.copy,
    );
    await tester.pump();
    expect(copiedText, text);
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
    'MessageBubble lays out consecutive custom emoji collages flush horizontally and vertically',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final theme = ThemeController(prefs);
      addTearDown(theme.dispose);

      // Two rows of two custom emojis each: "😀😀\n😀😀"
      // UTF-16 offsets:
      // 0..2, 2..4, 4..5 ('\n'), 5..7, 7..9
      const text = '😀😀\n😀😀';
      final message = ChatMessage(
        id: 501,
        isOutgoing: false,
        text: text,
        date: 1000,
        contentType: 'messageText',
        textEntities: const [
          MessageTextEntity(
            offset: 0,
            length: 2,
            type: 'textEntityTypeCustomEmoji',
            customEmojiId: 1001,
          ),
          MessageTextEntity(
            offset: 2,
            length: 2,
            type: 'textEntityTypeCustomEmoji',
            customEmojiId: 1002,
          ),
          MessageTextEntity(
            offset: 5,
            length: 2,
            type: 'textEntityTypeCustomEmoji',
            customEmojiId: 1003,
          ),
          MessageTextEntity(
            offset: 7,
            length: 2,
            type: 'textEntityTypeCustomEmoji',
            customEmojiId: 1004,
          ),
        ],
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeController>.value(
          value: theme,
          child: MaterialApp(
            theme: ThemeData(extensions: [AppColors.light]),
            home: Scaffold(
              body: MessageBubble(
                message: message,
                peerTitle: 'Collage',
                isGroup: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final emojis = find.byType(SelectableCustomEmojiView);
      expect(emojis, findsNWidgets(4));

      final r0 = tester.getRect(emojis.at(0));
      final r1 = tester.getRect(emojis.at(1));
      final r2 = tester.getRect(emojis.at(2));
      final r3 = tester.getRect(emojis.at(3));

      // Horizontal adjacency: no gap between tile 0 and tile 1, or tile 2 and tile 3.
      expect(r1.left, closeTo(r0.right, 0.01));
      expect(r3.left, closeTo(r2.right, 0.01));

      // Vertical adjacency: row 2 top meets row 1 bottom without extra line-height gap.
      expect(r2.top, closeTo(r0.bottom, 0.01));
      expect(r3.top, closeTo(r1.bottom, 0.01));

      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'TelegramRichText lays out consecutive custom emoji collages flush horizontally and vertically',
    (tester) async {
      const text = '😀😀\n😀😀';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          home: const Scaffold(
            body: TelegramRichText(
              text: text,
              style: TextStyle(fontSize: 15, height: 1.35, color: Colors.black),
              entities: [
                MessageTextEntity(
                  offset: 0,
                  length: 2,
                  type: 'textEntityTypeCustomEmoji',
                  customEmojiId: 2001,
                ),
                MessageTextEntity(
                  offset: 2,
                  length: 2,
                  type: 'textEntityTypeCustomEmoji',
                  customEmojiId: 2002,
                ),
                MessageTextEntity(
                  offset: 5,
                  length: 2,
                  type: 'textEntityTypeCustomEmoji',
                  customEmojiId: 2003,
                ),
                MessageTextEntity(
                  offset: 7,
                  length: 2,
                  type: 'textEntityTypeCustomEmoji',
                  customEmojiId: 2004,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final emojis = find.byType(SelectableCustomEmojiView);
      expect(emojis, findsNWidgets(4));

      final r0 = tester.getRect(emojis.at(0));
      final r1 = tester.getRect(emojis.at(1));
      final r2 = tester.getRect(emojis.at(2));
      final r3 = tester.getRect(emojis.at(3));

      expect(r1.left, closeTo(r0.right, 0.01));
      expect(r3.left, closeTo(r2.right, 0.01));
      expect(r2.top, closeTo(r0.bottom, 0.01));
      expect(r3.top, closeTo(r1.bottom, 0.01));

      await tester.pump(const Duration(milliseconds: 50));
    },
  );
}
