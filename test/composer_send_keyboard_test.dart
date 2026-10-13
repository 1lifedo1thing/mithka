import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_input_bar.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/components/keyboard_dismiss_on_tap.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/theme/app_theme.dart';

class _SendKeyboardViewModel extends ChatViewModel {
  _SendKeyboardViewModel()
    : super(chatId: 1, title: 'Test', markReadOnOpen: false);

  final sentTexts = <String>[];

  @override
  void sendTyping() {}

  @override
  void setDraft(
    String value, {
    String? formattedText,
    List<Map<String, dynamic>> entities = const [],
  }) {
    draft = value;
  }

  @override
  Future<bool> prepareMessageSend() async => true;

  @override
  Future<bool> currentUserIsPremium() async => true;

  @override
  Future<bool> sendFormatted(
    String text,
    List<Map<String, dynamic>> entities,
  ) async {
    sentTexts.add(text);
    return true;
  }
}

Future<_SendKeyboardViewModel> _pumpComposer(
  WidgetTester tester, {
  required bool enterToSend,
}) async {
  final vm = _SendKeyboardViewModel();
  addTearDown(vm.dispose);
  await tester.pumpWidget(
    MaterialApp(
      // The app wraps every route in the outside-tap dismissal (main.dart);
      // reproduce that here so composer taps see the same behavior.
      builder: (context, child) =>
          AppKeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        platform: TargetPlatform.android,
        extensions: [AppColors.light],
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ChatInputBar(
            vm: vm,
            enterToSend: enterToSend,
            quickRepliesEnabled: false,
            onStartCall: (_) {},
            onMessageSent: () {},
          ),
        ),
      ),
    ),
  );
  return vm;
}

FocusNode _composerFocusNode(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).first).focusNode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pointer down on send keeps the keyboard open on Android', (
    tester,
  ) async {
    final vm = await _pumpComposer(tester, enterToSend: false);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.pump();
    expect(_composerFocusNode(tester).hasFocus, isTrue);

    await tester.enterText(field, 'hello');
    await tester.pump();

    // The dismiss-on-tap handler runs on pointer down, before the button's
    // onTap. Split the gesture so the intermediate state is observable: the
    // send button joins the composer tap region group, so pressing it must
    // not drop focus (which would collapse and then reopen the keyboard).
    final sendButton = find.byKey(const ValueKey('composerSendButton'));
    final gesture = await tester.startGesture(tester.getCenter(sendButton));
    await tester.pump();
    expect(
      _composerFocusNode(tester).hasFocus,
      isTrue,
      reason:
          'pressing send must not be treated as an outside tap; the keyboard '
          'would collapse and immediately reopen once the send path '
          're-focuses the composer',
    );
    await gesture.up();
    await tester.pump();

    expect(vm.sentTexts, ['hello']);
    expect(_composerFocusNode(tester).hasFocus, isTrue);
  });

  testWidgets('the software send action keeps the keyboard open on Android', (
    tester,
  ) async {
    final vm = await _pumpComposer(tester, enterToSend: true);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'hello');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(vm.sentTexts, ['hello']);
    expect(
      _composerFocusNode(tester).hasFocus,
      isTrue,
      reason:
          'send is a chat-completion action; the composer must stay focused '
          'instead of collapsing and reopening the keyboard',
    );
  });
}
