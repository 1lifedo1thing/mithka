//
//  launch_background_test.dart
//
//  The cold-start surfaces are painted by three different runtimes — the
//  Android starting window, the iOS launch storyboard, and Flutter's first
//  frame — and the user sees every seam between them. These tests pin the
//  three to the same two colours so the launch screen follows the system
//  light/dark appearance instead of flashing white.
//

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/platform/system_ui.dart';
import 'package:mithka/theme/app_theme.dart';

const _androidRes = 'android/app/src/main/res';
const _iosAssets = 'ios/Runner/Assets.xcassets';
const _launchColorName = 'launch_background';
const _iosLaunchColorName = 'LaunchBackground';

String _read(String relativePath) => File(relativePath).readAsStringSync();

/// Parses `#RRGGBB` / `#AARRGGBB` from a color resource named [name].
Color _androidColor(String xml, String name) {
  final match = RegExp(
    '<color\\s+name="$name"\\s*>\\s*(#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8}))\\s*',
  ).firstMatch(xml);
  expect(
    match,
    isNotNull,
    reason: 'Expected a <color name="$name"> resource in:\n$xml',
  );
  final hex = match!.group(1)!.substring(1);
  final value = int.parse(hex, radix: 16);
  return Color(hex.length == 6 ? 0xFF000000 | value : value);
}

/// Reads one sRGB channel of the [appearance] variant of a color set.
///
/// [appearance] is `null` for the "Any Appearance" (light) variant and
/// `'dark'` for the dark-luminosity variant.
double _iosChannel(
  Map<String, dynamic> colorSet,
  String? appearance,
  String channel,
) {
  final colors = colorSet['colors'] as List<dynamic>;
  for (final entry in colors) {
    final variant = entry as Map<String, dynamic>;
    final appearances = variant['appearances'] as List<dynamic>?;
    String? luminosity;
    for (final a in appearances ?? const <dynamic>[]) {
      final map = a as Map<String, dynamic>;
      if (map['appearance'] == 'luminosity') {
        luminosity = map['value'] as String?;
      }
    }
    if (luminosity != appearance) continue;
    final components =
        ((variant['color'] as Map<String, dynamic>)['components'])
            as Map<String, dynamic>;
    return double.parse(components[channel]!.toString());
  }
  fail('No ${appearance ?? "light"} variant in $colorSet');
}

Color _iosColor(Map<String, dynamic> colorSet, String? appearance) =>
    Color.fromRGBO(
      (_iosChannel(colorSet, appearance, 'red') * 255).round(),
      (_iosChannel(colorSet, appearance, 'green') * 255).round(),
      (_iosChannel(colorSet, appearance, 'blue') * 255).round(),
      1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final lightLaunch = launchBackgroundColorFor(Brightness.light);
  final darkLaunch = launchBackgroundColorFor(Brightness.dark);

  group('launch background token', () {
    test('matches the app surface the first Flutter frame paints', () {
      expect(lightLaunch, AppColors.light.background);
      expect(darkLaunch, AppColors.dark.background);
      // A dark launch screen that was near-black-but-not-the-app would still
      // read as a jump; the dark surface is deliberately not pure black.
      expect(darkLaunch, isNot(Colors.black));
    });
  });

  group('Android', () {
    test('launch color is night-qualified and matches the app surfaces', () {
      expect(
        _androidColor(
          _read('$_androidRes/values/colors.xml'),
          _launchColorName,
        ),
        lightLaunch,
        reason: 'values/colors.xml must pin the light launch background',
      );
      expect(
        _androidColor(
          _read('$_androidRes/values-night/colors.xml'),
          _launchColorName,
        ),
        darkLaunch,
        reason: 'values-night/colors.xml must pin the dark launch background',
      );
    });

    test('launch drawables reference the color, never hardcoded white', () {
      for (final path in [
        '$_androidRes/drawable/launch_background.xml',
        '$_androidRes/drawable-v21/launch_background.xml',
      ]) {
        final xml = _read(path);
        expect(
          xml,
          contains('@color/$_launchColorName'),
          reason: '$path must resolve through the night-qualified color',
        );
        expect(xml, isNot(contains('@android:color/white')), reason: path);
        expect(
          xml,
          isNot(contains('?android:colorBackground')),
          reason:
              '$path resolves to AppCompat grey (#FAFAFA/#303030), which does '
              'not match the app surface and reads as a flash',
        );
      }
    });

    test('every launch and normal theme paints the same background', () {
      final styleFiles = [
        '$_androidRes/values/styles.xml',
        '$_androidRes/values-night/styles.xml',
        '$_androidRes/values-v29/styles.xml',
        '$_androidRes/values-night-v29/styles.xml',
      ];
      for (final path in styleFiles) {
        final xml = _read(path);
        String style(String name) {
          final match = RegExp(
            '<style name="$name".*?</style>',
            dotAll: true,
          ).firstMatch(xml);
          expect(match, isNotNull, reason: '$path must define $name');
          return match!.group(0)!;
        }

        // LaunchTheme paints the splash drawable, whose only layer is the
        // night-qualified colour checked above.
        final launchTheme = style('LaunchTheme');
        expect(
          launchTheme,
          contains(
            '<item name="android:windowBackground">@drawable/launch_background</item>',
          ),
          reason: 'LaunchTheme in $path must paint the splash drawable',
        );
        // NormalTheme is the window behind Flutter's first frame. It must not
        // resolve to AppCompat's grey colorBackground, or removing the splash
        // changes the colour on screen.
        final normalTheme = style('NormalTheme');
        expect(
          normalTheme,
          contains(
            '<item name="android:windowBackground">@color/$_launchColorName</item>',
          ),
          reason:
              'NormalTheme in $path must use the launch colour so the window '
              'behind the first Flutter frame matches the splash',
        );
        expect(
          launchTheme + normalTheme,
          isNot(contains('?android:colorBackground')),
          reason: '$path still resolves through AppCompat grey',
        );
        // Android 12+ replaces the windowBackground drawable with the system
        // splash screen, whose background comes from this attribute instead.
        expect(
          launchTheme,
          contains(
            '<item name="android:windowSplashScreenBackground">'
            '@color/$_launchColorName</item>',
          ),
          reason: 'LaunchTheme in $path must theme the Android 12+ splash',
        );
      }
    });
  });

  group('iOS', () {
    late Map<String, dynamic> colorSet;

    setUpAll(() {
      colorSet =
          jsonDecode(
                _read(
                  '$_iosAssets/$_iosLaunchColorName.colorset/Contents.json',
                ),
              )
              as Map<String, dynamic>;
    });

    test('launch color set ships light and dark variants', () {
      expect(_iosColor(colorSet, null), lightLaunch);
      expect(_iosColor(colorSet, 'dark'), darkLaunch);
      final dark =
          (colorSet['colors'] as List<dynamic>).firstWhere(
                (entry) =>
                    ((entry as Map<String, dynamic>)['appearances']
                            as List<dynamic>?)
                        ?.any(
                          (a) =>
                              (a as Map<String, dynamic>)['appearance'] ==
                                  'luminosity' &&
                              a['value'] == 'dark',
                        ) ==
                    true,
              )
              as Map<String, dynamic>;
      expect(
        (dark['color'] as Map<String, dynamic>)['color-space'],
        'srgb',
        reason: 'The color set must use the sRGB space the app tokens use',
      );
    });

    test('launch storyboard and root view follow the named color', () {
      for (final path in [
        'ios/Runner/Base.lproj/LaunchScreen.storyboard',
        'ios/Runner/Base.lproj/Main.storyboard',
      ]) {
        final storyboard = _read(path);
        // This is the markup Interface Builder itself writes for an asset
        // catalog color: a named reference on the view plus a design-time
        // <namedColor> preview. At runtime the catalog's light/dark variant
        // resolves, which is what makes the launch screen adaptive.
        expect(
          storyboard,
          contains(
            '<color key="backgroundColor" name="$_iosLaunchColorName"/>',
          ),
          reason: '$path must paint the adaptive launch color',
        );
        expect(
          storyboard,
          contains('<namedColor name="$_iosLaunchColorName">'),
          reason: '$path must declare the named color resource',
        );
        expect(
          storyboard,
          contains('<capability name="Named colors" minToolsVersion="9.0"/>'),
          reason: '$path must declare the named-color capability',
        );
        expect(
          storyboard,
          isNot(
            contains('<color key="backgroundColor" red="1" green="1" blue="1"'),
          ),
          reason: '$path still hardcodes a white background',
        );
      }
    });
  });

  group('system bars during launch', () {
    tearDown(() {
      TestWidgetsFlutterBinding.instance.platformDispatcher
          .clearPlatformBrightnessTestValue();
    });

    test('dark launches use light bar icons', () {
      TestWidgetsFlutterBinding
              .instance
              .platformDispatcher
              .platformBrightnessTestValue =
          Brightness.dark;

      // The style must follow the system brightness, not a hardcoded light
      // launch: dark background + dark icons is invisible for the whole start.
      expect(
        systemUiOverlayStyleFor(platformBrightness).statusBarIconBrightness,
        Brightness.light,
      );
      expect(
        systemUiOverlayStyleFor(
          platformBrightness,
        ).systemNavigationBarIconBrightness,
        Brightness.light,
      );
      expect(
        systemUiOverlayStyleFor(platformBrightness).statusBarColor,
        Colors.transparent,
      );
    });

    test('light launches use dark bar icons', () {
      TestWidgetsFlutterBinding
              .instance
              .platformDispatcher
              .platformBrightnessTestValue =
          Brightness.light;

      expect(
        systemUiOverlayStyleFor(platformBrightness).statusBarIconBrightness,
        Brightness.dark,
      );
      expect(
        systemUiOverlayStyleFor(
          platformBrightness,
        ).systemNavigationBarIconBrightness,
        Brightness.dark,
      );
    });
  });

  group('first Flutter frame', () {
    test('the root fills with the same color the native splash used', () {
      final main = _read('lib/main.dart');
      expect(
        main,
        contains('color: context.colors.background,'),
        reason:
            'The root builder must fill with the themed surface so removing '
            'the native splash cannot expose a differently colored window',
      );
      expect(
        main,
        contains('themeMode: theme.themeMode,'),
        reason:
            'MaterialApp must resolve brightness from the persisted '
            'appearance mode, or the first frame ignores the user setting',
      );
    });

    testWidgets('dark mode: the viewport-filling root is the dark colour', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.light,
            extensions: [AppColors.light],
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            extensions: [AppColors.dark],
          ),
          // ThemeMode.system is MaterialApp's default, so it is omitted; the
          // first frame must still follow the platform brightness.
          home: Builder(
            builder: (context) => ColoredBox(
              color: context.colors.background,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final box = tester.widgetList<ColoredBox>(find.byType(ColoredBox)).last;
      expect(
        box.color,
        darkLaunch,
        reason:
            'The first frame in dark mode must be the dark launch colour, not '
            'white — a mismatch is exactly the flash this branch removes',
      );
    });

    testWidgets('light mode: the viewport-filling root is the light colour', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.light,
            extensions: [AppColors.light],
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            extensions: [AppColors.dark],
          ),
          home: Builder(
            builder: (context) => ColoredBox(
              color: context.colors.background,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final box = tester.widgetList<ColoredBox>(find.byType(ColoredBox)).last;
      expect(box.color, lightLaunch);
    });
  });
}
