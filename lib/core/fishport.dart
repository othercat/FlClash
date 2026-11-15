import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

enum FishportProblem {
  missing,
  format,
  unreadable,
  rejected,
  rateLimited,
  unavailable,
}

/// Resolves portable Phantom declarations only when a desktop profile uses them.
/// The helper owns its listening socket before its private handshake is returned.
class DesktopFishport extends ChangeNotifier {
  DesktopFishport({
    Future<Process> Function(String, List<String>)? startProcess,
  }) : _startProcess = startProcess ?? Process.start;

  final Future<Process> Function(String, List<String>) _startProcess;
  final _nodes = <int, Set<String>>{};
  FishportProblem? _problem;
  Process? _process;
  Future<Map<String, dynamic>>? _endpoint;
  int _generation = 0;

  FishportProblem? problemFor(int? profileId, String name) =>
      _nodes[profileId]?.contains(name) == true ? _problem : null;

  void _setProblem(FishportProblem? problem) {
    if (_problem == problem) return;
    _problem = problem;
    notifyListeners();
  }

  Future<void> configure(
    Map<String, dynamic> profile,
    String home, {
    required int profileId,
  }) async {
    final proxies = profile['proxies'];
    final marked = (proxies is List ? proxies : const [])
        .whereType<Map>()
        .where((node) => node['x-fishport-protocol'] == 'phantom')
        .toList();
    final names = marked
        .map((node) => node['name'])
        .whereType<String>()
        .toSet();
    if (!setEquals(_nodes[profileId] ?? const <String>{}, names)) {
      if (names.isEmpty) {
        _nodes.remove(profileId);
      } else {
        _nodes[profileId] = names;
      }
      notifyListeners();
    }
    if (marked.isEmpty) return;
    // All other proxies remain usable if the optional native component is absent.
    var endpoint = <String, dynamic>{'server': '127.0.0.1', 'port': 1};
    final pending = _endpoint ??= _start(home);
    try {
      endpoint = await pending;
    } catch (_) {
      if (identical(_endpoint, pending)) {
        _endpoint = null;
        _setProblem(FishportProblem.unavailable);
      }
    }
    for (final node in marked) {
      final display = node['name'];
      final identity = node['username'];
      if (display is! String || identity is! String || identity.isEmpty) {
        throw const FormatException('Invalid Fishport proxy identity');
      }
      node
        ..clear()
        ..addAll(<String, dynamic>{
          'name': display,
          'type': 'socks5',
          'username': identity,
          'udp': false,
          ...endpoint,
        });
    }
  }

  Future<Map<String, dynamic>> _start(String home) async {
    final dir = p.dirname(Platform.resolvedExecutable);
    final exe = Platform.isMacOS
        ? p.join(dir, 'FPPhantomCore')
        : p.join(dir, 'FPPhantomCore.exe');
    final generation = _generation;
    final process = await _startProcess(exe, [p.join(home, 'Fishport')]);
    if (generation != _generation) {
      await process.stdin.close();
      throw StateError('Fishport helper closed');
    }
    _process = process;
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) {
          _process = null;
          _endpoint = null;
          _setProblem(FishportProblem.unavailable);
        }
      }),
    );
    try {
      final handshake = Completer<String>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!handshake.isCompleted) {
                handshake.complete(line);
              } else if (identical(_process, process)) {
                _onStatus(line);
              }
            },
            onError: (Object error) {
              if (!handshake.isCompleted) handshake.completeError(error);
            },
            onDone: () {
              if (!handshake.isCompleted) {
                handshake.completeError(StateError('Fishport helper exited'));
              }
            },
          );
      final line = await handshake.future.timeout(const Duration(seconds: 10));
      final data = jsonDecode(line) as Map<String, dynamic>;
      final port = data['port'];
      final pin = data['fingerprint'];
      final secret = data['password'];
      if (port is! int ||
          port < 1 ||
          port > 65535 ||
          pin is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(pin) ||
          secret is! String ||
          secret.length < 32) {
        throw const FormatException('Invalid local Fishport endpoint');
      }
      return {
        'server': '127.0.0.1',
        'port': port,
        'tls': true,
        'fingerprint': pin,
        'password': secret,
      };
    } catch (_) {
      await process.stdin.close();
      rethrow;
    }
  }

  void _onStatus(String line) {
    try {
      final data = jsonDecode(line);
      if (data is! Map || data['state'] is! String) return;
      _setProblem(switch (data['state']) {
        'ready' || 'starting' => null,
        'account-file-missing' => FishportProblem.missing,
        'account-file-format' => FishportProblem.format,
        'account-file-unreadable' => FishportProblem.unreadable,
        'account-rejected' => FishportProblem.rejected,
        'rate-limited' => FishportProblem.rateLimited,
        _ => FishportProblem.unavailable,
      });
    } on FormatException {
      // Native diagnostics are not status events and may contain private data.
    }
  }

  Future<void> close() async {
    _generation++;
    final process = _process;
    _process = null;
    _endpoint = null;
    _nodes.clear();
    _setProblem(null);
    if (process != null) await process.stdin.close();
  }
}
