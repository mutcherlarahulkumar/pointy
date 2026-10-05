import 'package:flutter/material.dart';

import '../../api.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/ai_mark.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import 'pay_flow.dart';
import 'request_flow.dart';

/// "Pay Dev 200 for chai": type (or dictate) a payment in one line. The AI
/// reads it and fills the usual screens; nothing is paid until the person
/// confirms there.
class QuickPayScreen extends StatefulWidget {
  const QuickPayScreen({super.key});

  @override
  State<QuickPayScreen> createState() => _QuickPayScreenState();
}

class _QuickPayScreenState extends State<QuickPayScreen> {
  static const _examples = ['Pay Dev 200 for chai', 'Ask Asha for 1.5k for the cab', 'Send 500 to 98765 43210'];

  final _text = TextEditingController();
  QuickPayRead? _read;
  Person? _picked; // chosen from the choices when a name fits several people
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _readIt() async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final r = await api.quickPay(text);
      if (!mounted) return;
      setState(() {
        _read = r;
        _picked = r.person;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  void _continue() {
    final r = _read!;
    final who = _picked!;
    final note = r.note.isEmpty ? null : r.note;
    final Widget next;
    if (r.isRequest) {
      next = RequestAmountScreen(person: who, amountPaise: r.amountPaise > 0 ? r.amountPaise : null, note: note);
    } else if (r.amountPaise > 0) {
      next = PayConfirmScreen(person: who, amountPaise: r.amountPaise, note: r.note);
    } else {
      next = PayAmountScreen(person: who, note: note);
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    final r = _read;
    final canGo = r != null && _picked != null;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [AiMark(size: 28), SizedBox(width: 10), Text('Say it')]),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Who and how much?', style: AppText.title()),
          const SizedBox(height: 4),
          Text('Type it the way you would say it. To speak, tap the mic on your keyboard.', style: AppText.detail()),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 200,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _readIt(),
            onChanged: (_) => setState(() => _read = null),
            decoration: InputDecoration(
              hintText: 'Pay Dev 200 for chai',
              counterText: '',
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Read it', icon: const Icon(Icons.arrow_upward_rounded), onPressed: _readIt),
            ),
          ),
          const SizedBox(height: 12),
          if (r == null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in _examples)
                  ActionChip(
                    label: Text(e),
                    onPressed: () {
                      _text.text = e;
                      _readIt();
                    },
                  ),
              ],
            )
          else ...[
            AiCard(
              title: r.reply,
              reasons: [r.isRequest ? 'Request' : 'Pay', r.source == 'ai' ? 'Read by AI' : 'Read by rules'],
            ),
            if (_picked != null && r.amountPaise > 0) ...[
              const SizedBox(height: 12),
              _Preview(person: _picked!, amountPaise: r.amountPaise, note: r.note, request: r.isRequest),
            ],
            if (r.choices.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final c in r.choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    color: _picked == c ? AppColors.pine100 : null,
                    child: ListTile(
                      leading: Avatar(c.name, size: 40),
                      title: Text(c.name, style: AppText.body(weight: FontWeight.w600)),
                      subtitle: Text('+91 ${formatPhone(c.phone)}', style: AppText.detail()),
                      trailing: _picked == c ? const Icon(Icons.check_circle, color: AppColors.pine700) : null,
                      onTap: () => setState(() => _picked = c),
                    ),
                  ),
                ),
            ],
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: canGo ? _continue : (r == null && !_busy ? _readIt : null),
            child: Text(canGo ? 'Continue' : 'Read it'),
          ),
        ),
      ),
    );
  }
}

/// What will happen if the person continues: who, how much, what for.
class _Preview extends StatelessWidget {
  const _Preview({required this.person, required this.amountPaise, required this.note, required this.request});

  final Person person;
  final int amountPaise;
  final String note;
  final bool request;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Avatar(person.name, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(request ? 'Ask ${person.name}' : 'Pay ${person.name}', style: AppText.body(weight: FontWeight.w600)),
                Text(note.isEmpty ? '+91 ${formatPhone(person.phone)}' : note, style: AppText.detail()),
              ],
            ),
          ),
          Text(formatPaise(amountPaise), style: AppText.heading(color: request ? AppColors.pending : AppColors.pine700)),
        ],
      ),
    );
  }
}
