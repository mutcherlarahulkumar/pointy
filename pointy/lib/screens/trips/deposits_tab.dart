import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../assistant/assistant.dart';
import '../assistant/request_view.dart';

/// Deposits tab: how much is collected, who has paid, and the requests and
/// reminders the assistant sent.
class DepositsTab extends StatefulWidget {
  const DepositsTab({super.key, required this.trip, required this.me, required this.onChanged});

  final Trip trip;
  final Me me;
  final VoidCallback onChanged;

  @override
  State<DepositsTab> createState() => _DepositsTabState();
}

class _DepositsTabState extends State<DepositsTab> {
  late Future<List<DepositRequest>> _requests = api.requests(widget.trip.id);

  void _reload() {
    setState(() => _requests = api.requests(widget.trip.id));
    widget.onChanged();
  }

  Future<void> _remind(DepositRequest r) async {
    try {
      await api.remind(r.id, key: newIdempotencyKey());
      if (!mounted) return;
      showMessage(context, 'Reminder sent to ${widget.trip.nameOf(r.userId)}');
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      showError(context, e.code == 'reminder_cap' ? 'PayPal allows 2 reminders a day. Try again tomorrow.' : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    final organiser = t.organiserId == widget.me.user.id;
    final target = t.targetPaise == 0 ? 1 : t.targetPaise;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Collected', style: AppText.detail()),
              Text('${formatPaise(t.depositedPaise)} of ${formatPaise(t.targetPaise)}', style: AppText.heading()),
              const SizedBox(height: 10),
              Bar(fraction: t.depositedPaise / target),
              const SizedBox(height: 6),
              Text('${formatPaise(t.depositTargetPaise)} each from ${t.members.length} people', style: AppText.small()),
            ],
          ),
        ),
        const SectionTitle('Who has paid'),
        SurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              for (final m in t.memberDetails)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(backgroundColor: AppColors.pine100, child: Text(m.user.name[0])),
                  title: Text(m.user.name, style: AppText.body()),
                  subtitle: Text('${formatPaise(m.depositedPaise)} of ${formatPaise(t.depositTargetPaise)}',
                      style: AppText.detail()),
                  trailing: m.depositedPaise >= t.depositTargetPaise
                      ? const Tag('Paid', kind: TagKind.trip)
                      : const Tag('Pending', kind: TagKind.pending),
                ),
            ],
          ),
        ),
        if (organiser && t.isOpen) ...[
          const SizedBox(height: 16),
          AiCard(
            title: 'Let the assistant collect deposits',
            body: 'Tell it how much and by when. It drafts the requests and waits for your OK.',
            actionLabel: 'Open the assistant',
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AssistantScreen(trip: t)));
              _reload();
            },
          ),
        ],
        const SectionTitle('Requests and reminders'),
        FutureBuilder<List<DepositRequest>>(
          future: _requests,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}', style: AppText.detail(color: AppColors.error));
            if (!snap.hasData) return const LinearProgressIndicator();
            if (snap.data!.isEmpty) return Text('No requests sent yet.', style: AppText.detail());
            return Column(children: [for (final r in snap.data!) _requestRow(r, organiser)]);
          },
        ),
      ],
    );
  }

  Widget _requestRow(DepositRequest r, bool organiser) {
    final who = widget.trip.nameOf(r.userId);
    final reminders = r.remindersSent == 0
        ? 'no reminders'
        : '${r.remindersSent} reminder${r.remindersSent == 1 ? '' : 's'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          title: Text('$who · ${formatPaise(r.amountPaise)}', style: AppText.body(weight: FontWeight.w600)),
          subtitle: Text(
            r.isPaid
                ? 'Paid ${r.paidAt == null ? '' : formatDay(r.paidAt!)} · $reminders'
                : 'Due ${formatDay(r.due)} · $reminders',
            style: AppText.detail(),
          ),
          trailing: r.isPaid
              ? const Tag('Paid', kind: TagKind.trip)
              : organiser && widget.trip.isOpen
                  ? TextButton(onPressed: () => _remind(r), child: const Text('Remind'))
                  : const Tag('Pending', kind: TagKind.pending),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RequestViewScreen(trip: widget.trip, request: r, isMock: widget.me.isMock),
            ));
            _reload();
          },
        ),
      ),
    );
  }
}
