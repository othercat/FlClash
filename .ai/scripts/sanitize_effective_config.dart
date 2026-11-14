// This diagnostics-only script reuses the YAML parser already locked by FlClash.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

Never _never(String message) {
  stderr.writeln(message);
  exit(2);
}

Map<Object?, Object?>? _asMap(Object? value) {
  if (value is Map) {
    return value.cast<Object?, Object?>();
  }
  return null;
}

Object? _read(Map<Object?, Object?>? map, String key) => map?[key];

Object? _safeScalar(Object? value) {
  if (value is bool || value is int || value is double) {
    return value;
  }
  if (value is String && value.length <= 64) {
    return value;
  }
  return null;
}

List<Object?> _asList(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is List) {
    return value.cast<Object?>();
  }
  return [value];
}

Map<String, Object> _addressSummary(Object? value) {
  final values = _asList(value);
  var ipv4Count = 0;
  var ipv6Count = 0;
  var otherCount = 0;

  for (final item in values) {
    if (item is! String) {
      otherCount += 1;
    } else if (item.contains(':')) {
      ipv6Count += 1;
    } else if (item.contains('.')) {
      ipv4Count += 1;
    } else {
      otherCount += 1;
    }
  }

  return {
    'present': values.isNotEmpty,
    'count': values.length,
    'ipv4Count': ipv4Count,
    'ipv6Count': ipv6Count,
    'otherCount': otherCount,
  };
}

Map<String, Object> _listSummary(Object? value) {
  final values = _asList(value);
  return {'present': values.isNotEmpty, 'count': values.length};
}

Map<String, Object?> _tunSummary(Map<Object?, Object?>? root) {
  final tun = _asMap(_read(root, 'tun'));
  return {
    'present': tun != null,
    'enable': _safeScalar(_read(tun, 'enable')),
    'stack': _safeScalar(_read(tun, 'stack')),
    'autoRoute': _safeScalar(_read(tun, 'auto-route')),
    'autoDetectInterface': _safeScalar(_read(tun, 'auto-detect-interface')),
    'strictRoute': _safeScalar(_read(tun, 'strict-route')),
    'mtu': _safeScalar(_read(tun, 'mtu')),
    'udpTimeout': _safeScalar(_read(tun, 'udp-timeout')),
    'endpointIndependentNat': _safeScalar(
      _read(tun, 'endpoint-independent-nat'),
    ),
    'inet4Address': _addressSummary(_read(tun, 'inet4-address')),
    'inet6Address': _addressSummary(_read(tun, 'inet6-address')),
    'routeAddress': _addressSummary(_read(tun, 'route-address')),
    'routeExcludeAddress': _addressSummary(_read(tun, 'route-exclude-address')),
    'dnsHijack': _listSummary(_read(tun, 'dns-hijack')),
  };
}

Map<String, Object?> _dnsSummary(Map<Object?, Object?>? root) {
  final dns = _asMap(_read(root, 'dns'));
  final fakeIpRange = _read(dns, 'fake-ip-range');
  return {
    'present': dns != null,
    'enable': _safeScalar(_read(dns, 'enable')),
    'ipv6': _safeScalar(_read(dns, 'ipv6')),
    'enhancedMode': _safeScalar(_read(dns, 'enhanced-mode')),
    'fakeIpRangePresent': fakeIpRange != null,
    'nameserver': _listSummary(_read(dns, 'nameserver')),
    'fallback': _listSummary(_read(dns, 'fallback')),
    'proxyServerNameserver': _listSummary(
      _read(dns, 'proxy-server-nameserver'),
    ),
  };
}

void main(List<String> arguments) {
  if (arguments.isEmpty || arguments.length > 2) {
    _never(
      'Usage: dart run .ai/scripts/sanitize_effective_config.dart '
      '<input.yaml> [output.json]',
    );
  }

  final input = File(arguments.first);
  if (!input.existsSync()) {
    _never('Input YAML does not exist.');
  }
  if (input.lengthSync() > 64 * 1024 * 1024) {
    _never('Input YAML exceeds the 64 MiB safety limit.');
  }

  Object? document;
  try {
    document = loadYaml(input.readAsStringSync());
  } on Object catch (error) {
    _never('YAML parse failed: ${error.runtimeType}.');
  }

  final root = _asMap(document);
  if (root == null) {
    _never('YAML root must be a mapping.');
  }

  final sanitized = <String, Object?>{
    'schema': 'flclash-phase1-effective-config-v1',
    'topLevel': {'ipv6': _safeScalar(_read(root, 'ipv6'))},
    'tun': _tunSummary(root),
    'dns': _dnsSummary(root),
    'omittedSensitiveSections': [
      'proxies',
      'proxy-providers',
      'proxy-groups',
      'rules',
      'rule-providers',
      'hosts',
      'secret',
      'nameserver values',
    ],
  };

  const encoder = JsonEncoder.withIndent('  ');
  final output = '${encoder.convert(sanitized)}\n';
  if (arguments.length == 2) {
    final outputFile = File(arguments[1]);
    outputFile.parent.createSync(recursive: true);
    outputFile.writeAsStringSync(output);
  } else {
    stdout.write(output);
  }
}
