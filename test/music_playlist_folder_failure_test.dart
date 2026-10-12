import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/music_playlist_service.dart';
import 'package:mithka/tdlib/td_client.dart';

Map<String, dynamic> _folderInfo(int id) => {
  '@type': 'chatFolderInfo',
  'id': id,
  'name': {
    '@type': 'chatFolderName',
    'text': {
      '@type': 'formattedText',
      'text': MusicPlaylistService.folderTitle,
      'entities': <Map<String, dynamic>>[],
    },
  },
};

Map<String, dynamic> _snapshot(List<Map<String, dynamic>> infos) => {
  '@type': 'updateChatFolders',
  'chat_folders': infos,
};

Map<String, dynamic> _playlistFolder(List<int> chatIds) => {
  '@type': 'chatFolder',
  'name': {
    '@type': 'chatFolderName',
    'text': {
      '@type': 'formattedText',
      'text': MusicPlaylistService.folderTitle,
      'entities': <Map<String, dynamic>>[],
    },
  },
  'included_chat_ids': chatIds,
};

void main() {
  group('an unreadable known folder blocks writes without creating a chat', () {
    test(
      "createPlaylist throws and writes nothing when getChatFolder(7) fails",
      () async {
        final requests = <Map<String, dynamic>>[];
        final service = MusicPlaylistService(
          folderUpdate: () => _snapshot([_folderInfo(7)]),
          query: (request) {
            requests.add(request);
            return switch (request['@type']) {
              'getChatFolder' => Future<Map<String, dynamic>>.error(
                StateError('folder 7 unavailable'),
              ),
              _ => Future.value({'@type': 'ok'}),
            };
          },
        );

        await expectLater(service.createPlaylist('Mix'), throwsA(anything));

        final types = requests.map((request) => request['@type']).toList();
        expect(types, ['getChatFolder']);
        expect(
          types,
          isNot(contains('createNewSupergroupChat')),
          reason: 'the chat must not exist when the catalog is unvalidated',
        );
        expect(types, isNot(contains('createChatFolder')));
        expect(types, isNot(contains('editChatFolder')));
      },
    );

    test('a sync getChatFolder throw is also caught by validation', () async {
      final requests = <Map<String, dynamic>>[];
      final service = MusicPlaylistService(
        folderUpdate: () => _snapshot([_folderInfo(7)]),
        query: (request) {
          requests.add(request);
          if (request['@type'] == 'getChatFolder') {
            throw StateError('sync failure');
          }
          return Future.value({'@type': 'ok'});
        },
      );

      await expectLater(service.createPlaylist('Mix'), throwsA(anything));
      expect(
        requests.map((request) => request['@type']),
        everyElement('getChatFolder'),
      );
    });

    test(
      'mixed folders: one unreadable known folder still blocks the write',
      () async {
        final requests = <Map<String, dynamic>>[];
        final service = MusicPlaylistService(
          folderUpdate: () => _snapshot([_folderInfo(7), _folderInfo(8)]),
          query: (request) {
            requests.add(request);
            if (request['@type'] != 'getChatFolder') {
              return Future.value({'@type': 'ok'});
            }
            final id = request['chat_folder_id'] as int;
            return id == 7
                ? Future.value(_playlistFolder([900]))
                : Future<Map<String, dynamic>>.error(
                    StateError('folder 8 unavailable'),
                  );
          },
        );

        await expectLater(service.createPlaylist('Mix'), throwsA(anything));
        expect(
          requests.where((r) => r['@type'] == 'getChatFolder'),
          hasLength(2),
        );
        expect(
          requests.map((request) => request['@type']),
          isNot(contains('createNewSupergroupChat')),
          reason: 'a half-readable catalog is not a validated catalog',
        );
        expect(
          requests.map((request) => request['@type']),
          isNot(contains('createChatFolder')),
        );
        expect(
          requests.map((request) => request['@type']),
          isNot(contains('editChatFolder')),
        );
      },
    );

    test(
      'an empty received catalog still allows creating a playlist folder',
      () async {
        final requests = <Map<String, dynamic>>[];
        final service = MusicPlaylistService(
          folderUpdate: () => _snapshot([]),
          folderWait: (cached) async => cached,
          query: (request) {
            requests.add(request);
            return switch (request['@type']) {
              'createNewSupergroupChat' => Future.value({
                '@type': 'chat',
                'id': 951,
                'title': 'Mix',
              }),
              'createChatFolder' => Future.value({
                '@type': 'chatFolderInfo',
                'id': 9,
              }),
              _ => Future.value({'@type': 'ok'}),
            };
          },
        );

        final playlist = await service.createPlaylist('Mix');

        expect(playlist.chatId, 951);
        final types = requests.map((request) => request['@type']).toList();
        expect(types, contains('createNewSupergroupChat'));
        expect(
          types,
          contains('createChatFolder'),
          reason: 'a genuinely folder-less account must still get a folder',
        );
      },
    );

    test('loadPlaylists stays tolerant: an unreadable known folder is skipped, '
        'not fatal', () async {
      final requests = <Map<String, dynamic>>[];
      final service = MusicPlaylistService(
        folderUpdate: () => _snapshot([_folderInfo(7)]),
        query: (request) {
          requests.add(request);
          return switch (request['@type']) {
            'getChatFolder' => Future<Map<String, dynamic>>.error(
              StateError('folder 7 unavailable'),
            ),
            _ => Future.value({'@type': 'ok'}),
          };
        },
      );

      // Display tolerance: no throw, an empty library, not a crash.
      expect(await service.loadPlaylists(), isEmpty);
      expect(requests.map((r) => r['@type']), contains('getChatFolder'));
    });

    test(
      'loadPlaylists keeps the readable half when one of two folders fails',
      () async {
        final service = MusicPlaylistService(
          folderUpdate: () => _snapshot([_folderInfo(7), _folderInfo(8)]),
          query: (request) {
            if (request['@type'] != 'getChatFolder') {
              return Future.value({
                '@type': 'chat',
                'id': request['chat_id'],
                'title': 'Favourites',
              });
            }
            final id = request['chat_folder_id'] as int;
            return id == 7
                ? Future.value(_playlistFolder([900]))
                : Future<Map<String, dynamic>>.error(
                    StateError('folder 8 unavailable'),
                  );
          },
        );

        final playlists = await service.loadPlaylists();
        expect(playlists.map((playlist) => playlist.chatId), [900]);
      },
    );
  });

  group('the cold-cache waiter cancels its subscription on timeout', () {
    Map<String, dynamic> seedPushedFolders(TdClient client) {
      // Make the latest pushed snapshot match the cached one, so the waiter
      // cannot take its snapshot fast path and must own a subscription.
      client.routeUpdateForTesting({
        '@type': 'updateChatFolders',
        '@client_id': 1,
        'chat_folders': [_folderInfo(7)],
      });
      return client.latestChatFoldersUpdateForClient(1)!;
    }

    test(
      'a timed-out wait resolves with the cached snapshot and detaches',
      () async {
        final client = TdClient.shared;
        final seeded = seedPushedFolders(client);

        final wait = MusicPlaylistService.waiterForClient(
          1,
          timeout: const Duration(milliseconds: 50),
        )(seeded);

        final resolved = await wait;
        expect(
          resolved,
          same(seeded),
          reason: 'a timed-out wait falls back to the cached snapshot',
        );

        // The leak regression: a matching update arriving AFTER the timeout
        // must neither crash nor resurrect the dead wait. With the old
        // firstWhere().timeout() the leaked subscription stayed live on the
        // broadcast stream for the rest of the session; with the owned
        // subscription the late update is dropped by the isCompleted guard.
        client.routeUpdateForTesting({
          '@type': 'updateChatFolders',
          '@client_id': 1,
          'chat_folders': [_folderInfo(99)],
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          client.latestChatFoldersUpdateForClient(1)?['chat_folders'],
          isNotNull,
          reason: 'the late push still updates the cache',
        );
      },
    );

    test(
      'a matching push during the wait completes it with that update',
      () async {
        final client = TdClient.shared;
        final seeded = seedPushedFolders(client);
        final wait = MusicPlaylistService.waiterForClient(
          1,
          timeout: const Duration(seconds: 30),
        )(seeded);

        // Deliver the awaited push asynchronously, as TDLib would.
        scheduleMicrotask(() {
          client.routeUpdateForTesting({
            '@type': 'updateChatFolders',
            '@client_id': 1,
            'chat_folders': [_folderInfo(99)],
          });
        });

        final resolved = await wait;
        expect(
          (resolved?['chat_folders'] as List).first['id'],
          99,
          reason: 'the wait resolves with the first differing snapshot',
        );
      },
    );

    test(
      'a null clientId passes the cached snapshot through untouched',
      () async {
        final cached = _snapshot([_folderInfo(7)]);
        final wait = MusicPlaylistService.waiterForClient(null)(cached);
        expect(await wait, same(cached));
      },
    );
  });
}
