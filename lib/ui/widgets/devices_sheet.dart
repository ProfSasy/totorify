import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/connect/connect_controller.dart';
import '../../services/connect/connect_protocol.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'app_sheet.dart';

/// Lets the user choose where the music plays: this device, or another one
/// running Totorify on the same network (a TV), which continues from the
/// same point.
Future<void> showDevicesSheet(BuildContext context) {
  PlaybackLogService.instance.log('UI', 'dispositivi: apri');
  return showAppSheet<void>(context, builder: (_) => const _DevicesSheet());
}

class _DevicesSheet extends StatefulWidget {
  const _DevicesSheet();

  @override
  State<_DevicesSheet> createState() => _DevicesSheetState();
}

class _DevicesSheetState extends State<_DevicesSheet> {
  final ConnectController _connect = ConnectController.instance;

  /// Id of the device being connected to.
  String? _connecting;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect.scan();
  }

  Future<void> _choose(ConnectDevice device) async {
    if (_connecting != null) return;
    if (_connect.activeDevice.value == device) {
      Navigator.pop(context);
      return;
    }
    HapticFeedback.selectionClick();
    PlaybackLogService.instance.log('UI', 'dispositivi: scelgo "${device.name}"');
    setState(() {
      _connecting = device.id;
      _error = null;
    });
    final ok = await _connect.transferTo(device);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _connecting = null;
        _error = 'Non riesco a raggiungere ${device.name}. '
            'Controlla che Totorify sia aperto lì e che siate sulla stessa rete.';
      });
    }
  }

  Future<void> _backHere() async {
    if (_connect.activeDevice.value == null) {
      Navigator.pop(context);
      return;
    }
    HapticFeedback.selectionClick();
    PlaybackLogService.instance.log('UI', 'dispositivi: torno su questo dispositivo');
    Navigator.pop(context);
    await _connect.transferBack();
  }

  Future<void> _addByAddress() async {
    final address = await showCupertinoDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    final host = address?.trim() ?? '';
    if (host.isEmpty || !mounted) return;
    PlaybackLogService.instance.log('UI', 'dispositivi: provo l\'indirizzo $host');
    setState(() {
      _connecting = host;
      _error = null;
    });
    final device = await _connect.probe(host);
    if (!mounted) return;
    setState(() => _connecting = null);
    if (device == null) {
      setState(() => _error = 'A $host non risponde nessun Totorify.');
      return;
    }
    await _choose(device);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_connect.devices, _connect.scanning, _connect.activeDevice]),
      builder: (context, _) {
        final active = _connect.activeDevice.value;
        final devices = _connect.devices.value;
        final scanning = _connect.scanning.value;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitle(
              'Dove ascoltare',
              subtitle: 'La musica continua dal punto in cui è arrivata',
            ),
            SheetAction(
              icon: AppIcons.phone,
              label: 'Questo dispositivo',
              subtitle: active == null ? 'In riproduzione qui' : null,
              color: active == null ? cs.primary : null,
              trailing: active == null ? Icon(AppIcons.check, color: cs.primary) : null,
              onTap: _backHere,
            ),
            for (final device in devices)
              SheetAction(
                icon: AppIcons.tv,
                label: device.name,
                subtitle: active == device ? 'In riproduzione' : device.host,
                color: active == device ? cs.primary : null,
                trailing: _connecting == device.id
                    ? const CupertinoActivityIndicator(radius: 9)
                    : (active == device ? Icon(AppIcons.check, color: cs.primary) : null),
                onTap: () => _choose(device),
              ),
            if (scanning)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
                child: Row(
                  children: [
                    CupertinoActivityIndicator(radius: 9),
                    SizedBox(width: AppSpacing.lg),
                    Text('Cerco i dispositivi sulla rete…'),
                  ],
                ),
              )
            else if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
                child: Text(
                  'Nessun dispositivo trovato. Apri Totorify sulla TV, collegata '
                  'alla stessa rete Wi-Fi, e cerca di nuovo. La prima volta iOS '
                  'chiede il permesso di accedere alla rete locale: va concesso.',
                  style: AppText.caption(cs).copyWith(height: 1.4),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
                child: Text(
                  _error!,
                  style: AppText.caption(cs).copyWith(color: cs.error, height: 1.4),
                ),
              ),
            Divider(color: cs.outlineVariant, height: AppSpacing.lg),
            if (!scanning)
              SheetAction(
                icon: AppIcons.refresh,
                label: 'Cerca di nuovo',
                onTap: _connect.scan,
              ),
            SheetAction(
              icon: AppIcons.link,
              label: 'Aggiungi con l\'indirizzo',
              subtitle: 'È scritto sulla schermata di Totorify della TV',
              trailing: _connecting != null && !devices.any((d) => d.id == _connecting)
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              onTap: _addByAddress,
            ),
          ],
        );
      },
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Indirizzo della TV'),
      content: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: CupertinoTextField(
          controller: _controller,
          placeholder: '192.168.1.20',
          autofocus: true,
          autocorrect: false,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(context),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: const Text('Collega'),
          onPressed: () => Navigator.pop(context, _controller.text),
        ),
      ],
    );
  }
}

/// The glyph that opens the devices sheet; it lights up, with the device's
/// name beside it, while another device is playing.
class DevicesButton extends StatelessWidget {
  const DevicesButton({
    super.key,
    required this.remoteName,
    required this.accent,
    required this.idle,
    this.showName = true,
    this.size = 23,
  });

  final ValueListenable<String?> remoteName;
  final Color accent;
  final Color idle;
  final bool showName;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: remoteName,
      builder: (context, name, _) {
        final color = name == null ? idle : accent;
        return Semantics(
          button: true,
          label: name == null ? 'Scegli dove ascoltare' : 'In riproduzione su $name',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showDevicesSheet(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.devices, color: color, size: size),
                  if (name != null && showName) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
