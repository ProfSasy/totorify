import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_tokens.dart';

/// Shows the diagnostic log so a test session can be copied and shared.
class PlaybackLogScreen extends StatelessWidget {
  const PlaybackLogScreen({super.key});

  // Enough to cover a test session without producing a paste too large to
  // send in a chat.
  static const int _copyLines = 600;

  Future<void> _copy(BuildContext context, String text, String confirmation) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      SnackBar(
        content: Text(confirmation),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _copyPrevious(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final previous = await PlaybackLogService.instance.previousSession(lastLines: _copyLines);
    if (previous == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Nessuna sessione precedente salvata'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: previous));
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Sessione precedente copiata'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final log = PlaybackLogService.instance;

    return Scaffold(
      appBar: AppBar(
        title: Text('Log', style: AppText.screenTitle(cs)),
        actions: [
          IconButton(
            tooltip: 'Pulisci',
            icon: const Icon(Icons.delete_outline),
            onPressed: log.clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: log.revision,
        builder: (context, _, _) {
          final entries = log.entries;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Build ${PlaybackLogService.buildId} · ${entries.length} righe · '
                      '${log.errorCount} errori',
                      style: AppText.caption(cs),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton.icon(
                      onPressed: () => _copy(
                        context,
                        log.export(lastLines: _copyLines),
                        'Log copiato: incollalo nella chat',
                      ),
                      icon: const Icon(Icons.copy_all, size: 18),
                      label: const Text('Copia log'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _copy(
                              context,
                              log.export(errorsOnly: true),
                              'Errori copiati',
                            ),
                            child: const Text('Solo errori'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _copyPrevious(context),
                            child: const Text('Sessione precedente'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          'Nessun evento registrato.',
                          style: AppText.tileSubtitle(cs),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          0,
                          AppSpacing.md,
                          AppSpacing.xxl,
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          // Newest first.
                          final entry = entries[entries.length - 1 - index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              entry.line,
                              style: TextStyle(
                                fontFamily: 'Menlo',
                                fontFamilyFallback: const ['Courier'],
                                fontSize: 11,
                                height: 1.35,
                                color: entry.isError ? cs.error : cs.onSurfaceVariant,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
