//
//  chat_sticker_packs_view.dart
//
//  Sticker and emoji packs used in a chat, deduplicated, in two tabs. Each
//  row adds its pack in one tap; "Add all" installs every missing pack in the
//  open tab. Touch layouts use 56pt rows with 40pt covers; pointer layouts use
//  44pt rows with 30pt covers and split into two columns from 620pt wide.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mithka/l10n/app_localizations.dart';

import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../platform/adaptive_platform.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../theme/app_theme.dart';
import 'chat_sticker_packs_service.dart';
import 'sticker_preview.dart';
import 'sticker_set_detail_view.dart';

class ChatStickerPacksView extends StatefulWidget {
  const ChatStickerPacksView({super.key, required this.chatId, this.service});

  final int chatId;
  final ChatStickerPacksService? service;

  @override
  State<ChatStickerPacksView> createState() => _ChatStickerPacksViewState();
}

class _ChatStickerPacksViewState extends State<ChatStickerPacksView> {
  late final ChatStickerPacksService _service =
      widget.service ?? ChatStickerPacksService();
  ChatUsedPacks _result = ChatUsedPacks.empty;
  bool _loading = true;
  int _tab = 0;
  final Set<int> _working = {};
  bool _addingAll = false;

  List<ChatUsedPack> get _packs => _tab == 0 ? _result.stickers : _result.emoji;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final result = await _service.scan(widget.chatId);
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
        // Open on whichever tab has content.
        if (result.stickers.isEmpty && result.emoji.isNotEmpty) _tab = 1;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(ChatUsedPack pack) async {
    if (pack.installed || _working.contains(pack.id)) return;
    setState(() => _working.add(pack.id));
    final ok = await _service.install(pack);
    if (ok) ChatStickerPacksService.refreshComposerStores();
    if (!mounted) return;
    setState(() => _working.remove(pack.id));
    if (!ok) {
      showToast(
        context,
        AppStrings.t(AppStringKeys.stickerSetDetailActionFailed),
      );
    }
  }

  Future<void> _addAll() async {
    if (_addingAll) return;
    final pending = _packs.where((p) => !p.installed).toList();
    if (pending.isEmpty) return;
    setState(() {
      _addingAll = true;
      _working.addAll(pending.map((p) => p.id));
    });
    final added = await _service.installAll(pending);
    if (!mounted) return;
    setState(() {
      _addingAll = false;
      _working.removeAll(pending.map((p) => p.id));
    });
    showToast(
      context,
      added == 0
          ? AppStrings.t(AppStringKeys.stickerSetDetailActionFailed)
          : AppStrings.plural(AppStringKeys.chatStickerPacksAddedCount, added),
    );
  }

  Future<void> _openDetail(ChatUsedPack pack) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StickerSetDetailView(setId: pack.id)),
    );
    // The detail page can install or remove the set; mirror its state.
    try {
      final set = await TdClient.shared.query({
        '@type': 'getStickerSet',
        'set_id': pack.id,
      });
      final installed = set.boolean('is_installed') ?? pack.installed;
      if (mounted && installed != pack.installed) {
        setState(() => pack.installed = installed);
        ChatStickerPacksService.refreshComposerStores();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dense = isDesktopTargetPlatform(Theme.of(context).platform);
    return ColoredBox(
      color: c.groupedBackground,
      child: Column(
        children: [
          NavHeader(
            title: AppStringKeys.chatStickerPacksTitle,
            onBack: () => Navigator.of(context).pop(),
          ),
          _tabBar(dense),
          if (!_loading && _packs.isNotEmpty) _summaryBar(dense),
          Expanded(child: _body(dense)),
        ],
      ),
    );
  }

  Widget _tabBar(bool dense) {
    Widget tab(int index, String key, int count) => Expanded(
      child: SettingsFilterChip(
        key: ValueKey('chat-sticker-packs-tab-$index'),
        label: AppStrings.t(key),
        trailingLabel: _loading ? null : '$count',
        selected: _tab == index,
        onTap: () => setState(() => _tab = index),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(12, dense ? 8 : 10, 12, dense ? 4 : 6),
      child: Row(
        children: [
          tab(
            0,
            AppStringKeys.chatStickerPacksTabStickers,
            _result.stickers.length,
          ),
          SizedBox(width: dense ? 6 : 8),
          tab(1, AppStringKeys.chatStickerPacksTabEmoji, _result.emoji.length),
        ],
      ),
    );
  }

  Widget _summaryBar(bool dense) {
    final c = context.colors;
    final missing = _packs.where((p) => !p.installed).length;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, dense ? 2 : 4, 8, dense ? 2 : 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.plural(
                AppStringKeys.chatStickerPacksScanned,
                _result.scannedMessages,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? AppTextSize.caption : AppTextSize.footnote,
                color: c.textSecondary,
              ),
            ),
          ),
          if (missing > 0)
            AppInteractiveSurface(
              key: const ValueKey('chat-sticker-packs-add-all'),
              onTap: _addingAll ? null : _addAll,
              isButton: true,
              semanticLabel: AppStrings.t(AppStringKeys.chatStickerPacksAddAll),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: dense ? 4 : 8,
                ),
                child: Text(
                  '${AppStrings.t(AppStringKeys.chatStickerPacksAddAll)} ($missing)',
                  style: TextStyle(
                    fontSize: dense
                        ? AppTextSize.caption
                        : AppTextSize.footnote,
                    fontWeight: AppTextWeight.semibold,
                    color: _addingAll ? c.textTertiary : c.linkBlue,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(bool dense) {
    final c = context.colors;
    if (_loading) return const Center(child: AppActivityIndicator(size: 22));
    final packs = _packs;
    if (packs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                _tab == 0 ? HeroAppIcons.grip : HeroAppIcons.solidFaceSmile,
                size: dense ? 28 : 34,
                color: c.textTertiary,
              ),
              const SizedBox(height: 10),
              Text(
                AppStrings.t(
                  _tab == 0
                      ? AppStringKeys.chatStickerPacksEmptyStickers
                      : AppStringKeys.chatStickerPacksEmptyEmoji,
                ),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: dense ? AppTextSize.footnote : AppTextSize.callout,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = dense && constraints.maxWidth >= 620 ? 2 : 1;
        if (columns == 2) {
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 44,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: packs.length,
            itemBuilder: (context, index) => DecoratedBox(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: _row(packs[index], dense: true),
            ),
          );
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(12, 4, 12, dense ? 16 : 24),
          children: [
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(
                  dense ? AppRadius.control : AppRadius.card,
                ),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < packs.length; i++) ...[
                    if (i > 0) InsetDivider(leadingInset: dense ? 50 : 64),
                    _row(packs[i], dense: dense),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(ChatUsedPack pack, {required bool dense}) {
    final c = context.colors;
    final cover = dense ? 30.0 : 40.0;
    final countKey = pack.isCustomEmoji
        ? AppStringKeys.chatStickerPacksEmojiCount
        : AppStringKeys.stickerSetDetailStickerCount;
    return AppInteractiveSurface(
      key: ValueKey('chat-sticker-pack-${pack.id}'),
      onTap: () => unawaited(_openDetail(pack)),
      semanticLabel: pack.title,
      borderRadius: BorderRadius.circular(
        dense ? AppRadius.control : AppRadius.card,
      ),
      child: SizedBox(
        height: dense ? 44 : 56,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12),
          child: Row(
            children: [
              SizedBox(
                width: cover,
                height: cover,
                child: Center(
                  child: pack.cover == null
                      ? AppIcon(
                          HeroAppIcons.solidFaceSmile,
                          size: cover * 0.6,
                          color: c.textTertiary,
                        )
                      : StickerTabPreview(item: pack.cover!),
                ),
              ),
              SizedBox(width: dense ? 10 : 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pack.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense
                            ? AppTextSize.footnote
                            : AppTextSize.body,
                        fontWeight: AppTextWeight.medium,
                        color: c.textPrimary,
                      ),
                    ),
                    SizedBox(height: dense ? 1 : 2),
                    Text(
                      '${AppStrings.plural(countKey, pack.itemCount)} · '
                      '${AppStrings.plural(AppStringKeys.chatStickerPacksUses, pack.uses)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense
                            ? AppTextSize.tiny + 1
                            : AppTextSize.caption,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _addButton(pack, dense: dense),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addButton(ChatUsedPack pack, {required bool dense}) {
    final c = context.colors;
    final fontSize = dense ? AppTextSize.caption : AppTextSize.footnote;
    if (pack.installed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            HeroAppIcons.check,
            size: dense ? 12 : 14,
            color: c.textTertiary,
          ),
          const SizedBox(width: 4),
          Text(
            AppStrings.t(AppStringKeys.chatStickerPacksAdded),
            style: TextStyle(fontSize: fontSize, color: c.textTertiary),
          ),
        ],
      );
    }
    final working = _working.contains(pack.id);
    final height = dense ? 24.0 : 28.0;
    return AppInteractiveSurface(
      key: ValueKey('chat-sticker-pack-add-${pack.id}'),
      onTap: working ? null : () => unawaited(_add(pack)),
      isButton: true,
      semanticLabel: AppStrings.t(AppStringKeys.chatStickerPacksAdd),
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        constraints: BoxConstraints(minWidth: dense ? 48 : 56),
        padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: working ? c.searchFill : c.linkBlue,
          borderRadius: BorderRadius.circular(height / 2),
        ),
        child: working
            ? AppActivityIndicator(
                size: dense ? 12 : 14,
                color: c.textSecondary,
              )
            : Text(
                AppStrings.t(AppStringKeys.chatStickerPacksAdd),
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: AppTextWeight.semibold,
                  color: c.onAccent,
                ),
              ),
      ),
    );
  }
}
