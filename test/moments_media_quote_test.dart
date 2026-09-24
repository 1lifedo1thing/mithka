import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/animated_sticker_view.dart';
import 'package:mithka/chat/music_player_controller.dart';
import 'package:mithka/chat/video_player_view.dart';
import 'package:mithka/chat/video_sticker_view.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/moments/moments_view.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Moments renders music metadata and opens its source playlist', (
    tester,
  ) async {
    final player = MusicPlayerController.shared;
    addTearDown(player.closeWidget);
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final message = ChatMessage(
      id: 12,
      chatId: 42,
      isOutgoing: false,
      text: 'Song caption',
      date: 1,
      contentType: 'messageAudio',
      music: MessageMusic(
        title: 'Channel song',
        performer: 'Artist',
        duration: 187,
        file: TdFileRef(id: 902),
      ),
    );
    await _pumpPost(tester, message);
    expect(find.text('Channel song'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('3:07'), findsOneWidget);
    expect(find.text('Song caption', findRichText: true), findsOneWidget);
    expect(player.current, isNull, reason: 'Scrolling must not start playback');
    await tester.tap(find.byKey(const ValueKey('moments-music-play-12')));
    await tester.pump();
    expect(player.current?.music, same(message.music));
    expect(player.playbackSourceChatId, 42);
    expect(player.playbackSourceTitle, 'Channel');
    await tester.pumpWidget(const SizedBox.shrink());
    player.closeWidget();
    // No native TDLib is started in this rendering test. Drain its bounded
    // file-resolution timeouts after disposing the media widgets.
    await tester.pump(const Duration(seconds: 181));
  });

  for (final kind in ['static', 'animated', 'video', 'emoji']) {
    testWidgets(
      'Moments renders $kind stickers without duplicating emoji text',
      (tester) async {
        final image = TdFileRef(
          id: 910,
          localPath: '${Directory.current.path}/assets/penguin.png',
        );
        final message = ChatMessage(
          id: 13,
          isOutgoing: false,
          text: kind == 'emoji' ? '😀' : '[Sticker]',
          date: 1,
          contentType: kind == 'emoji'
              ? 'messageAnimatedEmoji'
              : 'messageSticker',
          stickerFileId: 911,
          image: image,
          imageWidth: 400,
          imageHeight: 200,
          animatedSticker: kind == 'animated' || kind == 'emoji'
              ? TdFileRef(id: 911)
              : null,
          videoSticker: kind == 'video' ? TdFileRef(id: 912) : null,
        );
        await _pumpPost(tester, message);
        final media = find.byKey(const ValueKey('moments-sticker-13'));
        expect(media, findsOneWidget);
        expect(tester.getSize(media).aspectRatio, closeTo(2, .01));
        expect(find.text('[Sticker]', findRichText: true), findsNothing);
        expect(find.text('😀', findRichText: true), findsNothing);
        if (message.animatedSticker != null) {
          expect(
            tester
                .widget<AnimatedStickerView>(find.byType(AnimatedStickerView))
                .file,
            same(message.animatedSticker),
          );
        } else if (message.videoSticker != null) {
          expect(
            tester.widget<VideoStickerView>(find.byType(VideoStickerView)).file,
            same(message.videoSticker),
          );
        } else {
          expect(
            tester
                .widget<TDImage>(
                  find.descendant(of: media, matching: find.byType(TDImage)),
                )
                .photo,
            same(image),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 181));
      },
    );
  }

  testWidgets('Moments keeps plain emoji text and disables unavailable audio', (
    tester,
  ) async {
    await _pumpPost(
      tester,
      ChatMessage(
        id: 20,
        isOutgoing: false,
        text: 'Hello 🙂',
        date: 1,
        contentType: 'messageText',
      ),
    );
    expect(find.text('Hello 🙂', findRichText: true), findsOneWidget);
    await _pumpPost(
      tester,
      ChatMessage(
        id: 21,
        isOutgoing: false,
        text: '',
        date: 1,
        contentType: 'messageAudio',
        music: MessageMusic(title: 'Unavailable audio'),
      ),
    );
    expect(find.text('Unavailable audio'), findsOneWidget);
    expect(
      tester
          .widget<GestureDetector>(
            find.byKey(const ValueKey('moments-music-play-21')),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('Moments cannot play a cached post from another account', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 22,
      isOutgoing: false,
      text: '',
      date: 1,
      contentType: 'messageAudio',
      music: MessageMusic(title: 'Cached audio', file: TdFileRef(id: 915)),
    );
    await _pumpPost(tester, message, accountSlot: 1);
    expect(
      tester
          .widget<GestureDetector>(
            find.byKey(const ValueKey('moments-music-play-22')),
          )
          .onTap,
      isNull,
    );
  });

  for (final contentType in [
    'messageAnimation',
    'messageVideoNote',
    'messageVideo',
  ]) {
    testWidgets('Moments opens thumbnail-less $contentType', (tester) async {
      final video = TdFileRef(id: 901);
      final message = ChatMessage(
        id: 7,
        isOutgoing: false,
        text: '',
        date: 1,
        contentType: contentType,
        video: video,
        videoDuration: 7,
        imageWidth: 320,
        imageHeight: 240,
      );
      final observer = _MediaRouteObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
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
                  lastMessageId: 7,
                  date: 1,
                  unreadCount: 0,
                  order: 1,
                  isMuted: false,
                  kind: ChatKind.channel,
                ),
                message: message,
                accountSlot: 2,
              ),
              meName: 'Me',
              showInlineReply: false,
              showInlineComments: false,
            ),
          ),
        ),
      );
      final tile = find.byKey(const ValueKey('moments-media-7'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      final route = observer.latest as MaterialPageRoute;
      final player =
          route.builder(tester.element(tile)) as VideoOnDemandPlayerView;
      expect(player.queue.items.single.video, same(video));
      expect(player.queue.items.single.durationSeconds, 7);
      expect(player.queue.items.single.accountSlot, 2);
      expect(player.queue.items.single.messageId, 7);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Moments shows forwarding and unresolved reply attribution', (
    tester,
  ) async {
    final message =
        ChatMessage(
            id: 7,
            isOutgoing: false,
            text: '',
            date: 1,
            replyToMessageId: 9,
          )
          ..forwardFromChatId = -44
          ..forwardOrigin = 'Source channel'
          ..forwardAuthorSignature = 'Alice';
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
                lastMessageId: 7,
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
    expect(find.text('Forwarded from Source channel (Alice)'), findsOneWidget);
    expect(find.byKey(const ValueKey('momentsReplyQuote')), findsOneWidget);
    expect(find.text('Reply', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Moments shows media-only reply quotes', (tester) async {
    final quotedImage = TdFileRef(
      id: 900,
      localPath: '${Directory.current.path}/assets/penguin.png',
    );
    final channel = ChatSummary(
      id: 42,
      title: 'Channel',
      lastMessage: '',
      lastMessageId: 7,
      date: 1,
      unreadCount: 0,
      order: 1,
      isMuted: false,
      kind: ChatKind.channel,
    );
    final message =
        ChatMessage(
            id: 7,
            isOutgoing: false,
            text: 'Moment',
            date: 1,
            contentType: 'messageText',
            replyToMessageId: 9,
            replyToImage: quotedImage,
            replyToImageWidth: 600,
            replyToImageHeight: 400,
          )
          ..replyToSender = 'Original channel'
          ..replyToPreview = '';

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(extensions: [AppColors.light]),
        home: Scaffold(
          body: ChannelPostRow(
            post: ChannelPost(
              channel: channel,
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

    final mediaPreview = find.byKey(const ValueKey('momentsReplyMediaPreview'));
    expect(mediaPreview, findsOneWidget);
    final image = tester.widget<TDImage>(
      find.descendant(of: mediaPreview, matching: find.byType(TDImage)),
    );
    expect(image.photo, same(quotedImage));
  });
}

class _MediaRouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
  }
}

Future<void> _pumpPost(
  WidgetTester tester,
  ChatMessage message, {
  int accountSlot = 0,
}) => tester.pumpWidget(
  MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [AppLocalizations.delegate],
    theme: ThemeData(extensions: [AppColors.light]),
    home: Scaffold(
      body: ChannelPostRow(
        post: ChannelPost(
          channel: ChatSummary(
            id: 42,
            title: 'Channel',
            lastMessage: '',
            lastMessageId: message.id,
            date: 1,
            unreadCount: 0,
            order: 1,
            isMuted: false,
            kind: ChatKind.channel,
          ),
          message: message,
          accountSlot: accountSlot,
        ),
        meName: 'Me',
        showInlineReply: false,
        showInlineComments: false,
      ),
    ),
  ),
);
