import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/image_media_album_bubble.dart';
import 'package:mithka/chat/looping_video_view.dart';
import 'package:mithka/chat/media_spoiler.dart';
import 'package:mithka/chat/message_bubble.dart';
import 'package:mithka/chat/message_send_options.dart';
import 'package:mithka/chat/outgoing_attachment.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/moments/moments_view.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _message(
  int id, {
  String type = 'messagePhoto',
  bool spoiler = true,
}) => ChatMessage(
  id: id,
  chatId: 42,
  isOutgoing: false,
  text: '',
  date: 1,
  contentType: type,
  hasSpoiler: spoiler,
  image: TdFileRef(id: id + 100),
  imageWidth: 320,
  imageHeight: 240,
  video: type == 'messagePhoto' ? null : TdFileRef(id: id + 200),
  videoFileSize: 1000,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  SharedPreferences.setMockInitialValues({});
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(800, 600),
              disableAnimations: true,
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final type in ['messagePhoto', 'messageVideo', 'messageAnimation']) {
    test('$type retains its spoiler flag from TDLib', () {
      for (final spoiler in [true, false]) {
        final message = TDParse.message({
          '@type': 'message',
          'id': 1,
          'date': 1,
          'content': {'@type': type, 'has_spoiler': spoiler},
        });
        expect(message!.hasSpoiler, spoiler);
      }
      expect(
        TDParse.message({
          '@type': 'message',
          'id': 1,
          'date': 1,
          'content': {'@type': type},
        })!.hasSpoiler,
        isFalse,
      );
    });

    testWidgets('$type stays unmounted behind its message spoiler', (
      tester,
    ) async {
      final message = _message(1, type: type);
      await _pump(
        tester,
        MessageBubble(message: message, peerTitle: 'Chat', isGroup: false),
      );
      expect(find.byType(MediaSpoiler), findsOneWidget);
      expect(find.byType(TDImage), findsNothing);
      expect(find.byType(LoopingVideoView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'spoiler send configuration reaches photo, video and animation payloads',
    () {
      for (final kind in [
        OutgoingAttachmentKind.photo,
        OutgoingAttachmentKind.video,
        OutgoingAttachmentKind.animation,
      ]) {
        for (final spoiler in [true, false]) {
          final content = attachmentInputMessageContent(
            OutgoingAttachment(path: '/tmp/fixture', kind: kind),
            sendConfiguration: MessageSendConfiguration(hasSpoiler: spoiler),
          );
          expect(content['has_spoiler'], spoiler);
        }
      }
    },
  );

  test('gallery swipe and video queues cannot expose other spoilers', () {
    final selected = _message(1);
    final other = _message(2);
    final public = _message(3, spoiler: false);
    expect(
      [
        selected,
        other,
        public,
      ].where((m) => canPreviewMediaAlongside(m, selected)),
      [selected, public],
    );
    other.chatId = 99;
    final sameIdElsewhere = _message(1)..chatId = 99;
    expect(canPreviewMediaAlongside(sameIdElsewhere, selected), isFalse);
  });

  testWidgets('send options expose and return the spoiler switch', (
    tester,
  ) async {
    MessageSendConfiguration? selected;
    await _pump(
      tester,
      Builder(
        builder: (context) => GestureDetector(
          onTap: () async {
            selected = await showMessageSendOptionsSheet(
              context,
              mediaOptions: true,
            );
          },
          child: const Text('Open options'),
        ),
      ),
    );
    await tester.tap(find.text('Open options'));
    await tester.pumpAndSettle();
    final row = find
        .ancestor(
          of: find.text('Hide with spoiler'),
          matching: find.byType(Row),
        )
        .first;
    final toggle = find.descendant(of: row, matching: find.byType(AppSwitch));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<AppSwitch>(toggle).value, isTrue);
    final confirm = find.byKey(const ValueKey('messageSendOptionsConfirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(selected?.hasSpoiler, isTrue);
  });

  testWidgets('rich collage spoilers do not enter a sibling gallery', (
    tester,
  ) async {
    final hidden = TdFileRef(id: 1, localPath: 'assets/penguin.png');
    final visible = TdFileRef(id: 2, localPath: 'assets/penguin.png');
    List<TdFileRef>? opened;
    await _pump(
      tester,
      MessageBubble(
        message: ChatMessage(
          id: 10,
          chatId: 42,
          isOutgoing: false,
          text: '',
          date: 1,
          contentType: 'messageRichMessage',
          richBlocks: [
            RichMessageBlock.container(
              kind: RichMessageBlockKind.collage,
              children: [
                RichMessageBlock.media(
                  kind: RichMessageBlockKind.photo,
                  image: hidden,
                  hasSpoiler: true,
                ),
                RichMessageBlock.media(
                  kind: RichMessageBlockKind.photo,
                  image: visible,
                ),
              ],
            ),
          ],
        ),
        peerTitle: 'Chat',
        isGroup: false,
        onOpenImageGallery: ({required items, required startIndex}) =>
            opened = items,
      ),
    );
    final images = find.byType(TDImage);
    expect(images, findsOneWidget);
    await tester.tap(images);
    expect(opened, [visible]);
    opened = null;
    await tester.tap(find.byType(MediaSpoiler));
    await tester.pump();
    expect(opened, isNull);
    final revealed = find.byWidgetPredicate(
      (widget) => widget is TDImage && widget.photo?.id == 1,
    );
    await tester.tap(revealed);
    expect(opened, [hidden]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 181));
  });

  test('non-interactive quote and search previews omit spoiler images', () {
    final hidden = _message(1);
    expect(hidden.previewImage, isNull);
    hidden.hasSpoiler = false;
    expect(hidden.previewImage, same(hidden.image));
  });

  testWidgets('first click reveals, second click opens; keyboard can reveal', (
    tester,
  ) async {
    var opens = 0;
    await _pump(
      tester,
      SizedBox(
        width: 200,
        height: 160,
        child: GestureDetector(
          onTap: () => opens++,
          child: MediaSpoiler(
            identity: 1,
            enabled: true,
            child: Semantics(
              label: 'hidden image',
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('hidden image'), findsNothing);
    expect(find.bySemanticsLabel('Spoiler. Tap to reveal'), findsOneWidget);
    await tester.tap(find.byType(MediaSpoiler));
    await tester.pump();
    expect(opens, 0);
    expect(find.bySemanticsLabel('hidden image'), findsOneWidget);
    await tester.tap(find.byType(MediaSpoiler));
    expect(opens, 1);
    semantics.dispose();

    await _pump(
      tester,
      const SizedBox(
        width: 200,
        height: 160,
        child: MediaSpoiler(
          identity: 2,
          enabled: true,
          child: Text('revealed'),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);
  });

  testWidgets('reveal resets for another message, file or account', (
    tester,
  ) async {
    final message = _message(7);
    var slot = 0;
    late StateSetter update;
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return SizedBox(
            width: 200,
            height: 160,
            child: MessageMediaSpoiler(
              message: message,
              accountSlot: slot,
              child: const Text('revealed'),
            ),
          );
        },
      ),
    );
    await tester.tap(find.byType(MediaSpoiler));
    await tester.pump();
    update(() {});
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);
    update(() => slot = 1);
    await tester.pump();
    expect(find.text('revealed'), findsNothing);
    await tester.tap(find.byType(MediaSpoiler));
    await tester.pump();
    update(() => message.image = TdFileRef(id: 999));
    await tester.pump();
    expect(find.text('revealed'), findsNothing);
    update(() => message.hasSpoiler = false);
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);
    update(() => message.hasSpoiler = true);
    await tester.pump();
    expect(find.text('revealed'), findsNothing);
  });

  testWidgets('album first tap reveals only that tile', (tester) async {
    var opens = 0;
    await _pump(
      tester,
      ImageMediaAlbumBubble(
        messages: [_message(1), _message(2)],
        peerTitle: 'Chat',
        isGroup: false,
        onOpenImage: (_) => opens++,
        imageBuilder: (_, message, _, _) => ColoredBox(
          key: ValueKey('image-${message.id}'),
          color: Colors.blue,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('image-1')), findsNothing);
    expect(find.byKey(const ValueKey('image-2')), findsNothing);
    await tester.tap(find.byType(MediaSpoiler).first);
    await tester.pump();
    expect(opens, 0);
    expect(find.byKey(const ValueKey('image-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('image-1')));
    expect(opens, 1);
  });

  testWidgets('selecting an album keeps spoilers hidden and selection usable', (
    tester,
  ) async {
    var selections = 0;
    await _pump(
      tester,
      ImageMediaAlbumBubble(
        messages: [_message(1), _message(2)],
        peerTitle: 'Chat',
        isGroup: false,
        selecting: true,
        onToggleSelection: (_) => selections++,
        imageBuilder: (_, message, _, _) => Text('image-${message.id}'),
      ),
    );
    // Selection mode deliberately intercepts taps above the concealed tile.
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('messageImageAlbumTile-1'))),
    );
    await tester.pump();
    expect(selections, 1);
    expect(find.text('image-1'), findsNothing);
    expect(find.byKey(const ValueKey('media-selection-1')), findsOneWidget);
  });

  testWidgets('reduced motion keeps the cover static', (tester) async {
    await _pump(
      tester,
      const SizedBox(
        width: 200,
        height: 160,
        child: MediaSpoiler(identity: 1, enabled: true, child: Text('hidden')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hidden'), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('Moments masks spoiler media before fetching its full preview', (
    tester,
  ) async {
    final message = _message(1);
    await _pump(
      tester,
      ChannelPostRow(
        post: ChannelPost(
          channel: ChatSummary(
            id: 42,
            title: 'Channel',
            lastMessage: '',
            lastMessageId: 1,
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
    );
    expect(find.byType(MediaSpoiler), findsOneWidget);
    expect(find.byType(TDImage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
