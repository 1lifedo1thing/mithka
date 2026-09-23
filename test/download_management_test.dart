import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/file_detail_view.dart';
import 'package:mithka/chat/shared_media_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/data_storage_service.dart';
import 'package:mithka/settings/downloads_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _slot = 7;
late ThemeController _theme;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<Map<String, dynamic>> updates;
  late _Backend backend;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: _slot,
        query: (request) => backend.query(request),
        send: (request) async => backend.requests.add(request),
        updates: updates.stream,
      ),
    );
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(_theme.dispose);
    backend = _Backend();
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  test(
    'explicit downloads register message context on the owning account',
    () async {
      await DataStorageService(
        TdClient.shared,
        _slot,
      ).addDownload(fileId: 501, chatId: 101, messageId: 1);
      expect(backend.requests.single, {
        '@type': 'addFileToDownloads',
        'file_id': 501,
        'chat_id': 101,
        'message_id': 1,
        'priority': 32,
      });
      await expectLater(
        Future.sync(
          () => DataStorageService(
            TdClient.shared,
            _slot + 1,
          ).addDownload(fileId: 501, chatId: 101, messageId: 1),
        ),
        throwsStateError,
      );
      expect(backend.requests, hasLength(1));
    },
  );

  test(
    'pause stops managed and playback owners without deleting cache',
    () async {
      await DataStorageService(TdClient.shared, _slot).pauseDownload(501);
      expect(backend.requests, [
        {'@type': 'toggleDownloadIsPaused', 'file_id': 501, 'is_paused': true},
        {
          '@type': 'cancelDownloadFile',
          'file_id': 501,
          'only_if_pending': false,
        },
      ]);
    },
  );

  test('playback-only pause tolerates only an absent managed task', () async {
    backend.pauseError = TdError({'code': 400, 'message': "Can't find file"});
    await DataStorageService(TdClient.shared, _slot).pauseDownload(501);
    expect(backend.calls('cancelDownloadFile'), hasLength(1));
    backend.requests.clear();
    backend.pauseError = TdError({
      'code': 500,
      'message': 'DownloadManager is closed',
    });
    await expectLater(
      DataStorageService(TdClient.shared, _slot).pauseDownload(501),
      throwsA(isA<TdError>()),
    );
    expect(backend.calls('cancelDownloadFile'), isEmpty);
  });

  testWidgets(
    'estimated bytes and historical complete date do not mean complete',
    (tester) async {
      backend.files[501] = _file(501, bytes: 60, expected: 50);
      backend.downloadSearch = (_) async => _downloads([
        _task(501, backend.files[501]!, completeDate: 1700000000),
      ]);
      await tester.pumpWidget(_app(const DownloadsView()));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('download-row-501'));
      expect(
        find.descendant(of: row, matching: find.text('clip.mp4')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('download-toggle-501')), findsOneWidget);
      expect(find.textContaining('60 B / 100 B'), findsOneWidget);

      updates.add({
        '@type': 'updateFile',
        'file': _file(501, bytes: 100, done: true),
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('download-toggle-501')), findsNothing);
      expect(find.textContaining('Completed'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an evicted completed task explicitly starts again on resume', (
    tester,
  ) async {
    backend.files[501] = _file(501);
    backend.downloadSearch = (_) async =>
        _downloads([_task(501, backend.files[501]!, completeDate: 1700000000)]);
    await tester.pumpWidget(_app(const DownloadsView()));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Continue download'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-toggle-501')));
    await tester.pumpAndSettle();
    expect(backend.calls('addFileToDownloads').single['message_id'], 501);
    expect(backend.calls('toggleDownloadIsPaused'), isEmpty);
    expect(find.bySemanticsLabel('Pause download'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('task pause/resume and external status updates stay in sync', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const DownloadsView()));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('download-toggle-501'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(backend.calls('toggleDownloadIsPaused').last['is_paused'], true);
    expect(backend.calls('cancelDownloadFile'), hasLength(1));
    expect(find.bySemanticsLabel('Continue download'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(backend.calls('toggleDownloadIsPaused').last['is_paused'], false);
    updates.add({
      '@type': 'updateFileDownload',
      'file_id': 501,
      'is_paused': true,
      'complete_date': 0,
    });
    await tester.pump();
    expect(find.bySemanticsLabel('Continue download'), findsOneWidget);
    updates.add({'@type': 'updateFileRemovedFromDownloads', 'file_id': 501});
    await tester.pump();
    expect(find.byKey(const ValueKey('download-row-501')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'progress updates preserve the task list instead of refetching it',
    (tester) async {
      await tester.pumpWidget(_app(const DownloadsView()));
      await tester.pumpAndSettle();
      for (var n = 1; n <= 20; n++) {
        updates.add({'@type': 'updateFile', 'file': _file(501, bytes: n)});
        updates.add({
          '@type': 'updateFileDownloads',
          'total_size': 100,
          'downloaded_size': n,
        });
      }
      await tester.pump(const Duration(seconds: 1));
      expect(backend.calls('searchFileDownloads'), hasLength(1));
      expect(find.textContaining('20 B / 100 B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'global task actions offer both pause and resume regardless of this page',
    (tester) async {
      backend.downloadSearch = (_) async => _downloads([]);
      await tester.pumpWidget(_app(const DownloadsView()));
      await tester.pumpAndSettle();
      for (final paused in [true, false]) {
        await tester.tap(find.byKey(const ValueKey('downloads-actions')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('downloads-toggle-all-true')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('downloads-toggle-all-false')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(ValueKey('downloads-toggle-all-$paused')));
        await tester.pumpAndSettle();
        expect(
          backend.calls('toggleAllDownloadsArePaused').last['are_paused'],
          paused,
        );
      }
      expect(backend.calls('removeAllFilesFromDownloads'), isEmpty);
    },
  );

  testWidgets('empty download search pages retain their continuation cursor', (
    tester,
  ) async {
    backend.downloadSearch = (request) async => request['offset'] == ''
        ? {
            '@type': 'foundFileDownloads',
            'files': [],
            'next_offset': 'next-task',
          }
        : _downloads([_task(501, _file(501))]);
    await tester.pumpWidget(_app(const DownloadsView()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads-load-more')));
    await tester.pumpAndSettle();
    expect(backend.calls('searchFileDownloads').last['offset'], 'next-task');
    expect(find.byKey(const ValueKey('download-row-501')), findsOneWidget);
  });

  testWidgets('a delayed old search cannot replace the new query result', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    backend.downloadSearch = (request) async {
      if (request['query'] == 'old') return old.future;
      return _downloads(
        request['query'] == 'new'
            ? [_task(502, _file(502))]
            : [_task(501, _file(501))],
      );
    };
    await tester.pumpWidget(_app(const DownloadsView()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    old.complete(_downloads([_task(501, _file(501))]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('download-row-502')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-row-501')), findsNothing);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      'global cached files and videos fit $platform and never auto-download',
      (tester) async {
        _view(tester, platform);
        backend.files[501] = _file(501, bytes: 30);
        backend.files[502] = _file(502, bytes: 100, done: true);
        backend.mediaPages[''] = {
          '@type': 'foundMessages',
          'messages': [
            _message(501, backend.files[501]!, video: true),
            _message(502, backend.files[502]!, video: true),
          ],
          'next_offset': '',
        };
        await tester.pumpWidget(_app(const DownloadsView()));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('downloads-section-videos')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('shared-media-progress-501')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('shared-media-download-501')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('shared-media-inner-header')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('shared-media-downloads')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        expect(backend.calls('addFileToDownloads'), isEmpty);
        expect(backend.calls('downloadFile'), isEmpty);

        await tester.tap(
          find.byKey(const ValueKey('shared-media-download-501')),
        );
        await tester.pumpAndSettle();
        expect(backend.calls('addFileToDownloads').single['chat_id'], 101);
        expect(backend.calls('addFileToDownloads').single['message_id'], 501);
        expect(backend.calls('toggleDownloadIsPaused'), isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('shared-media-download-501')),
        );
        await tester.pumpAndSettle();
        expect(
          backend.calls('toggleDownloadIsPaused').single['is_paused'],
          true,
        );
        expect(backend.calls('cancelDownloadFile'), hasLength(1));
        expect(tester.takeException(), isNull);

        backend.mediaPages[''] = {
          '@type': 'foundMessages',
          'messages': [_message(501, backend.files[501]!, video: false)],
          'next_offset': '',
        };
        await tester.tap(find.byKey(const ValueKey('downloads-section-files')));
        await tester.pumpAndSettle();
        expect(find.text('document-501.pdf'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('shared-media-progress-501')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('empty filtered pages can reach older archived cached media', (
    tester,
  ) async {
    backend.files[501] = _file(501);
    backend.files[502] = _file(502, bytes: 40);
    backend.mediaPages[''] = {
      '@type': 'foundMessages',
      'messages': [_message(501, backend.files[501]!, video: true)],
      'next_offset': 'older',
    };
    backend.mediaPages['older'] = {
      '@type': 'foundMessages',
      'messages': [],
      'next_offset': 'archived',
    };
    backend.mediaPages['archived'] = {
      '@type': 'foundMessages',
      'messages': [
        _message(502, backend.files[502]!, video: true, chatId: 202),
      ],
      'next_offset': '',
    };
    await tester.pumpWidget(
      _app(
        const SharedMediaView(
          chatId: 0,
          title: '',
          lockedTab: true,
          initialTab: 4,
          initialFileFilter: SharedMediaFileFilter.cached,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final more = find.byKey(const ValueKey('shared-media-load-more'));
    expect(more, findsOneWidget);
    expect(
      find.byKey(const ValueKey('shared-media-download-501')),
      findsNothing,
    );
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shared-media-download-502')),
      findsOneWidget,
    );
    expect(more, findsNothing);
    final searches = backend.calls('searchMessages');
    expect(searches.map((r) => r['offset']), ['', 'older', 'archived']);
    expect(
      searches.every(
        (r) => r['chat_list'] == null && !r.containsKey('offset_message_id'),
      ),
      true,
    );
    expect(backend.calls('addFileToDownloads'), isEmpty);
  });

  testWidgets(
    'download filters separate active, partial, complete and absent',
    (tester) async {
      _view(tester, TargetPlatform.macOS);
      backend.files.addAll({
        501: _file(501, bytes: 20),
        502: _file(502, bytes: 10, active: true),
        503: _file(503, bytes: 100, done: true),
        504: _file(504),
      });
      backend.mediaPages[''] = {
        '@type': 'foundMessages',
        'messages': [
          for (final id in [501, 502, 503, 504])
            _message(id, backend.files[id]!, video: true),
        ],
        'next_offset': '',
      };
      await tester.pumpWidget(
        _app(
          const SharedMediaView(
            chatId: 0,
            title: '',
            lockedTab: true,
            initialTab: 4,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> filter(String name, List<int> expected) async {
        await tester.tap(
          find.byKey(const ValueKey('shared-media-filter-dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('shared-media-filter-$name')));
        await tester.pumpAndSettle();
        for (final id in [501, 502, 503, 504]) {
          expect(
            find.byKey(ValueKey('shared-video-card-101-$id')),
            expected.contains(id) ? findsOneWidget : findsNothing,
          );
        }
      }

      await filter('partial', [501, 502]);
      await filter('downloading', [502]);
      await filter('downloaded', [503]);
      await filter('notDownloaded', [504]);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'file detail cancellation waits for registration then pauses it',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      backend.addResult = pending;
      final doc = TDParse.message(
        _message(501, backend.files[501]!, video: false),
      )!.document!;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => GestureDetector(
              key: const ValueKey('open-file'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FileDetailView(
                    doc: doc,
                    chatId: 101,
                    messageId: 501,
                    accountSlot: _slot,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-file')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('file-detail-pause')));
      await tester.pump();
      expect(backend.calls('toggleDownloadIsPaused'), isEmpty);
      pending.complete(_file(501, active: true));
      await tester.pumpAndSettle();
      expect(backend.calls('addFileToDownloads'), hasLength(1));
      expect(backend.calls('toggleDownloadIsPaused').single['is_paused'], true);
      expect(backend.calls('cancelDownloadFile'), hasLength(1));
      expect(find.byType(FileDetailView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening a complete document does not restart its task', (
    tester,
  ) async {
    backend.files[501] = _file(501, bytes: 100, done: true);
    final doc = TDParse.message(
      _message(501, backend.files[501]!, video: false),
    )!.document!;
    await tester.pumpWidget(
      _app(FileDetailView(doc: doc, chatId: 101, messageId: 501)),
    );
    await tester.pumpAndSettle();
    expect(backend.calls('addFileToDownloads'), isEmpty);
    expect(backend.calls('downloadFile'), isEmpty);
    expect(find.byKey(const ValueKey('file-detail-pause')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget home) => ChangeNotifierProvider.value(
  value: _theme,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [AppLocalizations.delegate],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(extensions: [AppColors.light]),
    home: home,
  ),
);

void _view(WidgetTester tester, TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = platform == TargetPlatform.macOS
      ? const Size(1024, 768)
      : const Size(390, 844);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    debugDefaultTargetPlatformOverride = null;
  });
}

Map<String, dynamic> _file(
  int id, {
  int bytes = 0,
  int size = 100,
  int expected = 100,
  bool active = false,
  bool done = false,
}) => {
  '@type': 'file',
  'id': id,
  'size': size,
  'expected_size': expected,
  'local': {
    '@type': 'localFile',
    'path': done ? '/synthetic/test.mp4' : '',
    'downloaded_size': bytes,
    'downloaded_prefix_size': bytes,
    'is_downloading_active': active,
    'is_downloading_completed': done,
  },
};

Map<String, dynamic> _message(
  int id,
  Map<String, dynamic> file, {
  required bool video,
  int chatId = 101,
}) => {
  '@type': 'message',
  'id': id,
  'chat_id': chatId,
  'date': 1700000000 + id,
  'is_outgoing': false,
  'content': video
      ? {
          '@type': 'messageVideo',
          'caption': {
            '@type': 'formattedText',
            'text': 'Video $id',
            'entities': [],
          },
          'video': {
            '@type': 'video',
            'file_name': 'clip.mp4',
            'duration': 30,
            'width': 1280,
            'height': 720,
            'video': file,
          },
        }
      : {
          '@type': 'messageDocument',
          'caption': {'@type': 'formattedText', 'text': '', 'entities': []},
          'document': {
            '@type': 'document',
            'file_name': 'document-$id.pdf',
            'mime_type': 'application/pdf',
            'document': file,
          },
        },
};

Map<String, dynamic> _task(
  int id,
  Map<String, dynamic> file, {
  bool paused = false,
  int completeDate = 0,
}) => {
  '@type': 'fileDownload',
  'file_id': id,
  'message': _message(id, file, video: true),
  'is_paused': paused,
  'complete_date': completeDate,
};
Map<String, dynamic> _downloads(List<Map<String, dynamic>> tasks) => {
  '@type': 'foundFileDownloads',
  'files': tasks,
  'next_offset': '',
};

class _Backend {
  final requests = <Map<String, dynamic>>[];
  final files = <int, Map<String, dynamic>>{501: _file(501, active: true)};
  final mediaPages = <String, Map<String, dynamic>>{};
  TdError? pauseError;
  Completer<Map<String, dynamic>>? addResult;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? downloadSearch;
  List<Map<String, dynamic>> calls(String type) =>
      requests.where((r) => r['@type'] == type).toList();

  Future<Map<String, dynamic>> query(Map<String, dynamic> request) async {
    requests.add(Map.of(request));
    final id = request['file_id'] as int? ?? 501;
    switch (request['@type']) {
      case 'searchFileDownloads':
        return downloadSearch?.call(request) ??
            _downloads([_task(501, files[501]!)]);
      case 'searchMessages':
        return mediaPages[request['offset']] ??
            {'@type': 'foundMessages', 'messages': [], 'next_offset': ''};
      case 'getFile':
        return files[id] ?? _file(id);
      case 'getChat':
        return {
          '@type': 'chat',
          'id': request['chat_id'],
          'title': 'Source chat',
        };
      case 'addFileToDownloads':
        if (addResult != null) return addResult!.future;
        final old = files[id]?['local'] as Map<String, dynamic>?;
        return files[id] = _file(
          id,
          bytes: old?['downloaded_size'] as int? ?? 0,
          active: true,
        );
      case 'toggleDownloadIsPaused':
        if (pauseError != null) throw pauseError!;
      case 'cancelDownloadFile':
        final local = files[id]?['local'] as Map<String, dynamic>?;
        if (local != null) local['is_downloading_active'] = false;
    }
    return {'@type': 'ok'};
  }
}
