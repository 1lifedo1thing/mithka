import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/communities/community_edit_view.dart';
import 'package:mithka/communities/community_models.dart';
import 'package:mithka/communities/community_view.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/edit_field_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The community profile editor mirrors the iOS CommunityEditScreen: the hub's
// ellipsis menu gains an Edit Profile entry only for creators and admins
// holding can_change_info, the name round-trips through setCommunityName, and
// a TDLib too old to know the method answers with a parse-level error that
// must surface as an explicit "not supported yet" toast rather than a generic
// failure.
//
// The editor also owns an execution boundary the menu alone cannot promise:
// can_change_info is re-checked after every await (the summary is shared with
// the hub, so an updateCommunity merge can revoke it mid-flow), writes stay
// pinned to the client of the account that opened the route, and disposal
// cancels stale work so nothing writes or mutates afterwards.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final requests = <Map<String, dynamic>>[];
  // Set by the unsupported-method test so setCommunityName answers with the
  // parse-level error a pinned pre-1.8.68 tdjson produces.
  var rejectCommunityName = false;
  var rejectCommunityPhoto = false;
  // Per-request-type gates that hold a write in flight, keyed by '@type'.
  final heldQueries = <String, Completer<Map<String, dynamic>>>{};

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(Map<String, dynamic>.from(request));
          if (request['@type'] == 'setCommunityName' && rejectCommunityName) {
            return {
              '@type': 'error',
              'code': 400,
              'message': 'Failed to parse JSON object as TDLib request',
            };
          }
          if (request['@type'] == 'setCommunityPhoto' && rejectCommunityPhoto) {
            return {'@type': 'error', 'code': 400, 'message': 'PHOTO_INVALID'};
          }
          final held = heldQueries[request['@type'] as String];
          if (held != null) return held.future;
          return {'@type': 'ok'};
        },
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  setUp(() {
    requests.clear();
    heldQueries.clear();
  });

  CommunitySummary community({required bool canChangeInfo}) => CommunitySummary(
    id: 42,
    name: 'Formula Paddock',
    haveAccess: true,
    isAdministrator: canChangeInfo,
    canEditChatList: true,
    canChangeInfo: canChangeInfo,
  );

  Future<void> pumpHome(
    WidgetTester tester,
    Widget home, {
    bool settle = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  group('canChangeInfo', () {
    test('the creator status carries the right', () {
      final parsed = CommunitySummary.fromTd({
        '@type': 'community',
        'id': '42',
        'have_access': true,
        'name': 'Formula Paddock',
        'status': {'@type': 'communityMemberStatusCreator'},
      });
      expect(parsed.canChangeInfo, isTrue);
    });

    test('an administrator needs can_change_info in the rights', () {
      final withoutRight = CommunitySummary.fromTd({
        '@type': 'community',
        'id': '42',
        'name': 'Formula Paddock',
        'status': {
          '@type': 'communityMemberStatusAdministrator',
          'rights': {
            '@type': 'communityAdministratorRights',
            'can_edit_chat_list': true,
          },
        },
      });
      expect(withoutRight.canChangeInfo, isFalse);

      final withRight = CommunitySummary.fromTd({
        '@type': 'community',
        'id': '42',
        'name': 'Formula Paddock',
        'status': {
          '@type': 'communityMemberStatusAdministrator',
          'rights': {
            '@type': 'communityAdministratorRights',
            'can_change_info': true,
          },
        },
      });
      expect(withRight.canChangeInfo, isTrue);
    });

    test('merge keeps the flag when TDLib re-delivers the community', () {
      final source = community(canChangeInfo: true);
      final target = community(canChangeInfo: false);
      target.merge(source);
      expect(target.canChangeInfo, isTrue);
    });
  });

  testWidgets('the hub menu hides Edit Profile without the right', (
    tester,
  ) async {
    await pumpHome(
      tester,
      CommunityView(
        community: community(canChangeInfo: false),
        chats: const [],
        onCollapsedChanged: (_) {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('community-header-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Show as One Chat'), findsOneWidget);
    expect(find.text('Edit Profile'), findsNothing);

    // Close the menu so nothing outlives the test.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('the hub menu opens the editor with the right', (tester) async {
    await pumpHome(
      tester,
      CommunityView(
        community: community(canChangeInfo: true),
        chats: const [],
        onCollapsedChanged: (_) {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('community-header-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Edit Profile'), findsOneWidget);

    await tester.tap(find.text('Edit Profile'));
    await tester.pumpAndSettle();
    expect(find.byType(CommunityEditView), findsOneWidget);
    // The editor renders the name in the avatar card and the row value.
    expect(find.text('Formula Paddock'), findsNWidgets(2));

    // Pop back via the editor's chevron so the route settles before teardown.
    // pageBack() can't be used: the app's NavHeader owns a custom back control.
    await tester.tap(find.byIcon(HeroAppIcons.chevronLeft.data));
    await tester.pumpAndSettle();
  });

  testWidgets('saving a name round-trips through setCommunityName', (
    tester,
  ) async {
    final summary = community(canChangeInfo: true);
    await pumpHome(
      tester,
      CommunityEditView(community: summary),
      settle: false,
    );
    // SettingsListView settles without any pending animation, but a fixed
    // frame budget keeps this pump independent of scaffold transitions.
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('community-edit-name')));
    await tester.pumpAndSettle();
    expect(find.byType(EditFieldView), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Paddock Club');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final request = requests.last;
    expect(request['@type'], 'setCommunityName');
    expect(request['community_id'], 42);
    expect(request['name'], 'Paddock Club');

    // The editor mutates the shared summary in place, so the hub header and
    // the row both reflect the new name without a re-fetch.
    expect(summary.name, 'Paddock Club');
    expect(find.text('Paddock Club'), findsWidgets);
    expect(find.text('Formula Paddock'), findsNothing);
  });

  testWidgets('an old TDLib library degrades into the unsupported toast', (
    tester,
  ) async {
    rejectCommunityName = true;
    addTearDown(() => rejectCommunityName = false);

    await pumpHome(
      tester,
      CommunityEditView(community: community(canChangeInfo: true)),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('community-edit-name')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Paddock Club');
    await tester.tap(find.text('Save'));

    // The error toast rides an overlay timer, so it needs discrete pumps to
    // appear and to drain before teardown.
    const toast = 'The bundled TDLib build doesn’t support this yet';
    var reported = false;
    for (var round = 0; round < 6 && !reported; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      reported = find.text(toast).evaluate().isNotEmpty;
    }
    expect(reported, isTrue, reason: 'the unsupported toast is visible');

    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(toast), findsNothing);

    // The editor stayed on screen and the name was not applied locally.
    expect(find.byType(CommunityEditView), findsOneWidget);
    // The editor renders the name in the avatar card and the row value.
    expect(find.text('Formula Paddock'), findsNWidgets(2));
  });

  group('execution re-checks the current permission', () {
    testWidgets('a right revoked mid-session sends no write', (tester) async {
      final summary = community(canChangeInfo: true);
      await pumpHome(
        tester,
        CommunityEditView(community: summary),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const ValueKey('community-edit-name')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Paddock Club');

      // The shared summary is mutated externally — the hub's updateCommunity
      // merge landing while the field sheet is open — revoking the right
      // between opening the editor and pressing Save.
      summary.canChangeInfo = false;

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // The focused recording-transport assertion: no setCommunityName is
      // sent for community 42 even though the menu had offered the editor.
      expect(
        requests.where((request) => request['@type'] == 'setCommunityName'),
        isEmpty,
      );
      expect(summary.name, 'Formula Paddock');

      // The honest failure surfaces as the save-failed toast, not silence.
      const toast = 'Couldn’t save the community name';
      var reported = false;
      for (var round = 0; round < 6 && !reported; round++) {
        await tester.pump(const Duration(milliseconds: 100));
        reported = find.text(toast).evaluate().isNotEmpty;
      }
      expect(reported, isTrue, reason: 'the revoked-right toast is visible');
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(toast), findsNothing);
    });

    testWidgets('a revoked right stops the photo write the same way', (
      tester,
    ) async {
      final summary = community(canChangeInfo: true);
      await pumpHome(
        tester,
        CommunityEditView(community: summary),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      final editor = tester.state(find.byType(CommunityEditView));
      summary.canChangeInfo = false;
      await (editor as dynamic).savePhotoForTesting('/tmp/avatar.jpg');
      await tester.pumpAndSettle();

      expect(
        requests.where((request) => request['@type'] == 'setCommunityPhoto'),
        isEmpty,
      );
      // The honest error still surfaces for the photo path.
      const toast = 'Couldn’t update the community photo';
      var reported = false;
      for (var round = 0; round < 6 && !reported; round++) {
        await tester.pump(const Duration(milliseconds: 100));
        reported = find.text(toast).evaluate().isNotEmpty;
      }
      expect(reported, isTrue, reason: 'the photo revoked-right toast shows');
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  });

  group('execution pins writes to the source account', () {
    testWidgets('a switched active account fails the write without sending', (
      tester,
    ) async {
      // The shared TdClient cannot switch under a configured proxy, so the
      // switch is driven through the same live probe seam the repo uses for
      // switch-race tests (AppearancePreviewRepository's activeClientId).
      var activeClientId = 1;
      final summary = community(canChangeInfo: true);
      await pumpHome(
        tester,
        CommunityEditView(
          community: summary,
          activeClientId: () => activeClientId,
          activeSlot: () => 0,
        ),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const ValueKey('community-edit-name')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Paddock Club');

      // The foreground account switches while the field sheet is open: the
      // editor's route-time owner is no longer the active account, so the
      // stale flow must fail instead of writing through the new account.
      activeClientId = 2;

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        requests.where((request) => request['@type'] == 'setCommunityName'),
        isEmpty,
        reason: 'no write may reach the other account',
      );
      expect(summary.name, 'Formula Paddock');

      // The stale-flow failure surfaced as the save-failed toast; drain its
      // timer so no pending work outlives the test.
      const toast = 'Couldn’t save the community name';
      var reported = false;
      for (var round = 0; round < 6 && !reported; round++) {
        await tester.pump(const Duration(milliseconds: 100));
        reported = find.text(toast).evaluate().isNotEmpty;
      }
      expect(reported, isTrue, reason: 'the switched-account toast shows');
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });

    testWidgets('a failed photo upload reports the error, mutating nothing', (
      tester,
    ) async {
      rejectCommunityPhoto = true;
      addTearDown(() => rejectCommunityPhoto = false);

      final summary = community(canChangeInfo: true);
      await pumpHome(
        tester,
        CommunityEditView(community: summary),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      final editor = tester.state(find.byType(CommunityEditView));
      await (editor as dynamic).savePhotoForTesting('/tmp/avatar.jpg');
      await tester.pumpAndSettle();

      // The request was issued once, the failure surfaced as the photo-save
      // toast, and no partial state mutation survived it.
      expect(
        requests.where((request) => request['@type'] == 'setCommunityPhoto'),
        hasLength(1),
      );
      const toast = 'Couldn’t update the community photo';
      var reported = false;
      for (var round = 0; round < 6 && !reported; round++) {
        await tester.pump(const Duration(milliseconds: 100));
        reported = find.text(toast).evaluate().isNotEmpty;
      }
      expect(reported, isTrue, reason: 'the photo failure toast is visible');
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(toast), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('disposal cancels stale work', () {
    testWidgets('disposing mid-name-save mutates nothing after dispose', (
      tester,
    ) async {
      final summary = community(canChangeInfo: true);
      await pumpHome(
        tester,
        CommunityEditView(community: summary),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      final editor = tester.state(find.byType(CommunityEditView));
      final held = Completer<Map<String, dynamic>>();
      heldQueries['setCommunityName'] = held;

      // The save is in flight when the route is torn down (the account
      // switcher replaced the stack under it).
      final saving = (editor as dynamic).saveNameForTesting('Paddock Club');
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      held.complete({'@type': 'ok'});
      await saving;
      await tester.pump();

      // No setState-after-dispose exception, and the shared summary never
      // advanced: nothing applied the write after the editor went away.
      expect(tester.takeException(), isNull);
      expect(summary.name, 'Formula Paddock');
      expect(
        requests.where((request) => request['@type'] == 'setCommunityName'),
        isNotEmpty,
      );
    });

    testWidgets('disposing mid-photo-upload mutates nothing after dispose', (
      tester,
    ) async {
      final summary = community(canChangeInfo: true);
      await pumpHome(
        tester,
        CommunityEditView(community: summary),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      final editor = tester.state(find.byType(CommunityEditView));
      final held = Completer<Map<String, dynamic>>();
      heldQueries['setCommunityPhoto'] = held;

      final saving = (editor as dynamic).savePhotoForTesting('/tmp/a.jpg');
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      held.complete({'@type': 'ok'});
      await saving;
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The photo-success toast and refresh never fired after disposal.
      expect(find.text('Community photo updated'), findsNothing);
      expect(
        requests.where((request) => request['@type'] == 'setCommunityPhoto'),
        isNotEmpty,
      );
    });
  });
}
