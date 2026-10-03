import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import 'pay_draft.dart';
import 'step_scaffold.dart';
import 'wallet.dart';

/// Step 2: how much, and what it is for. The AI suggests a category; the
/// person can change it.
class AmountScreen extends StatefulWidget {
  const AmountScreen({super.key, required this.draft, this.tripOnly = false});

  final PayDraft draft;
  final bool tripOnly;

  @override
  State<AmountScreen> createState() => _AmountScreenState();
}

class _AmountScreenState extends State<AmountScreen> {
  late final TextEditingController _amount;
  late final TextEditingController _what;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _amount = TextEditingController(text: d.amountPaise > 0 ? paiseToInput(d.amountPaise) : '');
    _what = TextEditingController(text: d.description);
    if (d.suggestion == null) _suggest();
  }

  // Asks the backend for a category and wallet from the time and place.
  Future<void> _suggest() async {
    try {
      final s = await api.suggest(placeType: widget.draft.placeType, placeName: widget.draft.placeName);
      if (!mounted) return;
      setState(() => widget.draft.applySuggestion(s));
    } catch (_) {
      // A suggestion is a nice-to-have; the person can still pick by hand.
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _what.dispose();
    super.dispose();
  }

  Future<void> _changeCategory() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in categories)
              ListTile(
                leading: TileIcon(categoryIcon(c)),
                title: Text(categoryLabel(c)),
                onTap: () => Navigator.of(context).pop(c),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => widget.draft.category = picked);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final paise = parseToPaise(_amount.text);
    return StepScaffold(
      step: 1,
      title: 'How much?',
      buttonLabel: 'Next',
      onNext: paise == null || _what.text.trim().isEmpty
          ? null
          : () {
              d.amountPaise = paise;
              d.description = _what.text.trim();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => WalletScreen(draft: d, tripOnly: widget.tripOnly)));
            },
      children: [
        Text('Paying ${d.payeeName}', style: AppText.detail()),
        const SizedBox(height: 12),
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: AppText.balance(),
          decoration: const InputDecoration(prefixText: '₹ ', hintText: '0'),
          onChanged: (_) => setState(() {}),
        ),
        if (_amount.text.isNotEmpty && paise == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Enter rupees, with up to two decimal places', style: AppText.detail(color: AppColors.error)),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _what,
          decoration: const InputDecoration(labelText: 'What is it for?', hintText: 'Dinner, taxi, tickets...'),
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
        ),
        const SectionTitle('Category'),
        AiCard(
          title: categoryLabel(d.category),
          body: d.suggestion == null ? 'Pick what this payment is for.' : 'Suggested from the time and place.',
          reasons: d.suggestion?.reasons ?? const [],
          actionLabel: 'Change',
          onTap: _changeCategory,
        ),
      ],
    );
  }
}
