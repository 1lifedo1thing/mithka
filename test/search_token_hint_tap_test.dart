import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_search_query.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/components/keyboard_dismiss_on_tap.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';

/// The title-bar search's floating filter hints are dead taps: the app
/// dismisses the keyboard on every pointer down outside the focused field
/// (`AppKeyboardDismissOnTap`), a hint row sits outside it, and the desktop
/// controller rebuilds on unfocus ([DesktopInlineSearchController] listens to
/// its focus node), so the whole panel collapses to `SizedBox.shrink` on the
/// press - the up lands on nothing and `startToken` never runs.
///
/// A synchronous `tester.tap` cannot see that (down and up land in one frame,
/// before the rebuild), so the failing tests below split the gesture the way a
/// finger does: press, let the frame the down triggers land, release.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;
  late List<Map<String, dynamic>> requests;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(Map<String, dynamic>.from(request));
          return <String, dynamic>{'@type': 'ok'};
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  setUp(() => requests = []);

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  Future<DesktopInlineSearchController> pumpField(WidgetTester tester) async {
    final controller = DesktopInlineSearchController(
      miniAppSearch: (_) async => const [],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: Scaffold(
          body: AppKeyboardDismissOnTap(
            child: Column(
              children: [
                DesktopInlineSearchField(
                  controller: controller,
                  onSearchAll: (_) {},
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: DesktopInlineSearchPanel(
                      controller: controller,
                      onSearchAll: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.focus();
    await tester.pump();
    expect(find.byKey(const ValueKey('searchTokenHints')), findsOneWidget);
    return controller;
  }

  testWidgets('a hint tap starts its token while taps dismiss the keyboard', (
    tester,
  ) async {
    final controller = await pumpField(tester);

    // Press, let the frame the down triggers land, then release - the
    // timeline a finger produces on a real device.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('searchTokenHint-has:'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();

    expect(controller.textController.text, 'has:');
    // `has:` names a closed vocabulary, so it becomes a filter once the kind
    // is typed — the tap only has to leave the field ready for it.
    await tester.enterText(
      find.byKey(const ValueKey('desktop-title-bar-search-input')),
      'has: music',
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    final filters = requests
        .where((request) => request['@type'] == 'searchMessages')
        .map((request) => request['filter'])
        .cast<Map<String, dynamic>>()
        .toList();
    expect(filters, isNotEmpty);
    // The panel fans out over its message categories; the audio category must
    // be among them — that is `has: music` reaching TDLib.
    expect(
      filters.any((filter) => filter['@type'] == 'searchMessagesFilterAudio'),
      isTrue,
    );
  });

  testWidgets('a from hint tap opens the sender autocompletion', (
    tester,
  ) async {
    final controller = await pumpField(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('searchTokenHint-from:'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.textController.text, 'from:');
    // The token is live: the panel now answers with the sender suggestions the
    // hint promised instead of results for a half-written filter.
    expect(controller.activeToken?.kind, ChatSearchTokenKind.from);
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(
      requests.where((request) => request['@type'] == 'searchContacts'),
      isNotEmpty,
      reason: 'the empty from: token offers the contact list to pick from',
    );
  });

  testWidgets('a tap outside the field still dismisses the keyboard', (
    tester,
  ) async {
    final controller = await pumpField(tester);
    expect(controller.focusNode.hasFocus, isTrue);

    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();

    expect(controller.focusNode.hasFocus, isFalse);
  });

  testWidgets(
    'selection toolbar stays inside the search tap region',
    (tester) async {
      final controller = await pumpField(tester);
      final field = find.byKey(
        const ValueKey('desktop-title-bar-search-input'),
      );
      await tester.enterText(field, 'Selected text');
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      editable.widget.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 8,
      );
      await tester.pump();
      editable.showToolbar();
      await tester.pumpAndSettle();
      final cut = find.text('Cut');
      expect(cut, findsOneWidget);
      final press = await tester.startGesture(tester.getCenter(cut));
      await tester.pump();
      expect(
        controller.focusNode.hasFocus,
        isTrue,
        reason: 'selection actions must not trigger outside-tap dismissal',
      );
      await press.up();
      await tester.pumpAndSettle();
      expect(controller.textController.text, ' text');
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
