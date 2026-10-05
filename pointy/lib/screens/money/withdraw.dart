import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../payment_lock.dart';
import '../../theme.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import 'paypal_account.dart';

/// Withdraw: money out of your Pointy wallet to your PayPal account, from
/// where you move it to your bank. The only place money leaves Pointy.
class WithdrawScreen extends StatefulWidget {
  const WithdrawScreen({super.key});

  @override
  State<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends State<WithdrawScreen> {
  late Future<Me> _me = api.me();
  final _amount = TextEditingController();
  String _key = newIdempotencyKey();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _linkPayPal(String current) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PayPalAccountScreen(current: current)));
    if (saved == true && mounted) setState(() => _me = api.me());
  }

  Future<void> _send(Me me, int paise) async {
    if (!await confirmPayment(context, 'Withdraw ${formatPaise(paise)} to ${me.paypalEmail}')) return;
    setState(() => _busy = true);
    try {
      final p = await api.withdraw(paise, key: _key);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          pending: p.status != 'paid',
          title: p.status == 'paid' ? 'Sent to your PayPal' : 'On its way to PayPal',
          amount: formatPaise(p.amountPaise),
          subtitle: p.email,
          rows: [
            ('From', 'Your Pointy balance'),
            ('Through', 'PayPal Payouts'),
            ('Status', p.statusLabel),
            if (p.batchId.isNotEmpty) ('PayPal reference', p.batchId),
          ],
        ),
      ));
    } catch (e) {
      _key = newIdempotencyKey();
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<Me>(
      future: _me,
      onRetry: () => setState(() => _me = api.me()),
      builder: (context, me) {
        final paise = parseToPaise(_amount.text);
        final tooMuch = paise != null && paise > me.personalBalancePaise;
        final linked = me.paypalEmail.isNotEmpty;
        return FlowScaffold(
          appBarTitle: 'Withdraw',
          title: 'Withdraw to your bank',
          subtitle: 'You have ${formatPaise(me.personalBalancePaise)} in your Pointy balance.',
          hint: linked ? 'Pick an amount. It goes to your PayPal account; from there, move it to your bank.' : 'First add the PayPal account to send it to.',
          buttonLabel: !linked
              ? 'Add your PayPal email'
              : tooMuch
                  ? 'More than your balance'
                  : (paise == null ? 'Withdraw' : 'Withdraw ${formatPaise(paise)}'),
          busy: _busy,
          onNext: !linked ? () => _linkPayPal('') : (paise == null || tooMuch ? null : () => _send(me, paise)),
          footer: Text('You confirm with your PIN. If PayPal sends it back, it returns to your balance.',
              textAlign: TextAlign.center, style: AppText.small()),
          children: [
            if (linked) ...[
              AmountField(controller: _amount, onChanged: () => setState(() {}), chipsRupees: const [500, 1000, 2000]),
              if (me.personalBalancePaise > 0)
                Align(
                  child: TextButton(
                    onPressed: () => setState(() => _amount.text = paiseToInput(me.personalBalancePaise)),
                    child: Text('Withdraw everything (${formatPaise(me.personalBalancePaise)})'),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            SurfaceCard(
              child: Row(
                children: [
                  const Icon(Icons.account_balance_rounded, color: AppColors.personal),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('To your PayPal', style: AppText.detail()),
                        Text(linked ? me.paypalEmail : 'Not added yet', style: AppText.body(weight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  TextButton(onPressed: () => _linkPayPal(me.paypalEmail), child: Text(linked ? 'Change' : 'Add')),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
