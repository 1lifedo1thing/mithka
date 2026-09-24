import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/image_media_album_bubble.dart';
import 'package:mithka/chat/message_bubble.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/message_bubble_background.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Iterable<TextSpan> spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* spans(child);
    }
  }
}

void main() {
  for (final dark in [false, true]) {
    for (final album in [false, true]) {
      for (final outgoing in [false, true]) {
        testWidgets(
          'decorative links dark=$dark album=$album outgoing=$outgoing',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final theme = ThemeController(await SharedPreferences.getInstance())
              ..messageBubblesEnabled = true
              ..messageBubbleBackground =
                  MessageBubbleBackground.midnightAurora;
            addTearDown(theme.dispose);
            const text = 'Body site https://example.com';
            ChatMessage message(int id, String text) => ChatMessage(
              id: id,
              date: 1,
              isOutgoing: outgoing,
              text: text,
              contentType: album ? 'messagePhoto' : 'messageText',
              image: album ? TdFileRef(id: id) : null,
              textEntities: const [
                MessageTextEntity(
                  offset: 5,
                  length: 4,
                  type: 'textEntityTypeTextUrl',
                  url: 'https://example.com',
                ),
              ],
            );
            await tester.pumpWidget(
              ChangeNotifierProvider.value(
                value: theme,
                child: MaterialApp(
                  theme: ThemeData(
                    brightness: dark ? Brightness.dark : Brightness.light,
                    extensions: [dark ? AppColors.dark : AppColors.light],
                  ),
                  home: Scaffold(
                    body: album
                        ? ImageMediaAlbumBubble(
                            messages: [message(1, ''), message(2, text)],
                            peerTitle: 'Test',
                            isGroup: false,
                            imageBuilder: (_, _, _, _) =>
                                const SizedBox.shrink(),
                          )
                        : MessageBubble(
                            message: message(1, text),
                            peerTitle: 'Test',
                            isGroup: false,
                          ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final rich = tester
                .widgetList<RichText>(find.byType(RichText))
                .singleWhere((w) => w.text.toPlainText() == text);
            final parts = spans(rich.text).toList();
            for (final target in ['site', 'https://example.com']) {
              final link = parts.singleWhere((span) => span.text == target);
              expect(
                link.style?.decoration?.contains(TextDecoration.underline),
                true,
              );
              expect(link.style?.decorationThickness, 1);
            }
            final body = parts.singleWhere((span) => span.text == 'Body ');
            expect(
              body.style?.decoration?.contains(TextDecoration.underline) ??
                  false,
              false,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  test('nearby theme ink needs a cue but distinct colors do not', () {
    expect(linkNeedsUnderline(body: Colors.white, link: Colors.white), true);
    expect(
      linkNeedsUnderline(
        body: const Color(0xff111111),
        link: const Color(0xff333333),
      ),
      true,
    );
    expect(linkNeedsUnderline(body: Colors.white, link: Colors.black), false);
  });
}
