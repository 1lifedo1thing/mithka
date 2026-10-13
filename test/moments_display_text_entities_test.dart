import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/telegram_rich_text.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/moments/moments_view.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';

void main() {
  testWidgets('real Moments post re-addresses raw leading whitespace once', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 71,
      chatId: 42,
      isOutgoing: false,
      text: '\n\nfile.txt hint',
      date: 1,
      contentType: 'messageText',
      textEntities: const [
        MessageTextEntity(offset: 2, length: 8, type: 'textEntityTypeBold'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        home: Scaffold(
          body: ChannelPostRow(
            post: ChannelPost(
              channel: ChatSummary(
                id: 42,
                title: 'Channel',
                lastMessage: '',
                lastMessageId: 71,
                date: 1,
                unreadCount: 0,
                order: 1,
                isMuted: false,
                kind: ChatKind.channel,
              ),
              message: message,
              accountSlot: 0,
            ),
            meName: 'Me',
            showInlineReply: false,
            showInlineComments: false,
          ),
        ),
      ),
    );
    await tester.pump();
    final rich = tester
        .widgetList<TelegramRichText>(find.byType(TelegramRichText))
        .singleWhere((widget) => widget.text == 'file.txt hint');
    expect(rich.entities.single.offset, 0);
    expect(rich.entities.single.length, 8);
    final display = tester
        .widgetList<RichText>(find.byType(RichText))
        .singleWhere((widget) => widget.text.toPlainText() == 'file.txt hint');
    expect(
      _spans(display.text)
          .where(
            (span) =>
                (span.style?.fontWeight?.value ?? 0) >= FontWeight.w600.value,
          )
          .map((span) => span.text),
      ['file.txt'],
    );
  });
}

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}
