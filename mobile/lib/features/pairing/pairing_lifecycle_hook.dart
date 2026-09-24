import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import 'pairing_link.dart';

/// Keeps a pairing session alive across a trip to another app.
///
/// While [active], leaving the foreground starts an iOS background task and
/// calls [onBackgrounded]; coming back ends the task and calls [onResumed].
/// Only `hidden`/`paused` count as leaving: the Face ID sheet makes the app
/// `inactive` without suspending it, and must not trigger a reconnect.
void usePairingLifecycle({
  required bool active,
  required VoidCallback onBackgrounded,
  required Future<void> Function() onResumed,
}) {
  final task = useMemoized(PairingBackgroundTask.new);
  final away = useRef(false);
  final activeRef = useRef(active);
  activeRef.value = active;

  useEffect(() {
    if (!active && away.value) {
      away.value = false;
      unawaited(task.end());
    }
    return null;
  }, [active]);

  useEffect(
    () =>
        () => unawaited(task.end()),
    const [],
  );

  useOnAppLifecycleStateChange((previous, current) {
    switch (current) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (!activeRef.value || away.value) return;
        away.value = true;
        unawaited(task.begin());
        onBackgrounded();
      case AppLifecycleState.resumed:
        if (!away.value) return;
        away.value = false;
        unawaited(task.end());
        if (activeRef.value) unawaited(onResumed());
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  });
}
