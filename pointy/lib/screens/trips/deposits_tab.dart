import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../assistant/assistant.dart';
import '../assistant/request_view.dart';

/// Deposits tab: how much is collected, who has paid, your own request if
/// the organiser asked you, and the requests the assistant sent.
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
    setState(() { _requests = api.requests(widget.trip.id); });
    widget.onChanged();
  }

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _reload();
  }

  Future<void> _remind(DepositRequest r) async {
    try {
      await api.remind(r.id, key: newIdempotencyKey());
      if (!mounted) return;
      showMessage(context, 'Reminder sent to ${firstName(r.user.name)}');
      _reload();
    } on ApiException catch (e) {
      if (mounted) showError(context, e.code == 'reminder_cap' ? 'Two reminders a day is the limit. Try tomorrow.' : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    final organiser = t.organiserId == widget.me.user.id;
    final target = t.targetPaise == 0 ? 1 : t.targetPaise;
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Collected', style: AppText.detail()),
                Text(t.targetPaise == 0 ? formatPaise(t.depositedPaise) : '${formatPaise(t.depositedPaise)} of ${formatPaise(t.targetPaise)}',
                    style: AppText.heading()),
                const SizedBox(height: 10),
                Bar(fraction: t.depositedPaise / target),
                const SizedBox(height: 6),
                Text(t.depositTargetPaise == 0 ? 'No deposit set' : '${formatPaise(t.depositTargetPaise)} each from ${t.members.length} people',
                    style: AppText.small()),
              ],
            ),
          ),
          FutureBuilder<List<DepositRequest>>(
            future: _requests,
            builder: (context, snap) {
              final mine = (snap.data ?? const <DepositRequest>[]).where((r) => r.user.id == widget.me.user.id && r.isOpen).toList();
              if (mine.isEmpty) return const SizedBox.shrink();
              final r = mine.first;
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Material(
                  color: AppColors.pendingBg,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _go(RequestViewScreen(trip: t, request: r)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.notification_important_outlined, color: AppColors.pending),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('You owe ${formatPaise(r.amountPaise)}', style: AppText.body(color: AppColors.pending, weight: FontWeight.w700)),
                                Text('Due ${formatWeekday(r.due)} · tap to pay', style: AppText.detail(color: AppColors.pending)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: AppColors.pending),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SectionTitle('Who has paid'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (final m in t.memberDetails)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Avatar(m.user.name),
                    title: Text(m.user.name, style: AppText.body()),
                    subtitle: Text(
                        t.depositTargetPaise == 0 ? 'Put in ${formatPaise(m.depositedPaise)}' : '${formatPaise(m.depositedPaise)} of ${formatPaise(t.depositTargetPaise)}',
                        style: AppText.detail()),
                    trailing: t.depositTargetPaise == 0
                        ? null
                        : (m.depositedPaise >= t.depositTargetPaise ? const Tag('Paid', kind: TagKind.trip) : const Tag('Pending', kind: TagKind.pending)),
                  ),
              ],
            ),
          ),
          if (organiser && t.isOpen) ...[
            const SizedBox(height: 16),
            AiCard(
              title: 'Let the assistant collect deposits',
              body: 'Say how much and by when. It drafts a request for each person and waits for your OK.',
              actionLabel: 'Open the assistant',
              onTap: () => _go(AssistantScreen(trip: t)),
            ),
          ],
          // Requests show up once someone has sent them; nothing to show before.
          FutureBuilder<List<DepositRequest>>(
            future: _requests,
            builder: (context, snap) {
              if (snap.hasError) return Text('${snap.error}', style: AppText.detail(color: AppColors.error));
              if (!snap.hasData || snap.data!.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [const SectionTitle('Requests and reminders'), for (final r in snap.data!) _requestRow(r, organiser)],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _requestRow(DepositRequest r, bool organiser) {
    final reminders = r.remindersSent == 0 ? 'no reminders' : '${r.remindersSent} reminder${r.remindersSent == 1 ? '' : 's'}';
    final (label, kind) = switch (r.status) {
      'paid' => ('Paid', TagKind.trip),
      'cancelled' => ('Cancelled', TagKind.plain),
      _ => ('Waiting', TagKind.pending),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: Avatar(r.user.name, size: 40),
          title: Text('${r.user.name} · ${formatPaise(r.amountPaise)}', style: AppText.body(weight: FontWeight.w600)),
          subtitle: Text(
            r.status == 'paid'
                ? 'Paid ${r.paidAt == null ? '' : formatDay(r.paidAt!)}${r.paidVia.isEmpty ? '' : ' via ${r.paidVia == 'balance' ? 'balance' : 'PayPal'}'}'
                : 'Due ${formatDay(r.due)} · $reminders',
            style: AppText.detail(),
          ),
          trailing: r.isOpen && organiser && r.user.id != widget.me.user.id && widget.trip.isOpen
              ? TextButton(onPressed: () => _remind(r), child: const Text('Remind'))
              : Tag(label, kind: kind),
          onTap: r.user.id == widget.me.user.id && r.isOpen ? () => _go(RequestViewScreen(trip: widget.trip, request: r)) : null,
        ),
      ),
    );
  }
}

