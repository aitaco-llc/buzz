import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pairing_socket.dart';

/// Creates the socket a [PairingLink] runs over. Matches [PairingSocket.new].
typedef PairingLinkSocketFactory =
    PairingSocket Function({
      required String wsUrl,
      required String ephemeralPrivkey,
      required void Function(List<dynamic> message) onMessage,
      required void Function(Object? error) onDisconnected,
    });

/// A NIP-AB relay connection that outlives the app going to the background.
///
/// Pairing two apps on one phone means one of them is always in the
/// background, where iOS suspends its socket. On return to the foreground,
/// [appResumed] reconnects with the same ephemeral key and sends the `REQ`
/// again, and the pair relay replays what it held for that `#p` (at most
/// 120 s). It also re-sends every event the relay has not acknowledged with
/// `OK`, because a write into a suspended socket may never have left the
/// phone. Receivers discard duplicates by event id (NIP-AB §Duplicate Event
/// Handling), so a re-send is safe.
class PairingLink {
  PairingLink({
    required PairingLinkSocketFactory socketFactory,
    required String wsUrl,
    required String ephemeralPrivkey,
    required String subscribePubkey,
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function(Object? error) onLost,
  }) : _socketFactory = socketFactory,
       _wsUrl = wsUrl,
       _ephemeralPrivkey = ephemeralPrivkey,
       _subscribePubkey = subscribePubkey,
       _onEvent = onEvent,
       _onLost = onLost;

  static const subscriptionId = 'pair';
  static const pairingKind = 24134;

  final PairingLinkSocketFactory _socketFactory;
  final String _wsUrl;
  final String _ephemeralPrivkey;
  final String _subscribePubkey;
  final void Function(Map<String, dynamic> event) _onEvent;
  final void Function(Object? error) _onLost;

  /// Events published but not yet acknowledged, in publish order.
  final Map<String, Map<String, dynamic>> _unacked = {};

  PairingSocket? _socket;
  int _socketGeneration = 0;
  bool _connected = false;
  bool _established = false;
  bool _background = false;
  bool _disposed = false;
  Future<void>? _reconnecting;

  bool get isConnected => _connected;

  /// Connects and subscribes. Throws when the first connection fails.
  Future<void> connect() => _open();

  /// Publishes [event] now if connected, and again after any reconnect until
  /// the relay acknowledges it.
  void publish(Map<String, dynamic> event) {
    final id = event['id'] as String;
    _unacked[id] = event;
    if (_connected) _socket?.publishEvent(event);
  }

  /// The app left the foreground. A disconnect from here on waits for
  /// [appResumed] instead of failing the session.
  void appBackgrounded() {
    _background = true;
  }

  /// The app is back in the foreground: reconnect and re-subscribe.
  Future<void> appResumed() {
    _background = false;
    if (_disposed) return Future.value();
    return _reconnect();
  }

  void dispose() {
    _disposed = true;
    _connected = false;
    _socketGeneration++;
    _socket?.dispose();
    _socket = null;
    _unacked.clear();
  }

  Future<void> _open() async {
    final generation = ++_socketGeneration;
    _socket?.dispose();
    final socket = _socketFactory(
      wsUrl: _wsUrl,
      ephemeralPrivkey: _ephemeralPrivkey,
      onMessage: (message) {
        if (generation == _socketGeneration) _handleMessage(message);
      },
      onDisconnected: (error) {
        if (generation == _socketGeneration) _handleDisconnected(error);
      },
    );
    _socket = socket;
    _connected = false;
    await socket.connect();
    if (_disposed || generation != _socketGeneration) return;
    if (!socket.isConnected) {
      throw StateError('Pairing socket did not reach the connected state');
    }
    _connected = true;
    _established = true;
    socket.subscribe(subscriptionId, pairingKind, _subscribePubkey);
    for (final event in _unacked.values.toList()) {
      socket.publishEvent(event);
    }
  }

  Future<void> _reconnect() {
    final inFlight = _reconnecting;
    if (inFlight != null) return inFlight;
    final attempt = Completer<void>();
    _reconnecting = attempt.future;
    // A failing attempt also reports through onDisconnected; that report is
    // ignored while [_reconnecting] is set and surfaces here instead.
    _open()
        .catchError((Object error) {
          if (_disposed) return;
          if (_background) return; // Try again on the next resume.
          _onLost(error);
        })
        .whenComplete(() {
          _reconnecting = null;
          attempt.complete();
        });
    return attempt.future;
  }

  void _handleDisconnected(Object? error) {
    _connected = false;
    if (_disposed) return;
    // Before the first connection there is no session to keep: report it.
    if (!_established) return _onLost(error);
    if (_background || _reconnecting != null) return;
    // Each drop in the foreground gets one reconnect; if that fails too, the
    // loss is reported.
    unawaited(_reconnect());
  }

  void _handleMessage(List<dynamic> data) {
    if (data.isEmpty) return;
    switch (data[0]) {
      case 'EVENT' when data.length >= 3 && data[2] is Map<String, dynamic>:
        _onEvent(data[2] as Map<String, dynamic>);
      case 'OK' when data.length >= 3 && data[2] == true:
        _unacked.remove(data[1]);
    }
  }
}

/// Holds an iOS background task while a pairing session is in the
/// background, so the other app has time to answer before the socket is
/// suspended. A no-op on other platforms.
class PairingBackgroundTask {
  PairingBackgroundTask([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('buzz/background_task');

  final MethodChannel _channel;

  Future<void> begin() => _invoke('begin');

  Future<void> end() => _invoke('end');

  Future<void> _invoke(String method) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>(method, {'name': 'buzz.pairing'});
    } on MissingPluginException {
      // Hosts without the channel (tests, iPad native shell) do nothing.
    } on PlatformException {
      // Best effort: the resume reconnect still recovers the session.
    }
  }
}
