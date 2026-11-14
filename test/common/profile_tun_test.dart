import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> generateProfile(Map<String, dynamic>? tun) async {
  final result = await makeRealProfileTask(
    MakeRealProfileState(
      profilesPath: 'profiles',
      profileId: 1,
      rawConfig: {
        'tun': ?tun,
        'dns': {'enable': true},
        'rules': ['MATCH,DIRECT'],
      },
      realPatchConfig: const PatchClashConfig(
        tun: Tun(enable: true, autoRoute: true),
      ),
      overrideDns: false,
      appendSystemDns: false,
      proxyGroups: [],
      rules: [],
      addedRules: [],
      defaultUA: 'FlClash-test',
    ),
  );
  return result.a;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('profile TUN interface detection', () {
    for (final enabled in [false, true]) {
      test('preserves explicit YAML value $enabled', () async {
        final yaml = await generateProfile({'auto-detect-interface': enabled});

        expect(yaml, contains('auto-detect-interface: $enabled'));
        expect(yaml, isNot(contains('AutoDetectInterface:')));
      });

      test('normalizes the core JSON value $enabled', () async {
        final yaml = await generateProfile({'AutoDetectInterface': enabled});

        expect(yaml, contains('auto-detect-interface: $enabled'));
        expect(yaml, isNot(contains('AutoDetectInterface:')));
      });
    }

    test('prefers the canonical field over the legacy alias', () async {
      final yaml = await generateProfile({
        'auto-detect-interface': false,
        'AutoDetectInterface': true,
      });

      expect(yaml, contains('auto-detect-interface: false'));
      expect(yaml, isNot(contains('AutoDetectInterface:')));
    });

    test('retains the core default when the field is omitted', () async {
      for (final tun in <Map<String, dynamic>?>[null, {}]) {
        final yaml = await generateProfile(tun);

        expect(yaml, contains('auto-detect-interface: true'));
      }
    });

    test('keeps unrelated TUN options and routing rules', () async {
      final yaml = await generateProfile({
        'AutoDetectInterface': false,
        'mtu': 1400,
        'strict-route': false,
        'route-exclude-address': ['10.0.0.0/8'],
      });

      expect(yaml, contains('auto-detect-interface: false'));
      expect(yaml, contains('mtu: 1400'));
      expect(yaml, contains('strict-route: false'));
      expect(yaml, contains('10.0.0.0/8'));
      expect(yaml, contains('MATCH,DIRECT'));
    });
  });
}
