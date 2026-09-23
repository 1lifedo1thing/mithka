import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/app_interactive_surface.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/retain_download_button.dart';
import 'package:mithka/settings/retained_download_store.dart';
import 'package:mithka/settings/retained_downloads_panel.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late File source;
  late RetainedDownloadStore store;
  late StreamController<Map<String, dynamic>> updates;
  late List<Map<String, dynamic>> requests;
  var userId = 100;
  const slot = 7;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  Map<String, dynamic> file({
    bool complete = true,
    String identity = 'video-1',
  }) => {
    '@type': 'file',
    'id': 20,
    'size': 5,
    'remote': {'unique_id': identity},
    'local': {
      'path': source.path,
      'is_downloading_completed': complete,
      'downloaded_size': 5,
    },
  };

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: slot,
        query: (request) async {
          requests.add(request);
          return switch (request['@type']) {
            'getMe' => {'@type': 'user', 'id': userId},
            'getFile' => file(),
            _ => throw StateError('Unexpected request'),
          };
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('mithka-retained-test-');
    source = await File(
      '${temporary.path}/cached-video',
    ).writeAsBytes([1, 2, 3, 4, 5]);
    store = RetainedDownloadStore(Directory('${temporary.path}/retained'));
    requests = [];
    userId = 100;
    messenger.setMockMethodCallHandler(paths, (call) async => temporary.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    await temporary.delete(recursive: true);
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  test(
    'retained bytes and index survive cache deletion and store restart',
    () async {
      final entry = await store.keep(
        file: file(),
        title: 'clip.mp4',
        isVideo: true,
      );
      expect(entry.path, isNot(source.path));
      await source.delete();
      final reopened = RetainedDownloadStore(store.directory);
      final listed = await reopened.list();
      expect(listed.single.id, entry.id);
      expect(listed.single.isVideo, isTrue);
      expect(listed.single.size, 5);
      expect(await File(listed.single.path).readAsBytes(), [1, 2, 3, 4, 5]);
    },
  );

  test(
    'partial bytes are never published even when their size matches',
    () async {
      await expectLater(
        store.keep(
          file: file(complete: false),
          title: 'clip.mp4',
          isVideo: true,
        ),
        throwsStateError,
      );
      expect(await store.list(), isEmpty);
      expect(await source.exists(), isTrue);
    },
  );

  test('missing or truncated complete cache is rejected', () async {
    final stale = file();
    await source.writeAsBytes([1, 2]);
    await expectLater(
      store.keep(file: stale, title: 'clip.mp4', isVideo: true),
      throwsStateError,
    );
    await source.delete();
    await expectLater(
      store.keep(file: stale, title: 'clip.mp4', isVideo: true),
      throwsStateError,
    );
    expect(await store.list(), isEmpty);
  });

  test(
    'failed storage writes do not remove the source or advertise success',
    () async {
      final obstruction = await File(
        '${temporary.path}/not-a-directory',
      ).writeAsString('unrelated');
      final blocked = RetainedDownloadStore(Directory(obstruction.path));
      await expectLater(
        blocked.keep(file: file(), title: 'clip.mp4', isVideo: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await source.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await obstruction.readAsString(), 'unrelated');
    },
  );

  test(
    'concurrent saves of the same remote file publish one complete copy',
    () async {
      final saved = await Future.wait([
        store.keep(file: file(), title: 'first.mp4', isVideo: true),
        store.keep(file: file(), title: 'second.mp4', isVideo: true),
      ]);
      expect(saved[0].id, saved[1].id);
      expect(await store.list(), hasLength(1));
      expect(await store.directory.list().toList(), hasLength(1));
    },
  );

  test(
    'matching filenames and reused numeric file ids do not overwrite copies',
    () async {
      final first = await store.keep(
        file: file(),
        title: 'clip.mp4',
        isVideo: true,
      );
      await source.writeAsBytes([6, 7, 8, 9, 0]);
      final second = await store.keep(
        file: file(identity: 'video-2'),
        title: 'clip.mp4',
        isVideo: true,
      );
      expect(first.id, isNot(second.id));
      expect(await File(first.path).readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await File(second.path).readAsBytes(), [6, 7, 8, 9, 0]);
      expect(await store.list(), hasLength(2));
    },
  );

  test(
    'unsafe and long filenames stay inside their own entry directory',
    () async {
      for (final name in [
        '../../report.pdf',
        r'C:\private\report.pdf',
        'entry.json',
        'CON.txt',
        '${'字' * 150}.mp4',
        '...',
      ]) {
        final entry = await store.keep(
          file: file(identity: name),
          title: name,
          isVideo: false,
        );
        expect(
          File(entry.path).parent.path,
          '${store.directory.path}/${entry.id}',
        );
        expect(entry.fileName, isNot(contains(RegExp(r'[/\\]'))));
        expect(entry.fileName, isNot('entry.json'));
        expect(utf8.encode(entry.fileName).length, lessThanOrEqualTo(176));
        expect(await File(entry.path).length(), 5);
      }
    },
  );

  test(
    'pending copies, symlinks and corrupt metadata are not listed',
    () async {
      await store.directory.create(recursive: true);
      await Directory('${store.directory.path}/.pending-interrupted').create();
      final id = 'a' * 64;
      await Link('${store.directory.path}/$id').create(temporary.path);
      expect(await store.list(), isEmpty);
      await expectLater(store.remove(id), throwsStateError);
      expect(await source.exists(), isTrue);
      final entry = await store.keep(
        file: file(),
        title: 'clip.mp4',
        isVideo: true,
      );
      final metadata = File('${store.directory.path}/${entry.id}/entry.json');
      final raw =
          jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      raw['file_name'] = '../../cached-video';
      await metadata.writeAsString(jsonEncode(raw));
      expect(await store.list(), isEmpty);
      await expectLater(store.remove(entry.id), throwsStateError);
      expect(await source.exists(), isTrue);
      await expectLater(store.remove('../cached-video'), throwsArgumentError);
    },
  );

  test('explicit deletion removes only the selected retained copy', () async {
    final first = await store.keep(
      file: file(),
      title: 'clip.mp4',
      isVideo: true,
    );
    final second = await store.keep(
      file: file(identity: 'other'),
      title: 'notes.pdf',
      isVideo: false,
    );
    await store.remove(first.id);
    expect(await File(first.path).exists(), isFalse);
    expect(await source.exists(), isTrue);
    expect(await File(second.path).exists(), isTrue);
    expect((await store.list()).single.id, second.id);
  });

  test(
    'production path is persistent and isolated by owner, not reusable slot',
    () async {
      final first = await RetainedDownloadStore.keepFile(
        accountSlot: slot,
        fileId: 20,
        title: 'clip.mp4',
        isVideo: true,
      );
      final ownerStore = await RetainedDownloadStore.forAccount(slot);
      expect(
        ownerStore.directory.path,
        startsWith('${temporary.path}/retained-downloads-v1/'),
      );
      expect((await ownerStore.list()).single.id, first.id);
      userId = 200;
      final other = await RetainedDownloadStore.forAccount(slot);
      expect(other.directory.path, isNot(ownerStore.directory.path));
      expect(await other.list(), isEmpty);
      expect(
        requests.every((r) => ['getMe', 'getFile'].contains(r['@type'])),
        isTrue,
      );
      await expectLater(
        RetainedDownloadStore.keepFile(
          accountSlot: slot + 1,
          fileId: 20,
          title: 'clip.mp4',
          isVideo: true,
        ),
        throwsStateError,
      );
    },
  );

  testWidgets('keep control requires consent, copies only after confirmation', (
    tester,
  ) async {
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      _app(
        theme,
        const Center(
          child: RetainDownloadButton(
            accountSlot: slot,
            fileId: 20,
            title: 'clip.mp4',
            isVideo: true,
            showLabel: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('retain-download-7-20'));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.tap(find.byKey(const ValueKey('app-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await _drainFileOperations(
      tester,
      () => tester.widget<AppInteractiveSurface>(button).enabled,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AppInteractiveSurface>(button).enabled, isTrue);
    expect(find.text('Kept on device'), findsOneWidget);
    expect(
      await tester.runAsync(
        () async => (await (await RetainedDownloadStore.forAccount(
          slot,
        )).list()).length,
      ),
      1,
    );
    expect(await tester.runAsync(() => source.exists()), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'retained list reads the independent index and confirms deletion',
    (tester) async {
      late RetainedDownload entry;
      await tester.runAsync(() async {
        entry = await store.keep(
          file: file(),
          title: 'clip.mp4',
          isVideo: true,
        );
        await source.delete();
      });
      final theme = ThemeController(await SharedPreferences.getInstance());
      addTearDown(theme.dispose);
      final listing = _MemoryRetainedStore(store.directory, [entry]);
      await tester.pumpWidget(
        _app(theme, RetainedDownloadsPanel(accountSlot: slot, store: listing)),
      );
      await tester.pumpAndSettle();
      expect(find.text('clip.mp4'), findsOneWidget);
      final remove = find.byKey(ValueKey('retained-remove-${entry.id}'));
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-confirm-cancel')));
      await tester.pumpAndSettle();
      expect(listing.removed, isEmpty);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
      await tester.pumpAndSettle();
      expect(find.text('clip.mp4'), findsNothing);
      expect(listing.removed, [entry.id]);
    },
  );
}

class _MemoryRetainedStore extends RetainedDownloadStore {
  _MemoryRetainedStore(super.directory, this.entries);

  final List<RetainedDownload> entries;
  final List<String> removed = [];

  @override
  Future<List<RetainedDownload>> list() async => List.of(entries);

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    entries.removeWhere((entry) => entry.id == id);
  }
}

Future<void> _drainFileOperations(
  WidgetTester tester,
  bool Function() complete,
) async {
  // Widget futures run in fake async; real filesystem completions must be
  // drained between frames, not by an animation-only pumpAndSettle loop.
  for (var attempt = 0; attempt < 100 && !complete(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
}

Widget _app(ThemeController theme, Widget child) =>
    ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        home: Scaffold(body: child),
      ),
    );
