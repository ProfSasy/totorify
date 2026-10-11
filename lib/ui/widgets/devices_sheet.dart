import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart' show audioHandler;
import '../../services/connect/connect_controller.dart';
import '../../services/connect/connect_protocol.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'app_sheet.dart';

/// Lets the user choose where the music plays: this device, or another one
/// running Totorify on the same network (a TV), which continues from the
/// same point; a device that is already playing is taken control of. While
/// another device plays, its volume is set from here.
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

  // The volume while the slider is dragged, and when it was last sent: the
  // other device is not told of every pixel.
  double? _draggedVolume;
  DateTime _volumeSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _connect.search();
  }

  @override
  void dispose() {
    _connect.stopListening();
    super.dispose();
  }

  void _dragVolume(double value) {
    setState(() => _draggedVolume = value);
    final now = DateTime.now();
    if (now.difference(_volumeSentAt) < const Duration(milliseconds: 80)) return;
    _volumeSentAt = now;
    audioHandler.setOutputVolume(value);
  }

  void _releaseVolume(double value) {
    audioHandler.setOutputVolume(value);
    setState(() => _draggedVolume = null);
  }

  /// The library the device has is somebody's: replacing it is asked twice.
  Future<void> _replaceLibrary(ConnectDevice device) async {
    final sure = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('Sostituire la libreria di ${device.name}?'),
        content: const Text(
          'Playlist, preferiti e artisti che ci sono ora lì verranno sostituiti '
          'con i tuoi. Da quel momento quello che cambi lì torna su questo telefono.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sostituisci'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    PlaybackLogService.instance.log('UI', 'dispositivi: la mia libreria su "${device.name}"');
    _connect.sendLibrary();
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
        _error = _connect.refused
            ? 'Su ${device.name} la richiesta non è stata accettata.'
            : 'Non riesco a raggiungere ${device.name}. '
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
      listenable: Listenable.merge([
        _connect.devices,
        _connect.scanning,
        _connect.activeDevice,
        _connect.libraryOwnedBy,
        _connect.waitingFor,
        audioHandler.outputVolumeNotifier,
      ]),
      builder: (context, _) {
        final active = _connect.activeDevice.value;
        final devices = _connect.devices.value;
        final scanning = _connect.scanning.value;
        final libraryOwner = _connect.libraryOwnedBy.value;
        final volume = _draggedVolume ?? audioHandler.outputVolumeNotifier.value;

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
            for (final device in devices) ...[
              SheetAction(
                icon: device.kind == ConnectDevice.kindPhone ? AppIcons.phone : AppIcons.tv,
                label: device.name,
                subtitle: active == device
                    ? 'In riproduzione'
                    : (_connecting == device.id && _connect.waitingFor.value != null
                        ? 'Conferma su ${device.name}…'
                        : (device.nowPlaying == null
                            ? device.host
                            : 'Sta suonando: ${device.nowPlaying}')),
                color: active == device ? cs.primary : null,
                trailing: _connecting == device.id
                    ? const CupertinoActivityIndicator(radius: 9)
                    : (active == device ? Icon(AppIcons.check, color: cs.primary) : null),
                onTap: () => _choose(device),
              ),
              // What belongs to the device that is playing, right under it.
              if (active == device) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.md, AppSpacing.sm),
                  child: Row(
                    children: [
                      Icon(AppIcons.volumeDown, color: cs.onSurfaceVariant, size: 22),
                      Expanded(
                        child: Semantics(
                          label: 'Volume di ${device.name}',
                          child: Slider(
                            value: volume.clamp(0.0, 1.0),
                            onChanged: _dragVolume,
                            onChangeEnd: _releaseVolume,
                          ),
                        ),
                      ),
                      Icon(AppIcons.volumeUp, color: cs.onSurfaceVariant, size: 22),
                      const SizedBox(width: AppSpacing.md),
                    ],
                  ),
                ),
                if (libraryOwner != null)
                  SheetAction(
                    icon: AppIcons.playlist,
                    label: 'Usa la mia libreria su ${device.name}',
                    subtitle: _connect.libraryThereIsItsOwn
                        ? 'Ora ha la sua'
                        : 'Ora ha quella di $libraryOwner',
                    onTap: () => _replaceLibrary(device),
                  ),
              ],
            ],
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
                onTap: _connect.search,
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
