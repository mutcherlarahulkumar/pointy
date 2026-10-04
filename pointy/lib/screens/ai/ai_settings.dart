import 'package:flutter/material.dart';

import '../../prefs.dart';
import '../../theme.dart';
import '../../widgets/section_title.dart';

/// What the AI may use: one switch per kind of data.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('What the AI may use')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Location'),
                  subtitle: const Text('A rough location, read only when you pay'),
                  value: AiPrefs.location,
                  onChanged: (v) => setState(() => AiPrefs.location = v),
                ),
                SwitchListTile(
                  title: const Text('Time of day'),
                  subtitle: const Text('To tell dinner from a morning taxi'),
                  value: AiPrefs.time,
                  onChanged: (v) => setState(() => AiPrefs.time = v),
                ),
                SwitchListTile(
                  title: const Text('Past choices'),
                  subtitle: const Text('Which wallet and split you picked before'),
                  value: AiPrefs.pastChoices,
                  onChanged: (v) => setState(() => AiPrefs.pastChoices = v),
                ),
                SwitchListTile(
                  title: const Text('Trip assistant'),
                  subtitle: const Text('Drafting deposit requests for you to approve'),
                  value: AiPrefs.assistant,
                  onChanged: (v) => setState(() => AiPrefs.assistant = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.lock_outline, color: AppColors.pine700),
              const SizedBox(width: 8),
              Expanded(
                child: Text('It never moves money on its own. Every payment and request waits for your tap.',
                    style: AppText.body(weight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
