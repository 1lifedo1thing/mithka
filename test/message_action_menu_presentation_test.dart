import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/message_action_menu_presentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    required bool visible,
    required VoidCallback onExitComplete,
    Offset? anchor,
    bool reducedMotion = false,
    Widget? child,
  }) => MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 400,
        height: 800,
        child: MessageActionMenuPresentation(
          visible: visible,
          anchor: anchor,
          onExitComplete: onExitComplete,
          child: child ?? const ColoredBox(color: Colors.black),
        ),
      ),
    ),
  );

  Finder scaleTransform() => find.descendant(
    of: find.byKey(MessageActionMenuPresentation.rootKey),
    matching: find.byType(Transform),
  );

  double scaleOf(WidgetTester tester) =>
      // storage[0] is the X scale factor; getMaxScaleOnAxis would fold in the
      // Z column, which a 2D scale leaves at 1.0.
      tester.widget<Transform>(scaleTransform()).transform.storage[0];

  Finder fadeTransition() => find.descendant(
    of: find.byKey(MessageActionMenuPresentation.rootKey),
    matching: find.byType(FadeTransition),
  );

  test('the anchor maps into the overlay-relative scale alignment', () {
    const size = Size(400, 800);
    expect(
      MessageActionMenuPresentation.alignmentForAnchor(null, size),
      Alignment.center,
    );
    // Top-left of the overlay.
    expect(
      MessageActionMenuPresentation.alignmentForAnchor(Offset.zero, size),
      Alignment.topLeft,
    );
    // Three quarters across, one quarter down.
    expect(
      MessageActionMenuPresentation.alignmentForAnchor(
        const Offset(300, 200),
        size,
      ),
      const Alignment(0.5, -0.5),
    );
    // Out-of-bounds anchors clamp instead of inverting the scale.
    expect(
      MessageActionMenuPresentation.alignmentForAnchor(
        const Offset(-10, 900),
        size,
      ),
      Alignment.bottomLeft,
    );
    expect(
      MessageActionMenuPresentation.alignmentForAnchor(Offset.zero, Size.zero),
      Alignment.center,
    );
  });

  testWidgets('enter fades and scales the surfaces up, exit plays it back', (
    tester,
  ) async {
    var exits = 0;
    await tester.pumpWidget(
      host(visible: false, onExitComplete: () => exits++),
    );
    // Mounted straight into a close: no exit to play, reported at once.
    await tester.pump();
    expect(exits, 1);

    await tester.pumpWidget(host(visible: true, onExitComplete: () => exits++));
    await tester.pump(const Duration(milliseconds: 100));
    expect(fadeTransition(), findsOneWidget);
    final midEnter = tester.widget<FadeTransition>(fadeTransition()).opacity;
    expect(midEnter.value, lessThan(1));
    expect(midEnter.value, greaterThan(0));
    final midScale = scaleOf(tester);
    expect(midScale, lessThan(1));
    expect(
      midScale,
      greaterThanOrEqualTo(MessageActionMenuPresentation.surfaceScale),
    );

    await tester.pumpAndSettle();
    expect(exits, 1, reason: 'a settled enter reports no exit');
    expect(tester.widget<FadeTransition>(fadeTransition()).opacity.value, 1);

    await tester.pumpWidget(
      host(visible: false, onExitComplete: () => exits++),
    );
    await tester.pump(const Duration(milliseconds: 60));
    // The exit is a transition, not a cut: still mounted and partially faded.
    expect(fadeTransition(), findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeTransition()).opacity.value,
      lessThan(1),
    );
    expect(exits, 1, reason: 'the exit has not landed yet');
    await tester.pumpAndSettle();
    expect(exits, 2);
  });

  testWidgets('the closing surface ignores taps until the exit lands', (
    tester,
  ) async {
    var taps = 0;
    Widget build({required bool visible}) => host(
      visible: visible,
      onExitComplete: () {},
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: const SizedBox.expand(child: ColoredBox(color: Colors.black)),
      ),
    );

    await tester.pumpWidget(build(visible: true));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 400));
    expect(taps, 1);

    await tester.pumpWidget(build(visible: false));
    await tester.pump();
    // Mid-exit the surface is still painted but must not receive taps: its
    // actions target state the host has already released.
    await tester.tapAt(const Offset(200, 400));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('a re-open mid-exit resumes forward without a stale exit', (
    tester,
  ) async {
    var exits = 0;
    Widget build({required bool visible}) =>
        host(visible: visible, onExitComplete: () => exits++);

    await tester.pumpWidget(build(visible: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build(visible: false));
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.widget<FadeTransition>(fadeTransition()).opacity.value,
      lessThan(1),
    );
    // Long-pressing another message while the previous menu is still
    // collapsing must bring the new menu in, not report an exit.
    await tester.pumpWidget(build(visible: true));
    await tester.pumpAndSettle();
    expect(exits, 0);
    expect(tester.widget<FadeTransition>(fadeTransition()).opacity.value, 1);
  });

  testWidgets('reduced motion collapses both phases to instant states', (
    tester,
  ) async {
    var exits = 0;
    Widget build({required bool visible}) => host(
      visible: visible,
      onExitComplete: () => exits++,
      reducedMotion: true,
    );

    await tester.pumpWidget(build(visible: true));
    await tester.pump();
    expect(
      tester.widget<FadeTransition>(fadeTransition()).opacity.value,
      1,
      reason: 'no fade-in under reduced motion',
    );

    await tester.pumpWidget(build(visible: false));
    await tester.pump();
    expect(exits, 1, reason: 'the zero-length exit reports immediately');
  });
}
