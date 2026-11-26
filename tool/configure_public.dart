import 'dart:convert';
import 'dart:io';

const publicConfigKeys = {
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'ONESIGNAL_APP_ID',
  'APP_ENVIRONMENT',
};

/// Only these public values may enter a Flutter build, even if .env has secrets.
Map<String, String> extractPublicConfig(String input) {
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(input)) {
    final match = RegExp(
      r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$',
    ).firstMatch(line);
    if (match == null || !publicConfigKeys.contains(match.group(1))) continue;
    var value = match.group(2)!;
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    values[match.group(1)!] = value;
  }
  return values;
}

Future<void> main(List<String> arguments) async {
  final source = File(arguments.isEmpty ? '.env' : arguments.single);
  if (!await source.exists()) {
    stderr.writeln(
      'Copy config/public.example.json to config/public.json, '
      'or provide a local .env file to this command.',
    );
    exitCode = 1;
    return;
  }
  final values = extractPublicConfig(await source.readAsString());
  for (final requiredKey in ['SUPABASE_URL', 'SUPABASE_ANON_KEY']) {
    if (values[requiredKey]?.isNotEmpty != true) {
      stderr.writeln('Missing public configuration: $requiredKey');
      exitCode = 1;
      return;
    }
  }
  final target = File('config/public.json');
  await target.parent.create(recursive: true);
  await target.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(values)}\n',
  );
  stdout.writeln(
    'Public configuration written to config/public.json. '
    'Private keys were excluded.',
  );
}
