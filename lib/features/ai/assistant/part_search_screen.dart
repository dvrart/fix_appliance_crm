import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_feedback.dart';
import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/part_search_service.dart';

class PartSearchScreen extends StatefulWidget {
  final PartSearchSession? initialSession;

  const PartSearchScreen({super.key, this.initialSession});

  @override
  State<PartSearchScreen> createState() => _PartSearchScreenState();
}

enum _OfferFilter { all, oem, aftermarket }

class _PartSearchScreenState extends State<PartSearchScreen> {
  _OfferFilter _filter = _OfferFilter.all;
  PartSearchSession? _boundSession;

  PartSearchSession? get _session =>
      PartSearchSession.current.value ?? widget.initialSession;

  @override
  void initState() {
    super.initState();
    PartSearchSession.current.addListener(_onCurrentSessionChanged);
    _bind(_session);
  }

  void _onCurrentSessionChanged() {
    if (!mounted) return;
    _bind(_session);
    setState(() {
      _filter = _OfferFilter.all;
    });
  }

  void _bind(PartSearchSession? next) {
    if (identical(_boundSession, next)) return;
    _boundSession?.removeListener(_onSessionUpdated);
    _boundSession = next;
    _boundSession?.addListener(_onSessionUpdated);
  }

  void _onSessionUpdated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PartSearchSession.current.removeListener(_onCurrentSessionChanged);
    _boundSession?.removeListener(_onSessionUpdated);
    super.dispose();
  }

  Future<void> _openOfferUrl(PartOffer offer) async {
    AppFeedback.pleasant();
    final uri = Uri.tryParse(offer.url);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Не удалось открыть ссылку в браузере',
              'Could not open link in browser',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _copyText(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    AppFeedback.pleasant();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text('$label: $value'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(context.tr('Проверенные запчасти', 'Verified Parts')),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: session == null
          ? _buildEmptyState(context)
          : session.isSearching
          ? _buildProgressView(context, session)
          : _buildResultsView(context, session),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          context.tr(
            'Попросите ассистента найти запчасть — проверенные ссылки и цены появятся здесь.',
            'Ask the assistant to find a part — verified links and prices will appear here.',
          ),
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.inkMuted, fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildProgressView(BuildContext context, PartSearchSession session) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      session.queryTitle,
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              for (final done in session.completedSteps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 19,
                        color: Color(0xFF16A34A),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          done,
                          style: TextStyle(
                            color: AppColors.ink,
                            fontSize: 14,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (session.currentStep.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.travel_explore_rounded,
                      size: 19,
                      color: AppColors.primaryOnCard,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        session.currentStep,
                        style: TextStyle(
                          color: AppColors.primaryOnCard,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResultsView(BuildContext context, PartSearchSession session) {
    final result = session.result;
    if (result == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            session.errorText ??
                context.tr('Поиск не завершился', 'Search did not finish'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.danger, fontSize: 15),
          ),
        ),
      );
    }

    if (result.needsClarification) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFF59E0B)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: Color(0xFFD97706),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.tr(
                          'Нужно уточнение для точной проверки',
                          'Clarification needed for exact check',
                        ),
                        style: TextStyle(
                          color: AppColors.ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  result.clarificationMessage,
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final hasOem = result.offers.any((o) => o.isOem == true);
    final hasAftermarket = result.offers.any((o) => o.isOem == false);
    final visibleOffers = switch (_filter) {
      _OfferFilter.oem =>
        result.offers.where((o) => o.isOem == true).toList(),
      _OfferFilter.aftermarket =>
        result.offers.where((o) => o.isOem == false).toList(),
      _OfferFilter.all => result.offers,
    };

    final cheapestUrl = result.cheapestOverall?.url;
    final cheapestOemUrl = result.cheapestOem?.url;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildPartHeaderCard(context, result),
        if (result.warehouseMatches.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildWarehouseBanner(context, result.warehouseMatches),
        ],
        if (hasOem && hasAftermarket) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterChip(
                context,
                label:
                    '${context.tr('Все в наличии', 'All in stock')} (${result.offers.length})',
                selected: _filter == _OfferFilter.all,
                onTap: () => setState(() => _filter = _OfferFilter.all),
              ),
              _filterChip(
                context,
                label: context.tr('Оригинал OEM', 'Genuine OEM'),
                selected: _filter == _OfferFilter.oem,
                onTap: () => setState(() => _filter = _OfferFilter.oem),
              ),
              _filterChip(
                context,
                label: context.tr('Аналоги дешевле', 'Aftermarket'),
                selected: _filter == _OfferFilter.aftermarket,
                onTap: () => setState(() => _filter = _OfferFilter.aftermarket),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        if (visibleOffers.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              result.clarificationMessage.isNotEmpty
                  ? result.clarificationMessage
                  : context.tr(
                      'По выбранному фильтру подтверждённых предложений в наличии нет.',
                      'No verified in-stock offers for the selected filter.',
                    ),
              style: TextStyle(color: AppColors.inkMuted, fontSize: 14),
            ),
          )
        else
          for (var i = 0; i < visibleOffers.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _buildOfferCard(
              context,
              offer: visibleOffers[i],
              isLowestOverall: visibleOffers[i].url == cheapestUrl,
              isLowestOem:
                  visibleOffers[i].url == cheapestOemUrl &&
                  cheapestOemUrl != cheapestUrl,
            ),
          ],
        if (result.amazonSearchUrl.isNotEmpty) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              AppFeedback.pleasant();
              final uri = Uri.tryParse(result.amazonSearchUrl);
              if (uri != null) {
                unawaited(
                  launchUrl(uri, mode: LaunchMode.externalApplication),
                );
              }
            },
            icon: const Icon(Icons.shopping_bag_outlined, size: 19),
            label: Text(
              context.tr(
                'Все варианты ${result.partNumber} на Amazon.ca',
                'All ${result.partNumber} options on Amazon.ca',
              ),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFD97706),
              side: const BorderSide(color: Color(0xFFF59E0B), width: 1.4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPartHeaderCard(BuildContext context, PartSearchResult result) {
    final modelLine = [
      result.applianceType,
      result.brand,
      result.model,
    ].where((s) => s.trim().isNotEmpty).join(' · ');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.partName,
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (modelLine.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        modelLine,
                        style: TextStyle(
                          color: AppColors.inkMuted,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (result.partNumber.isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => unawaited(
                    _copyText(
                      result.partNumber,
                      context.tr('Артикул скопирован', 'Part # copied'),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.tint(AppColors.primary, 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          result.partNumber,
                          style: TextStyle(
                            color: AppColors.primaryOnCard,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Icon(
                          Icons.copy_rounded,
                          size: 15,
                          color: AppColors.primaryOnCard,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (result.fitsModelVerified != null ||
              result.compatibilityNote.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: result.fitsModelVerified == false
                    ? const Color(0xFFFEF3C7)
                    : const Color(0xFFDCFCE7).withValues(
                        alpha: AppColors.isDark ? 0.18 : 0.85,
                      ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    result.fitsModelVerified == false
                        ? Icons.warning_amber_rounded
                        : Icons.verified_rounded,
                    size: 18,
                    color: result.fitsModelVerified == false
                        ? const Color(0xFFD97706)
                        : const Color(0xFF15803D),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.compatibilityNote.isNotEmpty
                          ? result.compatibilityNote
                          : context.tr(
                              'Совместимость детали проверена по каталогу',
                              'Part compatibility verified against catalog',
                            ),
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (result.interchangeNumbers.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${context.tr('Кросс-номера', 'Replaces')}: ${result.interchangeNumbers.join(', ')}',
              style: TextStyle(color: AppColors.inkMuted, fontSize: 12.5),
            ),
          ],
          if (result.checksPerformed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              result.checksPerformed.last,
              style: TextStyle(
                color: AppColors.inkMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWarehouseBanner(
    BuildContext context,
    List<WarehousePartMatch> items,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.tint(const Color(0xFF16A34A), 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF16A34A).withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.inventory_2_rounded,
            color: Color(0xFF15803D),
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr(
                    'Уже есть на вашем складе',
                    'Already in your warehouse',
                  ),
                  style: TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 4),
                for (final item in items)
                  Text(
                    '${item.name} (${item.partNumber}) — ${item.quantity} ${context.tr('шт.', 'pcs')}',
                    style: TextStyle(color: AppColors.ink, fontSize: 13.5),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.accent.withValues(alpha: 0.28),
      labelStyle: TextStyle(
        color: AppColors.ink,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  Widget _buildOfferCard(
    BuildContext context, {
    required PartOffer offer,
    required bool isLowestOverall,
    required bool isLowestOem,
  }) {
    final highlight = isLowestOverall || isLowestOem;
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => unawaited(_openOfferUrl(offer)),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isLowestOverall
                  ? const Color(0xFF16A34A)
                  : (highlight ? AppColors.primary : AppColors.border),
              width: highlight ? 1.6 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (highlight) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isLowestOverall
                        ? const Color(0xFF16A34A)
                        : AppColors.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isLowestOverall
                        ? context.tr(
                            'Самая низкая цена в наличии',
                            'Lowest price in stock',
                          )
                        : context.tr(
                            'Лучшая цена за оригинал OEM',
                            'Lowest OEM price in stock',
                          ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offer.store,
                          style: TextStyle(
                            color: AppColors.ink,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          offer.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.inkMuted,
                            fontSize: 13.5,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        offer.formattedPrice.isNotEmpty
                            ? offer.formattedPrice
                            : context.tr('Цена на сайте', 'See store price'),
                        style: TextStyle(
                          color: offer.formattedPrice.isNotEmpty
                              ? const Color(0xFF15803D)
                              : AppColors.primaryOnCard,
                          fontSize: offer.formattedPrice.isNotEmpty ? 18 : 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (offer.matchedPartNumber.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            offer.matchedPartNumber,
                            style: TextStyle(
                              color: AppColors.inkMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _badge(
                    icon: Icons.check_circle_rounded,
                    text: context.tr('В наличии', 'In stock'),
                    fg: const Color(0xFF15803D),
                    bg: const Color(0xFFDCFCE7).withValues(
                      alpha: AppColors.isDark ? 0.18 : 0.9,
                    ),
                  ),
                  if (offer.isOem != null)
                    _badge(
                      icon: offer.isOem!
                          ? Icons.verified_outlined
                          : Icons.handyman_outlined,
                      text: offer.isOem!
                          ? context.tr('Оригинал OEM', 'Genuine OEM')
                          : context.tr('Аналог', 'Aftermarket'),
                      fg: offer.isOem!
                          ? const Color(0xFF1D4ED8)
                          : const Color(0xFFB45309),
                      bg: (offer.isOem!
                              ? const Color(0xFFDBEAFE)
                              : const Color(0xFFFEF3C7))
                          .withValues(alpha: AppColors.isDark ? 0.18 : 0.9),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => unawaited(_openOfferUrl(offer)),
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: Text(
                        context.tr('Открыть и купить', 'Open store page'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: context.tr('Скопировать ссылку', 'Copy link'),
                    onPressed: () => unawaited(
                      _copyText(
                        offer.url,
                        context.tr('Ссылка скопирована', 'Link copied'),
                      ),
                    ),
                    icon: Icon(Icons.copy_rounded, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge({
    required IconData icon,
    required String text,
    required Color fg,
    required Color bg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
