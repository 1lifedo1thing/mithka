import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/chat_folder_management_view.dart';
import 'package:mithka/settings/chat_folder_service.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'quick folder editor returns name and configured icon without editing rules',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final theme = ThemeController(await SharedPreferences.getInstance());
      addTearDown(theme.dispose);
      ChatFolderDraft? result;
      var queries = 0;
      final service = ChatFolderService(
        query: (_) async {
          queries++;
          return {'@type': 'ok'};
        },
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: theme,
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [AppLocalizations.delegate],
            theme: ThemeData(extensions: [AppColors.light]),
            home: Builder(
              builder: (context) => GestureDetector(
                onTap: () async {
                  result = await Navigator.of(context).push<ChatFolderDraft>(
                    MaterialPageRoute(
                      builder: (_) => ChatFolderEditorView(
                        initial: const ChatFolderDraft(
                          title: 'Work',
                          iconName: 'Work',
                          includedChatIds: {42},
                          includeGroups: true,
                        ),
                        service: service,
                        tagsEnabled: false,
                        appearanceOnly: true,
                        folderId: 7,
                      ),
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          AppStrings.t(AppStringKeys.chatFolderManagementSectionInclude),
        ),
        findsNothing,
      );
      expect(
        find.text(
          AppStrings.t(AppStringKeys.chatFolderManagementSectionTagColor),
        ),
        findsNothing,
      );
      await tester.enterText(find.byKey(const ValueKey('folder-name')), 'Team');
      await tester.ensureVisible(find.byKey(const ValueKey('folder-icon-Cat')));
      await tester.tap(find.byKey(const ValueKey('folder-icon-Cat')));
      await tester.pump();
      await tester.tap(
        find.text(AppStrings.t(AppStringKeys.accentColorPickerSave)),
      );
      await tester.pumpAndSettle();
      expect(result!.title, 'Team');
      expect(result!.iconName, 'Cat');
      expect(result!.includedChatIds, {42});
      expect(result!.includeGroups, true);
      expect(queries, 0);
    },
  );
}
