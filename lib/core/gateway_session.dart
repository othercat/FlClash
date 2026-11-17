import 'dart:async';
import 'dart:io';

import 'hotspot.dart';
import 'interface.dart';
import 'soft_router.dart';

/// Reapplies saved choices after a core reconnect, independently of settings UI.
/// No listener, TUN, node or system network setting is changed here.
class GatewaySession {
  final CoreHandlerInterface handler;
  final bool supported;
  bool _hotspot = true;
  bool _router = true;
  String _address = '';
  bool _ready = false;
  int _generation = 0;
  bool? _appliedHotspot;
  (bool, String)? _appliedRouter;
  Future<void> _queue = Future<void>.value();

  GatewaySession(this.handler, {bool? supported})
    : supported = supported ?? Platform.isMacOS;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void disconnect() {
    _ready = false;
    _generation++;
    _appliedHotspot = null;
    _appliedRouter = null;
  }

  Future<void> configure({
    required bool hotspot,
    required bool router,
    required String address,
  }) {
    _hotspot = hotspot;
    _router = router;
    _address = address;
    return _serial(_sync);
  }

  Future<void> ready() {
    _ready = true;
    return _serial(() async {
      // Setup can finish after an early start-listener notification. Recheck
      // immediately instead of waiting for the idle native timer.
      _appliedHotspot = null;
      _appliedRouter = null;
      await _sync();
    });
  }

  Future<void> _sync() async {
    if (!supported || !_ready) return;
    final generation = _generation;
    if (_appliedHotspot != _hotspot) {
      final enabled = _hotspot;
      try {
        final status = await handler.setHotspotGateway(enabled);
        if (generation != _generation || !_ready) return;
        if (status.enabled == enabled) _appliedHotspot = enabled;
      } catch (_) {
        // Keep the requested choice and retry on the next lifecycle/status
        // call. A failed RPC must never become a saved disabled preference.
      }
    }
    if (generation != _generation || !_ready) return;
    final wanted = (_router, _address);
    if (_appliedRouter != wanted) {
      try {
        final status = await handler.setSoftRouter(wanted.$1, wanted.$2);
        if (generation != _generation || !_ready) return;
        if (status.enabled == wanted.$1 &&
            (!wanted.$1 || status.selectedAddress == wanted.$2)) {
          _appliedRouter = wanted;
        }
      } catch (_) {
        // The independent hotspot choice can still be applied successfully.
      }
    }
  }

  Future<HotspotGatewayStatus> getHotspot() => _serial(() async {
    await _sync();
    return handler.getHotspotGateway();
  });

  Future<SoftRouterStatus> getRouter() => _serial(() async {
    await _sync();
    return handler.getSoftRouter();
  });

  Future<HotspotGatewayStatus> setHotspot(bool enabled) {
    _hotspot = enabled;
    return _serial(() async {
      final generation = _generation;
      final status = await handler.setHotspotGateway(enabled);
      if (generation == _generation && status.enabled == enabled) {
        _appliedHotspot = enabled;
      }
      return status;
    });
  }

  Future<SoftRouterStatus> setRouter(bool enabled, String address) {
    _router = enabled;
    _address = address;
    return _serial(() async {
      final generation = _generation;
      final status = await handler.setSoftRouter(enabled, address);
      if (generation == _generation &&
          status.enabled == enabled &&
          (!enabled || status.selectedAddress == address)) {
        _appliedRouter = (enabled, address);
      }
      return status;
    });
  }
}
