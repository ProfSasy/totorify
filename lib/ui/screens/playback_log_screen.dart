import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_tokens.dart';

/// Shows the playback event log so a test session can be exported and shared.
class PlaybackLogScreen extends StatelessWidget {
  const PlaybackLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Log riproduzione', style: AppText.screenTitle(cs)),
        actions: [
          IconButton(
            tooltip: 'Copia tutto',
            icon: const Icon(Icons.copy_all),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(
                ClipboardData(text: PlaybackLogService.instance.export()),
              );
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Log copiato negli appunti'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Pulisci',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => PlaybackLogService.instance.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: PlaybackLogService.instance.revision,
        builder: (context, _, _) {
          final entries = PlaybackLogService.instance.entries;
          if (entries.isEmpty) {
            return Center(
              child: Text(
                'Nessun evento registrato.\nRiproduci un brano e torna qui.',
                textAlign: TextAlign.center,
                style: AppText.tileSubtitle(cs),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.xxl,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              // Newest first.
              final entry = entries[entries.length - 1 - index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText(
                  entry,
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontFamilyFallback: const ['Courier'],
                    fontSize: 11,
                    height: 1.35,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
