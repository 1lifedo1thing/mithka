import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/liquid_glass_bottom_bar.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/app_icon_controller.dart';
import 'package:mithka/settings/appearance_view.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('finite-height tab slots fit at larger text scales', (
    tester,
  ) async {
    const labels = ['Chats', 'Channels', 'Contacts', 'Moments'];
    for (final scale in [1.0, 1.4, 2.0]) {
      for (var selected = 0; selected < labels.length; selected++) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(extensions: [AppColors.light]),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 318,
                    child: LiquidGlassBottomBar(
                      selection: selected,
                      itemCount: labels.length,
                      child: SizedBox(
                        height: 62 + (11 * scale - 11) * 1.1,
                        child: Row(
                          children: [
                            for (final label in labels)
                              Expanded(
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          key: ValueKey('scaled-icon-$label'),
                                          width: 36,
                                          height: 28,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          label,
                                          key: ValueKey('scaled-label-$label'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            height: 1.1,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final indicator = find.byKey(const ValueKey('liquid-glass-selection'));
        final decoration =
            tester.widget<DecoratedBox>(indicator).decoration as BoxDecoration;
        final radius = decoration.borderRadius! as BorderRadius;
        final shape = radius.toRRect(tester.getRect(indicator));
        for (final prefix in ['scaled-icon', 'scaled-label']) {
          final bounds = tester.getRect(
            find.byKey(ValueKey('$prefix-${labels[selected]}')),
          );
          for (final point in [
            bounds.topLeft,
            bounds.topRight,
            bounds.bottomLeft,
            bounds.bottomRight,
          ]) {
            expect(
              shape.contains(point),
              isTrue,
              reason: '$prefix, scale $scale, selected $selected',
            );
          }
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass setting defaults off and persists both choices', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    final appIcons = AppIconController(prefs);
    addTearDown(theme.dispose);
    addTearDown(appIcons.dispose);
    expect(theme.liquidGlassBottomBar, isFalse);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: appIcons),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [AppLocalizations.delegate],
          home: AppearanceView(),
        ),
      ),
    );
    final row = find.byKey(const ValueKey('settings-liquid-glass-bottom-bar'));
    expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);
    for (final value in [true, false]) {
      await tester.tap(row);
      await tester.pump();
      expect(theme.liquidGlassBottomBar, value);
      expect(prefs.getBool('liquidGlassBottomBar'), value);
      final restored = ThemeController(prefs);
      expect(restored.liquidGlassBottomBar, value);
      restored.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass respects safe area, RTL, contrast, and reduced motion', (
    tester,
  ) async {
    var selection = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [AppColors.dark]),
        home: MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(bottom: 34),
            disableAnimations: true,
            highContrast: true,
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 320,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return LiquidGlassBottomBar(
                      selection: selection,
                      itemCount: 4,
                      child: const SizedBox(height: 90, width: double.infinity),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final bar = find.byType(LiquidGlassBottomBar);
    final pill = find.byKey(const ValueKey('liquid-glass-selection'));
    final initial = tester.getRect(pill);
    expect(tester.getRect(bar).bottom - initial.bottom, 39);
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isFalse,
    );
    update(() => selection = 3);
    await tester.pump();
    expect(tester.getRect(pill).left, lessThan(initial.left));
    expect(
      tester
          .widget<AnimatedPositionedDirectional>(
            find.byType(AnimatedPositionedDirectional),
          )
          .duration,
      Duration.zero,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection indicator fully covers the selected icon and label', (
    tester,
  ) async {
    // A full stadium (radius = slot height) pulls the corner arcs ~10 px
    // inward at the label row, so the label's lower corners fell outside the
    // filled pill — most visibly on narrow tablet tabs. The indicator must
    // keep a small corner radius so the whole icon+label of the selected tab
    // sits inside the filled shape at any slot size or text scale.
    //
    // The child mirrors the real bottom bar: each slot is an Expanded cell
    // centring an icon block above a label with a 2 px gutter on each side.
    Widget slot(String label) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(key: ValueKey('icon-$label'), width: 36, height: 28),
            const SizedBox(height: 2),
            Text(
              label,
              key: ValueKey('label-$label'),
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            // A narrow tablet slot: sidebar(~328) minus glass chrome, /4.
            child: SizedBox(
              width: 318,
              child: LiquidGlassBottomBar(
                selection: 0,
                itemCount: 4,
                child: Row(
                  children: [
                    Expanded(child: slot('Chats')),
                    Expanded(child: slot('Channels')),
                    Expanded(child: slot('Contacts')),
                    Expanded(child: slot('Moments')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final pill = find.byKey(const ValueKey('liquid-glass-selection'));
    final pr = tester.getRect(pill);
    final radius =
        (tester.widget<DecoratedBox>(pill).decoration as BoxDecoration)
                .borderRadius
            as BorderRadius;
    // Guard against a regression to a full stadium, which is what clipped.
    expect(radius.bottomLeft.y, lessThanOrEqualTo(16));
    expect(radius.bottomLeft.y, isNot(AppRadius.pill));

    bool insideRounded(Offset p) {
      if (!pr.contains(p)) return false;
      final r = radius.bottomLeft.y;
      // Only the corner discs can carve out the bounding box.
      final dx = p.dx < pr.left + r
          ? p.dx - (pr.left + r)
          : p.dx > pr.right - r
          ? p.dx - (pr.right - r)
          : 0.0;
      final dy = p.dy < pr.top + r
          ? p.dy - (pr.top + r)
          : p.dy > pr.bottom - r
          ? p.dy - (pr.bottom - r)
          : 0.0;
      return dx == 0 || dy == 0 || dx * dx + dy * dy <= r * r;
    }

    for (final key in ['icon-Chats', 'label-Chats']) {
      final r = tester.getRect(find.byKey(ValueKey(key)));
      for (final corner in [
        r.topLeft,
        r.topRight,
        r.bottomLeft,
        r.bottomRight,
      ]) {
        expect(
          insideRounded(corner),
          isTrue,
          reason: '$key corner $corner outside the indicator $pr',
        );
      }
    }
    expect(tester.takeException(), isNull);
  });
}
