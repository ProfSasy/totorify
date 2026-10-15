import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/storage_service.dart';
import 'settings_kit.dart';

/// Settings > Privacy: what the app remembers of what is played and
/// searched, and how to forget it.
class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final storage = StorageService.instance;
    return SettingsPage(
      title: 'Privacy',
      children: [
        SettingsSection(
          title: 'Cronologia degli ascolti',
          footer: 'Da qui nascono i mix, le statistiche e i suggerimenti della Home.',
          children: [
            SettingSwitch(
              setting: settings.pauseListenHistory,
              title: 'Metti in pausa la cronologia',
              subtitle: 'Quello che ascolti non viene ricordato',
            ),
            SettingLink(
              title: 'Cancella la cronologia degli ascolti',
              destructive: true,
              onTap: () async {
                final sure = await confirmAction(
                  context,
                  title: 'Cancellare la cronologia?',
                  message: 'Gli ascolti recenti e le statistiche ripartono da zero.',
                  confirm: 'Cancella',
                );
                if (!sure) return;
                PlaybackLogService.instance.log('UI', 'privacy: cancello la cronologia');
                await storage.clearHistory();
                if (context.mounted) _say(context, 'Cronologia cancellata');
              },
            ),
          ],
        ),
        SettingsSection(
          title: 'Ricerche',
          children: [
            SettingSwitch(
              setting: settings.pauseSearchHistory,
              title: 'Non ricordare le ricerche',
              subtitle: 'Le ricerche recenti non vengono salvate',
            ),
            SettingLink(
              title: 'Cancella le ricerche recenti',
              destructive: true,
              onTap: () async {
                PlaybackLogService.instance.log('UI', 'privacy: cancello le ricerche recenti');
                await storage.clearRecentSearches();
                if (context.mounted) _say(context, 'Ricerche recenti cancellate');
              },
            ),
          ],
        ),
      ],
    );
  }
}
