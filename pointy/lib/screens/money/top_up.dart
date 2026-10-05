import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../payment_lock.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';

/// Add money: to your balance with PayPal, or to a trip share from your
/// balance or with PayPal. After PayPal approves, the server finishes the
/// payment itself; this screen notices and shows the result.
class TopUpScreen extends StatefulWidget {
  const TopUpScreen({super.key, this.trip, this.suggestPaise});

  /// Null adds to your own balance.
  final Trip? trip;
  final int? suggestPaise;

  @override
  State<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends State<TopUpScreen> with WidgetsBindingObserver {
  late final _amount = TextEditingController(
      text: widget.suggestPaise != null && widget.suggestPaise! > 0 ? paiseToInput(_roundUp(widget.suggestPaise!)) : '');
  String _source = 'balance'; // for a trip: balance or paypal
  Deposit? _deposit; // a PayPal checkout waiting for approval
  Timer? _poll;
  bool _busy = false;
  Me? _me;

  bool get _forTrip => widget.trip != null;
  bool get _paypal => !_forTrip || _source == 'paypal';

  // Rounds up to whole rupees so suggested amounts look tidy.
  static int _roundUp(int paise) => ((paise + 99) ~/ 100) * 100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.me().then((m) {
      if (!mounted) return;
      setState(() {
        _me = m;
        if (_forTrip && m.personalBalancePaise <= 0) _source = 'paypal';
      });
    }).catchError((_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _amount.dispose();
    super.dispose();
  }

  // Coming back from the PayPal page: check straight away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _deposit != null) _check();
  }

  Future<void> _start(int paise) async {
    if (!_paypal && !await confirmPayment(context, 'Move ${formatPaise(paise)} from your balance to ${widget.trip!.name}')) return;
    setState(() => _busy = true);
    try {
      if (!_paypal) {
        await api.depositFromBalance(widget.trip!.id, paise, key: newIdempotencyKey());
        _done(paise, 'From your balance');
        return;
      }
      final d = _forTrip
          ? await api.startTripDeposit(widget.trip!.id, paise, key: newIdempotencyKey())
          : await api.startTopUp(paise, key: newIdempotencyKey());
      final url = Uri.parse(d.approveUrl);
      if (url.host.endsWith('.invalid')) {
        // Demo mode: PayPal is simulated and approves at once.
        await api.captureDeposit(d.paypalOrderId, key: newIdempotencyKey());
        _done(paise, 'PayPal (demo mode)');
        return;
      }
      setState(() => _deposit = d);
      await launchUrl(url, mode: LaunchMode.externalApplication);
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check(quiet: true));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Asks whether the payment finished; after approval it captures it.
  Future<void> _check({bool quiet = false}) async {
    final d = _deposit;
    if (d == null) return;
    try {
      var now = await api.deposit(d.paypalOrderId);
      if (!now.isCaptured && !quiet) now = await api.captureDeposit(d.paypalOrderId, key: newIdempotencyKey());
      if (now.isCaptured) _done(now.amountPaise, 'PayPal');
    } catch (e) {
      if (!quiet && mounted) showError(context, e);
    }
  }

  void _done(int paise, String via) {
    _poll?.cancel();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => SuccessScreen(
        title: 'Money added',
        amount: formatPaise(paise),
        subtitle: _forTrip ? 'to your share of ${widget.trip!.name}' : 'to your Pointy balance',
        rows: [('Paid with', via)],
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_deposit != null) return _waiting();
    final paise = parseToPaise(_amount.text);
    final balance = _me?.personalBalancePaise;
    final notEnough = !_paypal && paise != null && balance != null && paise > balance;
    return FlowScaffold(
      appBarTitle: 'Add money',
      title: _forTrip ? 'Add to ${widget.trip!.name}' : 'Add money',
      subtitle: _forTrip ? 'It goes into your share of the trip wallet.' : 'Pay with PayPal; it lands in your Pointy balance.',
      buttonLabel: notEnough ? 'Not enough balance' : (_paypal ? 'Continue to PayPal' : 'Add ${paise == null ? '' : formatPaise(paise)}'),
      busy: _busy,
      onNext: paise == null || notEnough ? null : () => _start(paise),
      footer: _paypal ? Text('Shown in rupees; PayPal sandbox charges the USD equivalent.', textAlign: TextAlign.center, style: AppText.small()) : null,
      children: [
        AmountField(controller: _amount, onChanged: () => setState(() {}), chipsRupees: const [500, 1000, 2000, 5000]),
        if (_forTrip) ...[
          const SectionTitle('Pay from'),
          _sourceTile('balance', Icons.account_balance_wallet_outlined, 'Your Pointy balance',
              balance == null ? 'Loading…' : '${formatPaise(balance)} available · instant'),
          const SizedBox(height: 8),
          _sourceTile('paypal', Icons.open_in_new_rounded, 'PayPal', 'Approve on PayPal, then come back'),
        ],
      ],
    );
  }

  Widget _sourceTile(String value, IconData icon, String title, String subtitle) {
    final on = _source == value;
    return Material(
      color: on ? AppColors.pine100 : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: on ? AppColors.pine700 : AppColors.line, width: on ? 2 : 1),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(icon, color: AppColors.pine700),
        title: Text(title, style: AppText.body(weight: FontWeight.w600)),
        subtitle: Text(subtitle, style: AppText.detail()),
        trailing: Icon(on ? Icons.radio_button_checked : Icons.radio_button_off, color: on ? AppColors.pine700 : AppColors.slate),
        onTap: () => setState(() => _source = value),
      ),
    );
  }

  Widget _waiting() {
    final d = _deposit!;
    return Scaffold(
      appBar: AppBar(title: const Text('Add money')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 4)),
            const SizedBox(height: 24),
            Text('Finish on PayPal', style: AppText.title()),
            const SizedBox(height: 8),
            Text('Approve ${formatPaise(d.amountPaise)} with your PayPal sandbox account. This screen updates by itself when it is done.',
                textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
            const Spacer(),
            FilledButton(onPressed: () => _check(), child: const Text("I've approved it")),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => launchUrl(Uri.parse(d.approveUrl), mode: LaunchMode.externalApplication),
              child: const Text('Open PayPal again'),
            ),
          ],
        ),
      ),
    );
  }
}
