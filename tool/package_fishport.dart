// Run with the Flutter SDK on the build Mac. Target machines run only FlClash.
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

void runTool(String tool, List<String> args, {String? cwd}) {
  final result = Process.runSync(tool, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('$tool failed (exit ${result.exitCode})');
  }
}

void copyFile(String src, String dst) {
  File(dst).parent.createSync(recursive: true);
  File(src).copySync(dst);
}

void main(List<String> args) {
  final parser = ArgParser()
    ..addOption(
      'platform',
      allowed: ['macos-arm64', 'windows-x64'],
      mandatory: true,
    )
    ..addOption(
      'app',
      mandatory: true,
      help: 'Built FlClash.app or Windows release directory',
    )
    ..addOption(
      'runtime',
      mandatory: true,
      help: 'Compiled helper, vendor assets and app-local VC runtime files',
    )
    ..addOption('out', mandatory: true, help: 'New output ZIP');
  if (args.contains('--help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final options = parser.parse(args);
  final platform = options.option('platform')!;
  final mac = platform == 'macos-arm64';
  final appInput = p.absolute(options.option('app')!);
  final runtime = p.absolute(options.option('runtime')!);
  final out = File(p.absolute(options.option('out')!));
  if (out.existsSync()) throw StateError('The output archive already exists');
  final label = 'FlClash-Fishport-$platform';
  final temporary = Directory.systemTemp.createTempSync('flclash-package-');
  final partial = File('${out.path}.$pid.zip');
  try {
    final root = p.join(temporary.path, label);
    Directory(root).createSync();
    final app = mac ? p.join(root, 'FlClash.app') : root;
    final exe = mac ? p.join(app, 'Contents', 'MacOS') : app;
    final assets = mac
        ? p.join(app, 'Contents', 'Resources', 'Fishport')
        : p.join(app, 'Fishport');
    final native = mac ? 'FPPhantomCore' : 'FPPhantomCore.exe';
    final ui = mac ? 'FlClash' : 'FlClash.exe';
    final inputExe = mac
        ? p.join(appInput, 'Contents', 'MacOS', ui)
        : p.join(appInput, ui);
    if (!File(inputExe).existsSync()) {
      throw StateError('FlClash release executable is missing');
    }
    const personalFiles = {
      'fishport-pass.txt',
      'pass-fishport.txt',
      '20261114.yaml',
    };
    if (Directory(appInput)
        .listSync(recursive: true, followLinks: false)
        .any(
          (entry) =>
              personalFiles.contains(p.basename(entry.path).toLowerCase()),
        )) {
      throw StateError('Use a clean application build without personal files');
    }
    runTool('/usr/bin/ditto', [appInput, app]);
    for (final name in [
      'airport-id',
      'api-transport-bundle.b64',
      'rd.bin',
      'rs.bin',
    ]) {
      copyFile(p.join(runtime, name), p.join(assets, name));
    }
    copyFile(p.join(runtime, native), p.join(exe, native));
    if (mac) {
      final lib = p.join(app, 'Contents', 'Frameworks', 'libnfxcore.dylib');
      copyFile(p.join(runtime, 'libnfxcore.dylib'), lib);
      runTool('/bin/chmod', ['755', p.join(exe, native), lib]);
      runTool('/usr/bin/codesign', ['--verify', '--strict', lib]);
      runTool('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        p.join(exe, native),
      ]);
      runTool('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        '--preserve-metadata=entitlements,flags,identifier,requirements',
        app,
      ]);
      runTool('/usr/bin/codesign', ['--verify', '--strict', '--deep', app]);
    } else {
      copyFile(p.join(runtime, 'nfxcore.dll'), p.join(assets, 'nfxcore.dll'));
      for (final name in [
        'vcruntime140.dll',
        'vcruntime140_1.dll',
        'msvcp140.dll',
      ]) {
        copyFile(p.join(runtime, name), p.join(exe, name));
      }
      // The vendor DLL searches only its own directory and Windows System32.
      copyFile(
        p.join(runtime, 'vcruntime140.dll'),
        p.join(assets, 'vcruntime140.dll'),
      );
    }
    out.parent.createSync(recursive: true);
    if (mac) {
      runTool('/usr/bin/ditto', [
        '-c',
        '-k',
        '--norsrc',
        '--keepParent',
        root,
        partial.path,
      ]);
    } else {
      runTool('/usr/bin/zip', [
        '-q',
        '-r',
        partial.path,
        label,
      ], cwd: temporary.path);
    }
    runTool('/bin/chmod', ['600', partial.path]);
    runTool('/usr/bin/unzip', ['-tqq', partial.path]);
    partial.renameSync(out.path);
    stdout.writeln(out.path);
  } finally {
    if (partial.existsSync()) partial.deleteSync();
    temporary.deleteSync(recursive: true);
  }
}
