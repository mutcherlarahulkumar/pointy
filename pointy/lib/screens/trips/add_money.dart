import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';

/// Add money to your share of a trip wallet: amount, PayPal approval, then
/// capture. The money only counts once it is captured.
class AddMoneyScreen extends StatefulWidget {
  const AddMoneyScreen({super.key, required this.trip});

  final Trip trip;

  @override
  State<AddMoneyScreen> createState() => _AddMoneyScreenState();
}

class _AddMoneyScreenState extends State<AddMoneyScreen> {
  final _amount = TextEditingController();
  Deposit? _deposit; // set once the PayPal order exists
  bool _busy = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final mine = widget.trip.member(api.userId);
    final missing = widget.trip.depositTargetPaise - (mine?.depositedPaise ?? 0);
    if (missing > 0) _amount.text = paiseToInput(missing);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  // Step 1: create the PayPal order and open its approve page.
  Future<void> _start() async {
    final paise = parseToPaise(_amount.text);
    if (paise == null) return;
    setState(() => _busy = true);
    try {
      final d = await api.startDeposit(widget.trip.id, paise, key: newIdempotencyKey());
      setState(() => _deposit = d);
      final url = Uri.parse(d.approveUrl);
      // The mock rail's link goes nowhere, so only open real PayPal pages.
      if (!url.host.endsWith('.invalid')) await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Step 2: after approving on PayPal, take the money into the wallet.
  // Capturing twice is safe: the backend credits once.
  Future<void> _capture() async {
    setState(() => _busy = true);
    try {
      await api.captureDeposit(_deposit!.paypalOrderId, key: newIdempotencyKey());
      setState(() => _done = true);
    } on ApiException catch (e) {
      if (mounted) {
        showError(context, e.code == 'paypal_error' ? 'PayPal has not approved it yet. Approve it, then try again.' : e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    final paise = parseToPaise(_amount.text);
    return Scaffold(
      appBar: AppBar(title: const Text('Add money')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_done ? 'Money added' : 'How much are you adding?', style: AppText.title()),
          const SizedBox(height: 4),
          Text('To your share of the ${t.name} wallet', style: AppText.detail()),
          const SizedBox(height: 16),
          if (_done) ...[
            const Icon(Icons.check_circle, color: AppColors.pine500, size: 56),
            const SizedBox(height: 8),
            Center(child: Text(formatPaise(_deposit!.amountPaise), style: AppText.balance())),
            Center(child: Text('is now in the trip wallet', style: AppText.body(color: AppColors.slate))),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ] else if (_deposit == null) ...[
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: AppText.balance(),
              decoration: const InputDecoration(prefixText: '₹ '),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final rupees in [500, 1000, 2000, 3000])
                  ActionChip(
                    label: Text(formatPaise(rupees * 100)),
                    onPressed: () => setState(() => _amount.text = '$rupees'),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy || paise == null ? null : _start,
              child: Text(paise == null ? 'Enter an amount' : 'Continue to PayPal'),
            ),
          ] else ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.open_in_new, color: AppColors.pine700),
                title: Text('Approve ${formatPaise(_deposit!.amountPaise)} on PayPal'),
                subtitle: Text('Order ${_deposit!.paypalOrderId}', style: AppText.detail()),
                onTap: () => launchUrl(Uri.parse(_deposit!.approveUrl), mode: LaunchMode.externalApplication),
              ),
            ),
            const SizedBox(height: 8),
            Text('When PayPal says it is approved, come back and finish.', style: AppText.detail()),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _capture, child: const Text("I've approved it, add the money")),
          ],
        ],
      ),
    );
  }
}
