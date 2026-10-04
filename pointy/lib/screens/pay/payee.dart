import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import 'amount.dart';
import 'pay_draft.dart';
import 'scan.dart';
import 'step_scaffold.dart';

/// Step 1: who is being paid. Scan a code, type a phone or ID, or pick
/// someone you have paid before.
class PayeeScreen extends StatefulWidget {
  const PayeeScreen({super.key, required this.draft, this.tripOnly = false});

  final PayDraft draft;

  /// Set when opened from "Pay from this wallet", so the personal wallet is
  /// not offered later.
  final bool tripOnly;

  @override
  State<PayeeScreen> createState() => _PayeeScreenState();
}

class _PayeeScreenState extends State<PayeeScreen> {
  late Future<List<User>> _contacts;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _contacts = _load();
  }

  Future<List<User>> _load() async {
    await loadPayContext(widget.draft);
    return contactsFrom(await api.trips(), widget.draft.me!.user.id);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _find() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      applyScannedCode(widget.draft, text);
      widget.draft.payeeUserId = '';
    });
  }

  void _pick(User u) => setState(() {
        widget.draft
          ..payeeName = u.name
          ..payeeEmail = u.paypalEmail
          ..payeeUserId = u.id;
      });

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return StepScaffold(
      step: 0,
      title: 'Who are you paying?',
      buttonLabel: 'Next',
      onNext: d.payeeName.isEmpty
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => AmountScreen(draft: d, tripOnly: widget.tripOnly)),
              ),
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan a payee code'),
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ScanScreen(draft: d))),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _input,
          decoration: InputDecoration(
            labelText: 'Phone, email or PayPal ID',
            suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _find),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _find(),
        ),
        if (d.payeeName.isNotEmpty) ...[
          const SectionTitle('Payee found'),
          SurfaceCard(
            child: Row(
              children: [
                const TileIcon(Icons.storefront_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.payeeName, style: AppText.body(weight: FontWeight.w600)),
                      Text(d.payeeEmail.isEmpty ? 'No PayPal email yet' : d.payeeEmail, style: AppText.detail()),
                    ],
                  ),
                ),
                const Icon(Icons.check_circle, color: AppColors.pine500),
              ],
            ),
          ),
        ],
        const SectionTitle('People you pay'),
        FutureBuilder<List<User>>(
          future: _contacts,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}', style: AppText.detail(color: AppColors.error));
            if (!snap.hasData) return const LinearProgressIndicator();
            return Column(
              children: [
                for (final u in snap.data!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(backgroundColor: AppColors.pine100, child: Text(u.name[0])),
                    title: Text(u.name, style: AppText.body()),
                    subtitle: Text(u.paypalEmail, style: AppText.detail()),
                    trailing: d.payeeUserId == u.id ? const Icon(Icons.check, color: AppColors.pine700) : null,
                    onTap: () => _pick(u),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// People you share trips with, which is who the demo lets you pay again.
List<User> contactsFrom(List<Trip> trips, String myId) {
  final seen = <String, User>{};
  for (final t in trips) {
    for (final m in t.memberDetails) {
      if (m.user.id != myId) seen[m.user.id] = m.user;
    }
  }
  return seen.values.toList();
}

