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

  // 3. Read config for allowed domains and project name
  List<String> allowedDomains = [];
  String projectName = 'SMC ACE';
  final configFile = File('coverage_config.json');
  if (await configFile.exists()) {
    try {
      final configContent = await configFile.readAsString();
      final config = jsonDecode(configContent);
      if (config['allowedDomains'] != null) {
        allowedDomains = List<String>.from(config['allowedDomains']);
      }
      if (config['projectName'] != null) {
        projectName = config['projectName'] as String;
      }
      print('Loaded allowed domains: $allowedDomains');
      print('Loaded project name: $projectName');
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

  // 5. Create current summary JSON object.
  //    A single app version produces many pipeline runs, so history is keyed
  //    per build (version + CI build number) rather than per version — that is
  //    what lets the trend accumulate a point on every run instead of one
  //    doc per version being overwritten. Falls back to a timestamp when the
  //    build number is unavailable (e.g. local runs).
  final buildNumber = Platform.environment['BITBUCKET_BUILD_NUMBER'];
  final buildId = (buildNumber != null && buildNumber.isNotEmpty)
      ? buildNumber
      : 'local-${DateTime.now().toUtc().millisecondsSinceEpoch}';
  final currentSummary = {
    'version': version,
    'buildNumber': buildId,
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

  // 6.5 Upload to Cloud Firestore.
  //   Preferred: a service-account key JSON in the GCP_SA_KEY env var (a
  //   Bitbucket repository variable). Repo variables are auto-exposed to the
  //   pipeline as env vars, so no bitbucket-pipelines.yml change is needed.
  //   Falls back to the legacy FIREBASE_TOKEN (firebase login:ci refresh
  //   token) when no service account is configured.
  final projectId = await _getFirestoreProjectId() ?? 'ace-devlopment';
  final serviceAccountJson = Platform.environment['GCP_SA_KEY'];
  final firebaseToken = Platform.environment['FIREBASE_TOKEN'];
  String? accessToken;

  if (serviceAccountJson != null && serviceAccountJson.trim().isNotEmpty) {
    print('Found GCP_SA_KEY. Minting access token from service account...');
    accessToken = await _getAccessTokenFromServiceAccount(serviceAccountJson);
    if (accessToken == null) {
      print('Warning: Could not mint access token from service account.');
    }
  } else if (firebaseToken != null && firebaseToken.isNotEmpty) {
    print('GCP_SA_KEY not set. Falling back to FIREBASE_TOKEN...');
    accessToken = await _getGcpAccessToken(firebaseToken);
    if (accessToken == null) {
      print('Warning: Could not get GCP access token from FIREBASE_TOKEN.');
    }
  } else {
    print('Neither GCP_SA_KEY nor FIREBASE_TOKEN set. Skipping Firestore upload.');
  }

  if (accessToken != null) {
    // One document per build so the trend keeps growing across runs of the
    // same app version, instead of a single per-version doc being overwritten.
    final docId = '${version}_$buildId';
    await _uploadToFirestore(projectId, docId, currentSummary, accessToken);
  }

  // 7. Inject Auth config into dashboard and login files
  await applyConfigAndInject(allowedDomains, projectName);
}

Future<String?> _getFirestoreProjectId() async {
  final rcFile = File('.firebaserc');
  if (await rcFile.exists()) {
    try {
      final content = await rcFile.readAsString();
      final rc = jsonDecode(content);
      if (rc['projects'] != null && rc['projects']['default'] != null) {
        return rc['projects']['default'] as String;
      }
    } catch (e) {
      print('Warning: Failed to parse .firebaserc: $e');
    }
  }
  return null;
}

/// Mints a short-lived GCP access token from a service-account key JSON using
/// the OAuth 2.0 JWT-bearer flow. RS256 signing is done via the `openssl` CLI
/// so no external Dart packages are required (the script runs standalone).
Future<String?> _getAccessTokenFromServiceAccount(String saJson) async {
  try {
    final sa = jsonDecode(saJson) as Map<String, dynamic>;
    final clientEmail = sa['client_email'] as String?;
    final privateKey = sa['private_key'] as String?;
    final tokenUri =
        (sa['token_uri'] as String?) ?? 'https://oauth2.googleapis.com/token';
    if (clientEmail == null || privateKey == null) {
      print('Service account JSON missing client_email/private_key.');
      return null;
    }

    String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final header = b64url(utf8.encode(jsonEncode({'alg': 'RS256', 'typ': 'JWT'})));
    final claim = b64url(utf8.encode(jsonEncode({
      'iss': clientEmail,
      'scope': 'https://www.googleapis.com/auth/datastore',
      'aud': tokenUri,
      'iat': now,
      'exp': now + 3600,
    })));
    final signingInput = '$header.$claim';

    // Sign SHA-256/RSA (RS256) with openssl.
    final pkFile = File('${Directory.systemTemp.path}/coverage_sa_key.pem');
    await pkFile.writeAsString(privateKey);
    final proc =
        await Process.start('openssl', ['dgst', '-sha256', '-sign', pkFile.path]);
    proc.stdin.add(utf8.encode(signingInput));
    await proc.stdin.close();
    final sigBytes =
        await proc.stdout.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
    final errBytes =
        await proc.stderr.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
    final exitCode = await proc.exitCode;
    try {
      await pkFile.delete();
    } catch (_) {}
    if (exitCode != 0 || sigBytes.isEmpty) {
      print('openssl signing failed (exit $exitCode): ${utf8.decode(errBytes)}');
      return null;
    }
    final jwt = '$signingInput.${b64url(sigBytes)}';

    final client = HttpClient();
    final request = await client.postUrl(Uri.parse(tokenUri));
    request.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    final body =
        'grant_type=${Uri.encodeComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}'
        '&assertion=$jwt';
    request.write(body);
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    if (response.statusCode == 200) {
      return (jsonDecode(responseBody) as Map<String, dynamic>)['access_token']
          as String?;
    }
    print(
        'Error exchanging service-account JWT. Status: ${response.statusCode}, Body: $responseBody');
  } catch (e) {
    print('Failed to mint access token from service account: $e');
  }
  return null;
}

Future<String?> _getGcpAccessToken(String refreshToken) async {
  final url = Uri.parse('https://oauth2.googleapis.com/token');
  try {
    final client = HttpClient();
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    
    final body = 'grant_type=refresh_token'
        '&client_id=563584335869-5stnv87a38t76ca4te21ofaj74jt93ib.apps.googleusercontent.com'
        '&client_secret=0g62IL1j3LIqthP64iMrpHr9'
        '&refresh_token=$refreshToken';
    
    request.write(body);
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    
    if (response.statusCode == 200) {
      final json = jsonDecode(responseBody);
      return json['access_token'] as String?;
    } else {
      print('Error exchanging refresh token. Status: ${response.statusCode}, Body: $responseBody');
    }
  } catch (e) {
    print('Failed to get GCP access token: $e');
  }
  return null;
}

Map<String, dynamic> _toFirestoreDocument(Map<String, dynamic> data) {
  Map<String, dynamic> convertValue(dynamic val) {
    if (val is String) {
      return {'stringValue': val};
    } else if (val is int) {
      return {'integerValue': val.toString()};
    } else if (val is double) {
      return {'doubleValue': val};
    } else if (val is bool) {
      return {'booleanValue': val};
    } else if (val is List) {
      return {
        'arrayValue': {
          'values': val.map((e) => convertValue(e)).toList()
        }
      };
    } else if (val is Map) {
      final fieldsMap = <String, dynamic>{};
      val.forEach((k, v) {
        fieldsMap[k] = convertValue(v);
      });
      return {
        'mapValue': {
          'fields': fieldsMap
        }
      };
    }
    return {'nullValue': null};
  }

  final fields = <String, dynamic>{};
  data.forEach((k, v) {
    fields[k] = convertValue(v);
  });
  return {'fields': fields};
}

Future<void> _uploadToFirestore(String projectId, String docId, Map<String, dynamic> summary, String accessToken) async {
  final url = Uri.parse(
    'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/coverage_history/$docId'
  );
  
  final payload = _toFirestoreDocument(summary);
  
  try {
    final client = HttpClient();
    final request = await client.patchUrl(url);
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer $accessToken');
    request.write(jsonEncode(payload));
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    
    if (response.statusCode >= 200 && response.statusCode < 300) {
      print('Successfully uploaded coverage summary to Firestore for $docId');
    } else {
      print('Failed to upload to Firestore. Status: ${response.statusCode}, Body: $responseBody');
    }
  } catch (e) {
    print('Error sending patch request to Firestore: $e');
  }
}

Future<void> applyConfigAndInject(List<String> allowedDomains, String projectName) async {
  final domainsJson = jsonEncode(allowedDomains);

  // Update public/index.html
  final indexFile = File('public/index.html');
  if (await indexFile.exists()) {
    var content = await indexFile.readAsString();
    content = content.replaceAll('/*ALLOWED_DOMAINS_PLACEHOLDER*/', domainsJson);
    content = content.replaceAll('SMC ACE', projectName);
    await indexFile.writeAsString(content);
    print('Injected allowed domains and project name into public/index.html');
  }

  // Update public/login.html
  final loginFile = File('public/login.html');
  if (await loginFile.exists()) {
    var content = await loginFile.readAsString();
    content = content.replaceAll('/*ALLOWED_DOMAINS_PLACEHOLDER*/', domainsJson);
    content = content.replaceAll('SMC ACE', projectName);
    await loginFile.writeAsString(content);
    print('Injected allowed domains and project name into public/login.html');
  }

  // Recursively inject auth gate into all subpage LCOV HTML files
  final publicDir = Directory('public');
  int injectedCount = 0;
  await for (var entity in publicDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.html')) {
      final normalizedPath = entity.path.replaceAll('\\', '/');
      if (normalizedPath != 'public/login.html' && normalizedPath != 'public/index.html') {
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
  }
  print('Injected security auth gate into $injectedCount LCOV subpages.');
}
