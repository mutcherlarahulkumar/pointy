import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/tag.dart';

/// What a member sees for a deposit request: the amount, the due date, a
/// QR code of the PayPal pay link, and "Pay with PayPal".
class RequestViewScreen extends StatefulWidget {
  const RequestViewScreen({super.key, required this.trip, required this.request, required this.isMock});

  final Trip trip;
  final DepositRequest request;

  /// In mock mode there is no real PayPal invoice, so a demo button marks
  /// the request as paid instead.
  final bool isMock;

  @override
  State<RequestViewScreen> createState() => _RequestViewScreenState();
}

class _RequestViewScreenState extends State<RequestViewScreen> {
  late DepositRequest _r = widget.request;
  bool _busy = false;

  Future<void> _markPaid() async {
    setState(() => _busy = true);
    try {
      final r = await api.demoMarkPaid(_r.id);
      setState(() => _r = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final link = r.payUrl.isNotEmpty ? r.payUrl : 'https://www.paypal.com/invoice/p/#${r.paypalInvoiceId}';
    return Scaffold(
      appBar: AppBar(title: const Text('Deposit request')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${widget.trip.name} deposit', style: AppText.detail()),
          Text(formatPaise(r.amountPaise), style: AppText.balance()),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('For ${widget.trip.nameOf(r.userId)} · due ${formatWeekday(r.due)}', style: AppText.body()),
              const Spacer(),
              r.isPaid ? const Tag('Paid', kind: TagKind.trip) : const Tag('Pending', kind: TagKind.pending),
            ],
          ),
          const SizedBox(height: 24),
          if (!r.isPaid) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: QrImageView(data: link, size: 200),
              ),
            ),
            const SizedBox(height: 8),
            Center(child: Text('Scan to pay on PayPal', style: AppText.detail())),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: const Text('Pay with PayPal'),
              onPressed: r.payUrl.isEmpty
                  ? null
                  : () => launchUrl(Uri.parse(r.payUrl), mode: LaunchMode.externalApplication),
            ),
            if (widget.isMock) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _markPaid,
                child: const Text('Demo: mark as paid'),
              ),
            ],
          ] else
            Text('Paid ${r.paidAt == null ? '' : formatDateTime(r.paidAt!)}. Thank you!', style: AppText.body()),
          const SizedBox(height: 16),
          Text('Reference ${r.paypalInvoiceId}', style: AppText.small()),
        ],
      ),
    );
  }
}
