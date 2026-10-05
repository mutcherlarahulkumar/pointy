import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api.dart';
import '../../family_mode.dart';
import '../../models.dart';
import '../../money.dart';
import '../../payment_lock.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/family_link_scene.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/section_title.dart';

/// The child's half of linking: what changes, then the code from the
/// parent's phone and the child's own PIN.
class AcceptInviteScreen extends StatefulWidget {
  const AcceptInviteScreen({super.key, required this.invite});
  final ChildView invite;

  @override
  State<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends State<AcceptInviteScreen> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    final pin = await pinValue(context, 'Accept with your own PIN');
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final c = await api.acceptFamilyInvite(widget.invite.linkId, _code.text, pin);
      if (!mounted) return;
      FamilyMode.isChild.value = true; // underneath, the app switches to the child version
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => FamilyLinkedScreen(
          parent: c.parent.name,
          child: c.child.name,
          forParent: false,
          limits: '${formatPaise(c.dailyLimitPaise)} a day · ${formatPaise(c.monthlyLimitPaise)} a month',
        ),
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _decline() async {
    try {
      await api.declineFamilyInvite(widget.invite.linkId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final parent = inv.parent.name;
    Widget item(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: AppColors.pine700),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: AppText.body())),
          ]),
        );
    return FlowScaffold(
      appBarTitle: 'Family',
      title: '$parent wants to look after your Pointy',
      subtitle: 'Only say yes if $parent is your parent or guardian.',
      buttonLabel: _code.text.length == 6 ? 'Accept with my PIN' : 'Type the 6-digit code',
      busy: _busy,
      onNext: _code.text.length == 6 ? _accept : null,
      footer: TextButton(onPressed: _busy ? null : _decline, child: const Text('No, keep my account as it is')),
      children: [
        SurfaceCard(
          child: Column(children: [
            item(Icons.visibility_outlined, '$parent sees your balance and every payment.'),
            item(Icons.speed_rounded, 'You can spend ${formatPaise(inv.dailyLimitPaise)} a day and ${formatPaise(inv.monthlyLimitPaise)} a month. More needs $parent\'s OK.'),
            item(Icons.block_rounded, 'No adding money with PayPal, withdrawing or trip wallets. $parent sends you pocket money.'),
            item(Icons.cake_outlined, 'On your 18th birthday your account becomes your own again.'),
          ]),
        ),
        const SectionTitle('The code on their phone'),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          onChanged: (_) => setState(() {}),
          style: AppText.title().copyWith(letterSpacing: 10),
          decoration: const InputDecoration(hintText: '••••••'),
        ),
      ],
    );
  }
}
