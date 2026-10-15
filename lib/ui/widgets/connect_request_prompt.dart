import 'package:flutter/cupertino.dart';

import '../../services/connect/connect_host.dart';

/// Puts to the user the question of a device that wants to play on this
/// one (see [ConnectHost]), over whatever [child] is showing. The question
/// goes away by itself when it is answered for the user (time ran out).
class ConnectRequestPrompt extends StatefulWidget {
  const ConnectRequestPrompt({super.key, required this.child});

  final Widget child;

  @override
  State<ConnectRequestPrompt> createState() => _ConnectRequestPromptState();
}

class _ConnectRequestPromptState extends State<ConnectRequestPrompt> {
  // The question, while it is shown.
  Route<void>? _shown;

  @override
  void initState() {
    super.initState();
    ConnectHost.instance.request.addListener(_onRequest);
    // One that arrived before this was on the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRequest());
  }

  @override
  void dispose() {
    ConnectHost.instance.request.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final shown = _shown;
    if (shown != null) {
      _shown = null;
      if (shown.isActive) navigator.removeRoute(shown);
    }
    final asked = ConnectHost.instance.request.value;
    if (asked == null) return;

    // Answering clears the request, which takes the question away.
    void answer({required bool allow, bool always = false}) =>
        ConnectHost.instance.answer(asked, allow: allow, always: always);

    final route = CupertinoDialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: CupertinoAlertDialog(
          title: Text(asked.listener ? 'Ascoltare insieme?' : 'Riprodurre su questo dispositivo?'),
          content: Text(
            asked.listener
                ? '"${asked.name}" vuole ascoltare quello che suona qui, in sincrono.'
                : '"${asked.name}" vuole far suonare la sua musica qui e comandarla. '
            'Quello che stai ascoltando verrà sostituito.',
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => answer(allow: true, always: true),
              child: const Text('Consenti sempre'),
            ),
            CupertinoDialogAction(
              onPressed: () => answer(allow: true),
              child: const Text('Solo questa volta'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => answer(allow: false),
              child: const Text('Rifiuta'),
            ),
          ],
        ),
      ),
    );
    _shown = route;
    navigator.push(route);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
