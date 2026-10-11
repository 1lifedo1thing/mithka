import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/music_playlist_service.dart';

void main() {
  test('a folder edit during chat creation keeps its new membership', () async {
    var members = [900];
    Map<String, dynamic>? edited;
    final service = MusicPlaylistService(
      folderUpdate: () => {
        '@type': 'updateChatFolders',
        'chat_folders': [
          {'@type': 'chatFolderInfo', 'id': 7, 'title': '_Playlist'},
        ],
      },
      query: (request) async {
        switch (request['@type']) {
          case 'getChatFolder':
            return {
              '@type': 'chatFolder',
              'title': '_Playlist',
              'included_chat_ids': [...members],
            };
          case 'createNewSupergroupChat':
            members = [900, 777];
            return {'@type': 'chat', 'id': 951, 'title': 'Mix'};
          case 'editChatFolder':
            edited = request['folder'] as Map<String, dynamic>;
            return {'@type': 'ok'};
          default:
            throw StateError('Unexpected request');
        }
      },
    );
    await service.createPlaylist('Mix');
    expect(edited?['included_chat_ids'], containsAll([900, 777, 951]));
  });

  for (final useWaiter in [false, true]) {
    test(
      'an unknown catalog blocks playlist writes (waiter: $useWaiter)',
      () async {
        final requests = <Map<String, dynamic>>[];
        final service = MusicPlaylistService(
          folderUpdate: () => null,
          folderWait: useWaiter ? (_) async => null : null,
          query: (request) async {
            requests.add(request);
            return request['@type'] == 'createNewSupergroupChat'
                ? {'@type': 'chat', 'id': 951, 'title': 'Mix'}
                : {'@type': 'ok'};
          },
        );
        await expectLater(service.createPlaylist('Mix'), throwsStateError);
        expect(requests, isEmpty);
        expect(await service.loadPlaylists(), isEmpty);
        expect(requests, isEmpty);
      },
    );
  }
}
