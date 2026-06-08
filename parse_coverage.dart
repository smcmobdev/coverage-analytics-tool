import 'dart:io';
import 'dart:convert';

void main() async {
  // 1. Find the coverage file (prefer clean_lcov.info, fallback to lcov.info)
  var lcovFile = File('coverage/clean_lcov.info');
  if (!await lcovFile.exists()) {
    lcovFile = File('coverage/lcov.info');
  }

  if (!await lcovFile.exists()) {
    print('Error: Neither coverage/clean_lcov.info nor coverage/lcov.info was found.');
    exit(1);
  }

  print('Using coverage file: ${lcovFile.path}');

  // 2. Read android/app/build.gradle or pubspec.yaml to get version
  String version = 'unknown';
  final gradleFile = File('android/app/build.gradle');
  if (await gradleFile.exists()) {
    final gradleContent = await gradleFile.readAsString();
    final versionMatch = RegExp(r'''\bversionName\s+["']([^"']+)["']''').firstMatch(gradleContent);
    version = versionMatch?.group(1) ?? 'unknown';
    print('Parsed version from build.gradle: $version');
  }

  if (version == 'unknown') {
    final pubspecFile = File('pubspec.yaml');
    if (await pubspecFile.exists()) {
      final pubspecContent = await pubspecFile.readAsString();
      final versionMatch = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(pubspecContent);
      version = versionMatch?.group(1) ?? 'unknown';
      print('Parsed version from pubspec.yaml: $version');
    }
  }

  if (version == 'unknown') {
    version = '1.0.0';
    print('Version fallback: $version');
  }

  // 3. Read config for allowed domains
  List<String> allowedDomains = [];
  final configFile = File('coverage_config.json');
  if (await configFile.exists()) {
    try {
      final configContent = await configFile.readAsString();
      final config = jsonDecode(configContent);
      if (config['allowedDomains'] != null) {
        allowedDomains = List<String>.from(config['allowedDomains']);
      }
      print('Loaded allowed domains: $allowedDomains');
    } catch (e) {
      print('Warning: Failed to parse coverage_config.json: $e');
    }
  }

  // 4. Parse LCOV file
  final lines = await lcovFile.readAsLines();

  // Modules map
  final Map<String, Map<String, int>> moduleStats = {
    'core': {'total': 0, 'covered': 0},
    'feature': {'total': 0, 'covered': 0},
    'models': {'total': 0, 'covered': 0},
    'providers': {'total': 0, 'covered': 0},
    'services': {'total': 0, 'covered': 0},
    'utils': {'total': 0, 'covered': 0},
    'views': {'total': 0, 'covered': 0},
    'other': {'total': 0, 'covered': 0},
  };

  int totalLF = 0;
  int totalLH = 0;

  String currentFile = '';
  int currentLF = 0;
  int currentLH = 0;

  for (var line in lines) {
    if (line.startsWith('SF:')) {
      currentFile = line.substring(3);
      currentLF = 0;
      currentLH = 0;
    } else if (line.startsWith('LF:')) {
      currentLF = int.parse(line.substring(3));
    } else if (line.startsWith('LH:')) {
      currentLH = int.parse(line.substring(3));
    } else if (line == 'end_of_record') {
      totalLF += currentLF;
      totalLH += currentLH;

      final parts = currentFile.split('/');
      String module = 'other';
      if (parts.length > 1 && parts[0] == 'lib') {
        final folder = parts[1];
        if (moduleStats.containsKey(folder)) {
          module = folder;
        }
      }

      moduleStats[module]!['total'] = moduleStats[module]!['total']! + currentLF;
      moduleStats[module]!['covered'] = moduleStats[module]!['covered']! + currentLH;
    }
  }

  // 5. Create current summary JSON object
  final currentSummary = {
    'version': version,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'totalLines': totalLF,
    'coveredLines': totalLH,
    'coveragePercentage': totalLF > 0 ? double.parse((totalLH / totalLF * 100).toStringAsFixed(2)) : 0.0,
    'modules': moduleStats.entries.map((e) {
      final total = e.value['total']!;
      final covered = e.value['covered']!;
      return {
        'name': e.key,
        'total': total,
        'covered': covered,
        'percentage': total > 0 ? double.parse((covered / total * 100).toStringAsFixed(2)) : 0.0,
      };
    }).toList(),
  };

  // Ensure public/VERSION directory exists
  final versionDir = Directory('public/$version');
  if (!await versionDir.exists()) {
    await versionDir.create(recursive: true);
  }

  // Copy coverage/html/* to public/$version/
  final coverageHtmlDir = Directory('coverage/html');
  if (await coverageHtmlDir.exists()) {
    print('Copying coverage/html contents to public/$version...');
    final result = await Process.run('cp', ['-r', 'coverage/html/.', 'public/$version/']);
    if (result.exitCode != 0) {
      print('Error copying coverage HTML: ${result.stderr}');
    } else {
      print('Successfully copied coverage HTML to public/$version');
    }
  } else {
    print('Warning: coverage/html directory does not exist. No HTML reports copied.');
  }

  // Write version specific summary.json
  final summaryFile = File('public/$version/summary.json');
  await summaryFile.writeAsString(JsonEncoder.withIndent('  ').convert(currentSummary));
  print('Saved summary.json for version $version');

  // 6. Build/Update history.json by searching the public/ directory
  final publicDir = Directory('public');
  final List<Map<String, dynamic>> history = [];

  if (await publicDir.exists()) {
    await for (var entity in publicDir.list(recursive: false)) {
      if (entity is Directory) {
        final versionSummaryFile = File('${entity.path}/summary.json');
        if (await versionSummaryFile.exists()) {
          try {
            final content = await versionSummaryFile.readAsString();
            final Map<String, dynamic> data = jsonDecode(content);
            history.add(data);
          } catch (e) {
            print('Warning: Failed to parse summary.json for ${entity.path}: $e');
          }
        }
      }
    }
  }

  // Sort history chronologically
  history.sort((a, b) => (a['timestamp'] as String).compareTo(b['timestamp'] as String));

  // Compute version-over-version deltas
  for (int i = 0; i < history.length; i++) {
    if (i == 0) {
      history[i]['deltaLines'] = 0;
      history[i]['deltaCovered'] = 0;
      history[i]['deltaCoveragePercentage'] = 0.0;
    } else {
      final prev = history[i - 1];
      final curr = history[i];

      final int addedLines = (curr['totalLines'] as int) - (prev['totalLines'] as int);
      final int addedCovered = (curr['coveredLines'] as int) - (prev['coveredLines'] as int);

      curr['deltaLines'] = addedLines;
      curr['deltaCovered'] = addedCovered;
      curr['deltaCoveragePercentage'] = addedLines > 0
          ? double.parse((addedCovered / addedLines * 100).toStringAsFixed(2))
          : 0.0;
    }
  }

  // Write history.json
  final historyFile = File('public/history.json');
  await historyFile.writeAsString(JsonEncoder.withIndent('  ').convert(history));
  print('Saved history.json with ${history.length} records');

  // 7. Inject Auth config into dashboard and login files
  await applyConfigAndInject(allowedDomains);
}

Future<void> applyConfigAndInject(List<String> allowedDomains) async {
  final domainsJson = jsonEncode(allowedDomains);

  // Update public/index.html
  final indexFile = File('public/index.html');
  if (await indexFile.exists()) {
    var content = await indexFile.readAsString();
    content = content.replaceAll('/*ALLOWED_DOMAINS_PLACEHOLDER*/', domainsJson);
    await indexFile.writeAsString(content);
    print('Injected allowed domains into public/index.html');
  }

  // Update public/login.html
  final loginFile = File('public/login.html');
  if (await loginFile.exists()) {
    var content = await loginFile.readAsString();
    content = content.replaceAll('/*ALLOWED_DOMAINS_PLACEHOLDER*/', domainsJson);
    await loginFile.writeAsString(content);
    print('Injected allowed domains into public/login.html');
  }

  // Recursively inject auth gate into all subpage LCOV HTML files
  final publicDir = Directory('public');
  int injectedCount = 0;
  await for (var entity in publicDir.list(recursive: true)) {
    if (entity is File &&
        entity.path.endsWith('.html') &&
        !entity.path.endsWith('login.html') &&
        !entity.path.endsWith('index.html')) {
      var content = await entity.readAsString();
      if (!content.contains('auth_gate.js')) {
        // Prepend Firebase config script and auth gate to <head>
        content = content.replaceFirst('<head>', '''<head>
  <script>window.ALLOWED_DOMAINS = $domainsJson;</script>
  <script src="/__/firebase/10.10.0/firebase-app-compat.js"></script>
  <script src="/__/firebase/10.10.0/firebase-auth-compat.js"></script>
  <script src="/__/firebase/init.js"></script>
  <script src="/auth_gate.js"></script>''');
        await entity.writeAsString(content);
        injectedCount++;
      }
    }
  }
  print('Injected security auth gate into $injectedCount LCOV subpages.');
}
