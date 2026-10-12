import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/full_image_viewer.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/profile/profile_detail_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

// The featured-photo viewer on your own profile replaces the gallery's
// built-in `…` menu with the delete sheet. That sheet must still offer the
// save action the built-in menu has, and the row must run the viewer's save
// pipeline (photo library on phones, picked folder on desktop) instead of a
// menu that only deletes.

Map<String, dynamic> _fileJson(int id, String path) => {
  '@type': 'file',
  'id': id,
  'local': {
    '@type': 'localFile',
    'path': path,
    'is_downloading_completed': true,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  L10nFixtures.load().install();

  late Directory directory;
  late String photoPath;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getMe' => {
            '@type': 'user',
            'id': 1,
            'type': {'@type': 'userTypeRegular'},
          },
          'getUser' => {
            '@type': 'user',
            'id': 1,
            'first_name': 'Me',
            'profile_photo': {
              '@type': 'chatPhotoInfo',
              'small': _fileJson(101, photoPath),
            },
            'type': {'@type': 'userTypeRegular'},
          },
          'getUserProfilePhotos' => {
            '@type': 'photos',
            'total_count': 1,
            'photos': [
              {
                '@type': 'photo',
                'id': 5,
                'sizes': [
                  {
                    '@type': 'photoSize',
                    'type': 'y',
                    'width': 320,
                    'height': 180,
                    'photo': _fileJson(10, photoPath),
                  },
                ],
              },
            ],
          },
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'mithka-featured-photo-save-',
    );
    photoPath = '${directory.path}/photo.png';
    // A file that really exists, so TdFileCenter.pathFor short-circuits on
    // it instead of arming a download waiter.
    File(photoPath).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> pumpOwnProfile(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          theme: ThemeData(
            extensions: [AppColors.light],
            // Keeps the featured-photo flow on the in-app viewer: profile
            // actions suppress the desktop preview window.
            platform: TargetPlatform.android,
          ),
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ProfileDetailView(userId: 1, name: 'Me'),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'the featured photo sheet saves the open photo and keeps it on screen',
    (tester) async {
      await pumpOwnProfile(tester);

      // The featured strip's tiles are 78x78 tappable squares.
      final tile = find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox && widget.width == 78 && widget.height == 78,
      );
      expect(tile, findsOneWidget, reason: 'the featured strip rendered');
      await tester.tap(tile, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(FullImageViewer), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('image-viewer-more')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey('featured-photo-save')),
        findsOneWidget,
        reason: 'the sheet must offer Save to Photos',
      );
      expect(
        find.byKey(const ValueKey('featured-photo-delete')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('featured-photo-save')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('featured-photo-save')), findsNothing);

      // The save pipeline resolves the file with real IO, which only
      // progresses outside the fake-async zone: alternate runAsync windows
      // with frame pumps until the pipeline has reported.
      // The host has no photo library, so the outcome is the failure toast —
      // proving the row ran the viewer's save pipeline rather than doing
      // nothing.
      var reported = false;
      for (var round = 0; round < 5 && !reported; round++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        reported = find.text("Couldn’t save to Photos.").evaluate().isNotEmpty;
      }
      expect(reported, isTrue, reason: 'the save pipeline reported its result');
      expect(
        find.byType(FullImageViewer),
        findsOneWidget,
        reason: 'saving must not close the viewer',
      );

      // Drain the toast so nothing outlives the test.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text("Couldn’t save to Photos."), findsNothing);

      await tester.tap(find.byKey(const ValueKey('image-viewer-close')));
      // The route's reverse transition needs a few frames to finish.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(FullImageViewer), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
