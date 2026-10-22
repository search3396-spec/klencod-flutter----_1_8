import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() => runApp(const BotIdeApp());

const bg = Color(0xFF0B1020);
const panel = Color(0xFF121A2B);
const panel2 = Color(0xFF192338);
const accent = Color(0xFF62E6B5);
const muted = Color(0xFF9AA8BD);
const border = Color(0xFF253047);
const danger = Color(0xFFFF6B78);
const warnC = Color(0xFFFFC857);

final ValueNotifier<bool> arabicN = ValueNotifier(true);
String tr(String ar, String en) => arabicN.value ? ar : en;

// ======================= أدوات =======================

String baseName(String path) => path.split(Platform.pathSeparator).last;

String stripPy(String n) =>
    n.toLowerCase().endsWith('.py') ? n.substring(0, n.length - 3) : n;

String cleanName(String raw) {
  var n = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  n = stripPy(n).trim();
  while (n.startsWith('.')) {
    n = n.substring(1);
  }
  return n;
}

Future<Directory> rootDir() async {
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory('${root.path}/bot_ide_bots');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

List<File> commandFiles(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return [];
  final list = d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.py'))
      .toList();
  list.sort((a, b) => baseName(a.path).toLowerCase().compareTo(baseName(b.path).toLowerCase()));
  return list;
}

String readTokenSync(String dir) {
  final f = File('$dir/token.txt');
  if (!f.existsSync()) return '';
  return f.readAsStringSync().trim().replaceAll('"', '').replaceAll("'", '');
}

final tokenRe = RegExp(r'^\d+:[A-Za-z0-9_-]+$');

String unescape(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      b.write(n == 'n' ? '\n' : n == 't' ? '\t' : n);
      i++;
    } else {
      b.write(s[i]);
    }
  }
  return b.toString();
}

/// يرجع نص الرد من ملف الأمر، أو null لو ما فيه reply
String? parseReply(String code) {
  final re = RegExp(
    r'''^\s*reply\s*=\s*("""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')''',
    multiLine: true,
  );
  final m = re.firstMatch(code);
  if (m == null) return null;
  final raw = m.group(1)!;
  if (raw.startsWith('"""') || raw.startsWith("'''")) {
    return raw.substring(3, raw.length - 3);
  }
  return unescape(raw.substring(1, raw.length - 1));
}

String commandTemplate(String name) =>
    '# أمر: $name\n'
    '# اكتب ردك بين علامتي التنصيص. يمكنك استخدام:\n'
    '# {name} اسم المستخدم   {id} رقمه   {username} معرفه\n'
    '# للسطر الجديد اكتب \\n\n\n'
    'reply = "اكتب هنا رد الأمر"\n';

const startTemplate =
    '# أمر: start\n'
    '# يرد عند كتابة /start\n\n'
    'reply = "أهلاً {name}! أنا بوت يعمل من Bot IDE."\n';

Future<void> createBotFiles(Directory dir) async {
  await dir.create(recursive: true);
  final t = File('${dir.path}/token.txt');
  if (!await t.exists()) await t.writeAsString('');
  final s = File('${dir.path}/start.py');
  if (!await s.exists()) await s.writeAsString(startTemplate);
}

// ======================= محرك تيليجرام =======================

enum Lv { info, ok, warn, err }

class LogLine {
  LogLine(this.time, this.lv, this.text);
  final String time;
  final Lv lv;
  final String text;
}

final Map<String, TelegramRunner> runners = {};

TelegramRunner runnerFor(String dir) => runners.putIfAbsent(dir, () => TelegramRunner(dir));

void syncWakelock() {
  if (runners.values.any((r) => r.running)) {
    WakelockPlus.enable();
  } else {
    WakelockPlus.disable();
  }
}

class TelegramRunner extends ChangeNotifier {
  TelegramRunner(this.dir);
  final String dir;
  final List<LogLine> logs = [];
  bool running = false;
  String? username;
  HttpClient? _client;
  String _token = '';
  int _offset = 0;
  int _gen = 0;

  void log(Lv lv, String m) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    logs.insert(0, LogLine('${two(t.hour)}:${two(t.minute)}:${two(t.second)}', lv, m));
    if (logs.length > 300) logs.removeLast();
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  /// يقرأ كل ملفات الأوامر. verbose = يكتب تحذيرات في الطرفية
  Map<String, String> loadCommands({bool verbose = false}) {
    final out = <String, String>{};
    for (final f in commandFiles(dir)) {
      final name = stripPy(baseName(f.path)).toLowerCase();
      String code;
      try {
        code = f.readAsStringSync();
      } catch (e) {
        if (verbose) log(Lv.err, tr('تعذّر قراءة $name.py', 'Cannot read $name.py'));
        continue;
      }
      final reply = parseReply(code);
      if (reply == null) {
        if (verbose) {
          log(Lv.warn, tr('الملف $name.py ما فيه سطر reply = "..." فتم تجاهله',
              '$name.py has no reply = "..." line, skipped'));
        }
        continue;
      }
      if (reply.trim().isEmpty) {
        if (verbose) log(Lv.warn, tr('رد الأمر $name فارغ', 'Reply of $name is empty'));
        continue;
      }
      out[name] = reply;
    }
    return out;
  }

  Future<Map<String, dynamic>> _call(HttpClient client, String method, Map<String, dynamic> params,
      {int timeout = 20}) async {
    final req = await client.postUrl(Uri.parse('https://api.telegram.org/bot$_token/$method'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(params));
    final res = await req.close().timeout(Duration(seconds: timeout));
    final body = await res.transform(utf8.decoder).join().timeout(Duration(seconds: timeout));
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> start() async {
    if (running) return;
    log(Lv.info, tr('فحص ملفات البوت...', 'Checking bot files...'));

    final tf = File('$dir/token.txt');
    if (!tf.existsSync()) {
      log(Lv.err, tr('ملف token.txt غير موجود.', 'token.txt is missing.'));
      return;
    }
    final token = readTokenSync(dir);
    if (token.isEmpty) {
      log(Lv.err, tr('ملف token.txt فارغ. افتحه والصق التوكن من @BotFather.',
          'token.txt is empty. Open it and paste the token from @BotFather.'));
      return;
    }
    if (!tokenRe.hasMatch(token)) {
      log(Lv.err, tr('صيغة التوكن غير صحيحة. لازم تكون مثل 123456789:ABC...',
          'Invalid token format. Must look like 123456789:ABC...'));
      return;
    }
    final cmds = loadCommands(verbose: true);
    if (cmds.isEmpty) {
      log(Lv.err, tr('ما فيه أوامر صالحة. أنشئ ملف أمر فيه reply = "...".',
          'No valid commands. Create a command file with reply = "...".'));
      return;
    }
    log(Lv.ok, tr('الأوامر الجاهزة (${cmds.length}): ${cmds.keys.join(', ')}',
        'Ready commands (${cmds.length}): ${cmds.keys.join(', ')}'));

    _token = token;
    _offset = 0;
    username = null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    running = true;
    final gen = ++_gen;
    notifyListeners();
    syncWakelock();
    log(Lv.info, tr('جارٍ الاتصال بتيليجرام...', 'Connecting to Telegram...'));
    _loop(client, gen);
  }

  Future<void> stop({bool silent = false}) async {
    if (!running) return;
    running = false;
    _gen++;
    _client?.close(force: true);
    _client = null;
    if (!silent) log(Lv.warn, tr('تم إيقاف البوت', 'Bot stopped'));
    notifyListeners();
    syncWakelock();
  }

  String _netError(Object e) {
    if (e is SocketException) {
      return tr('لا يوجد اتصال بالإنترنت أو تيليجرام محجوب.', 'No internet, or Telegram is blocked.');
    }
    if (e is TimeoutException) return tr('انتهت مهلة الاتصال.', 'Connection timed out.');
    return e.toString();
  }

  Future<void> _loop(HttpClient client, int gen) async {
    bool alive() => running && gen == _gen;
    try {
      final me = await _call(client, 'getMe', {});
      if (!alive()) return;
      if (me['ok'] != true) {
        log(Lv.err, tr('التوكن مرفوض (${me['error_code']}): ${me['description']}',
            'Token rejected (${me['error_code']}): ${me['description']}'));
        await stop(silent: true);
        return;
      }
      username = me['result']['username'] as String?;
      log(Lv.ok, tr('متصل: @$username. البوت يعمل الآن.', 'Connected: @$username. Bot is running.'));
      await _call(client, 'deleteWebhook', {});
      notifyListeners();
    } catch (e) {
      if (!alive()) return;
      log(Lv.err, tr('فشل الاتصال: ${_netError(e)}', 'Connection failed: ${_netError(e)}'));
      await stop(silent: true);
      return;
    }

    while (alive()) {
      try {
        final r = await _call(
          client,
          'getUpdates',
          {'offset': _offset, 'timeout': 25, 'allowed_updates': ['message']},
          timeout: 40,
        );
        if (!alive()) break;
        if (r['ok'] != true) {
          final code = r['error_code'];
          if (code == 401) {
            log(Lv.err, tr('التوكن لم يعد صالحاً (401).', 'Token no longer valid (401).'));
            await stop(silent: true);
            return;
          }
          if (code == 409) {
            log(Lv.err, tr('خطأ 409: نفس التوكن يعمل في مكان آخر. أوقفه هناك.',
                'Error 409: same token is running elsewhere. Stop it there.'));
          } else {
            log(Lv.err, 'Telegram $code: ${r['description']}');
          }
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        for (final u in (r['result'] as List)) {
          _offset = (u['update_id'] as int) + 1;
          try {
            await _handle(client, u as Map<String, dynamic>);
          } catch (e) {
            if (!alive()) break;
            log(Lv.err, tr('فشل الرد: ${_netError(e)}', 'Reply failed: ${_netError(e)}'));
          }
        }
      } catch (e) {
        if (!alive()) break;
        log(Lv.warn, tr('خطأ اتصال (${_netError(e)}). إعادة المحاولة...', 'Connection error (${_netError(e)}). Retrying...'));
        await Future.delayed(const Duration(seconds: 4));
      }
    }
  }

  Future<void> _handle(HttpClient client, Map<String, dynamic> u) async {
    final m = u['message'];
    if (m == null) return;
    final text = m['text'];
    if (text is! String) return;
    final t = text.trim();
    if (t.isEmpty) return;

    final first = t.split(RegExp(r'\s')).first;
    final slash = first.startsWith('/');
    final name = (slash ? first.substring(1) : first).split('@').first.toLowerCase();
    if (name.isEmpty) return;
    final ascii = RegExp(r'^[a-z0-9_]+$').hasMatch(name);
    if (!slash && ascii) return;

    final from = m['from'] ?? {};
    final who = '${from['first_name'] ?? ''}';
    final cmds = loadCommands();
    final reply = cmds[name];
    if (reply == null) {
      if (slash) {
        log(Lv.warn, tr('وصل /$name من $who لكن ما عندك ملف اسمه $name.py',
            'Got /$name from $who but there is no $name.py file'));
      }
      return;
    }
    log(Lv.info, '← $name  ($who)');

    final text2 = reply
        .replaceAll('{name}', who)
        .replaceAll('{id}', '${from['id'] ?? ''}')
        .replaceAll('{username}', from['username'] != null ? '@${from['username']}' : '')
        .replaceAll('{chat_id}', '${m['chat']['id']}');

    final r = await _call(client, 'sendMessage', {
      'chat_id': m['chat']['id'],
      'text': text2,
      'reply_parameters': {'message_id': m['message_id']},
    });
    if (r['ok'] == true) {
      log(Lv.ok, tr('→ تم الرد على $name', '→ Replied to $name'));
    } else {
      log(Lv.err, '→ ${r['error_code']}: ${r['description']}');
    }
  }
}

// ======================= التطبيق =======================

class BotIdeApp extends StatelessWidget {
  const BotIdeApp({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: arabicN,
    builder: (_, ar, __) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bot IDE',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(primary: accent, surface: panel),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      builder: (ctx, child) => Directionality(
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.15,
          child: child!,
        ),
      ),
      home: const HomeScreen(),
    ),
  );
}

class BotProject {
  BotProject(this.name, this.path);
  final String name;
  final String path;
}

Future<String?> askText(BuildContext context, String title, String hint, String initial) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: panel,
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('إلغاء', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(tr('موافق', 'OK'))),
      ],
    ),
  );
  c.dispose();
  return r;
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: panel,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('إلغاء', 'Cancel'))),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: danger),
          child: Text(tr('حذف', 'Delete')),
        ),
      ],
    ),
  );
  return ok == true;
}

void notify(BuildContext context, String message) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

// ======================= الشاشة الرئيسية =======================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<BotProject> projects = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = await rootDir();
    final found = <BotProject>[];
    await for (final e in root.list()) {
      if (e is Directory) found.add(BotProject(baseName(e.path), e.path));
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!mounted) return;
    setState(() {
      projects..clear()..addAll(found);
      loading = false;
    });
  }

  Future<void> _open(BotProject p) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => BotScreen(project: p)));
    _load();
  }

  Future<void> _newBot() async {
    final raw = await askText(context, tr('إنشاء بوت جديد', 'Create a new bot'),
        tr('اسم البوت (مثل: سام)', 'Bot name (e.g. Sam)'), '');
    if (raw == null) return;
    final name = cleanName(raw);
    if (name.isEmpty) return;
    final root = await rootDir();
    final dir = Directory('${root.path}/$name');
    if (await dir.exists()) {
      if (mounted) notify(context, tr('يوجد بوت بهذا الاسم بالفعل', 'A bot with that name already exists'));
      return;
    }
    await createBotFiles(dir);
    if (!mounted) return;
    await _open(BotProject(name, dir.path));
  }

  Future<void> _delete(BotProject p) async {
    final ok = await confirm(context, tr('حذف البوت', 'Delete bot'),
        tr('هل تريد حذف ${p.name} وكل ملفاته نهائياً؟', 'Delete ${p.name} and all its files permanently?'));
    if (!ok) return;
    final r = runners.remove(p.path);
    await r?.stop(silent: true);
    final d = Directory(p.path);
    if (await d.exists()) await d.delete(recursive: true);
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        _topBar(),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : projects.isEmpty
                  ? _empty()
                  : _list(),
        ),
        _bottomBar(),
      ]),
    ),
  );

  Widget _topBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: const BoxDecoration(color: panel, border: Border(bottom: BorderSide(color: border))),
    child: Row(children: [
      Container(
        width: 38, height: 38,
        decoration: BoxDecoration(color: accent.withValues(alpha: .13), borderRadius: BorderRadius.circular(11)),
        child: const Icon(Icons.terminal, color: accent),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Bot IDE', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
          Text(tr('بوتاتي', 'MY BOTS'), style: const TextStyle(fontSize: 9, color: muted, letterSpacing: 1)),
        ]),
      ),
      IconButton(
        tooltip: 'العربية / English',
        onPressed: () => arabicN.value = !arabicN.value,
        icon: const Icon(Icons.language),
      ),
    ]),
  );

  Widget _empty() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 88, height: 88,
          decoration: BoxDecoration(color: accent.withValues(alpha: .1), borderRadius: BorderRadius.circular(24)),
          child: const Icon(Icons.smart_toy_outlined, color: accent, size: 48),
        ),
        const SizedBox(height: 22),
        Text(tr('مرحباً بك في Bot IDE', 'Welcome to Bot IDE'),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text(
          tr('ما عندك بوتات حالياً. أنشئ أول بوت، ضع التوكن، وأضف أوامرك.',
              'No bots yet. Create your first bot, add the token, then add commands.'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 13, height: 1.6),
        ),
      ]),
    ),
  );

  Widget _list() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: projects.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final p = projects[i];
          final isRunning = runners[p.path]?.running ?? false;
          final cmdCount = commandFiles(p.path).length;
          return Material(
            color: panel,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _open(p),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: border),
                ),
                child: Row(children: [
                  Container(
                    width: 42, height: 42,
                    decoration: BoxDecoration(color: accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.smart_toy_outlined, color: accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 3),
                      Row(children: [
                        Icon(Icons.circle, size: 8, color: isRunning ? accent : muted),
                        const SizedBox(width: 5),
                        Text(
                          '${isRunning ? tr('يعمل', 'Running') : tr('متوقف', 'Stopped')} • $cmdCount ${tr('أمر', 'cmds')}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ]),
                    ]),
                  ),
                  PopupMenuButton<String>(
                    color: panel2,
                    onSelected: (v) {
                      if (v == 'del') _delete(p);
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'del', child: Text(tr('حذف', 'Delete'))),
                    ],
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _bottomBar() => Container(
    padding: const EdgeInsets.all(12),
    decoration: const BoxDecoration(color: panel, border: Border(top: BorderSide(color: border))),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _newBot,
            icon: const Icon(Icons.add),
            label: Text(tr('بوت جديد', 'New bot')),
            style: FilledButton.styleFrom(
              backgroundColor: accent, foregroundColor: bg,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ),
    ),
  );
}

// ======================= شاشة البوت =======================

class BotScreen extends StatefulWidget {
  const BotScreen({super.key, required this.project});
  final BotProject project;
  @override
  State<BotScreen> createState() => _BotScreenState();
}

class _BotScreenState extends State<BotScreen> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 2, vsync: this);
  late final TelegramRunner runner = runnerFor(widget.project.path);
  List<File> files = [];
  String token = '';

  BotProject get p => widget.project;

  @override
  void initState() {
    super.initState();
    createBotFiles(Directory(p.path)).then((_) => _reload());
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      files = commandFiles(p.path);
      token = readTokenSync(p.path);
    });
  }

  Future<void> _openFile(String path, {bool isToken = false}) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => FileEditor(path: path, isToken: isToken)));
    _reload();
  }

  Future<void> _newCommand() async {
    final raw = await askText(context, tr('ملف أمر جديد', 'New command file'),
        tr('اسم الأمر (مثل: ايدي)', 'Command name (e.g. id)'), '');
    if (raw == null) return;
    final name = cleanName(raw).replaceAll(' ', '_');
    if (name.isEmpty || name.toLowerCase() == 'token') return;
    final f = File('${p.path}/$name.py');
    if (await f.exists()) {
      if (mounted) notify(context, tr('الأمر موجود بالفعل', 'Command already exists'));
      return;
    }
    await f.writeAsString(commandTemplate(name));
    _reload();
    if (mounted) await _openFile(f.path);
  }

  Future<void> _import() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['py'], withData: false);
    if (result == null || result.files.single.path == null) return;
    final code = await File(result.files.single.path!).readAsString();
    var name = stripPy(result.files.single.name);
    var target = File('${p.path}/$name.py');
    if (await target.exists()) target = File('${p.path}/${name}_imported.py');
    await target.writeAsString(code);
    _reload();
  }

  Future<void> _deleteCommand(File f) async {
    final name = stripPy(baseName(f.path));
    final ok = await confirm(context, tr('حذف الأمر', 'Delete command'),
        tr('هل تريد حذف $name؟', 'Delete $name?'));
    if (!ok) return;
    await f.delete();
    _reload();
  }

  Future<void> _toggleRun() async {
    if (runner.running) {
      await runner.stop();
      return;
    }
    tabs.animateTo(1);
    await runner.start();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        _topBar(),
        Container(
          color: panel,
          child: TabBar(
            controller: tabs,
            indicatorColor: accent,
            labelColor: Colors.white,
            unselectedLabelColor: muted,
            labelStyle: const TextStyle(fontSize: 12),
            dividerColor: border,
            tabs: [
              Tab(icon: const Icon(Icons.folder_outlined, size: 16), text: tr('الملفات', 'Files'),
                  iconMargin: const EdgeInsets.only(bottom: 2)),
              Tab(icon: const Icon(Icons.terminal, size: 16), text: tr('الطرفية', 'Terminal'),
                  iconMargin: const EdgeInsets.only(bottom: 2)),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: tabs,
            physics: const NeverScrollableScrollPhysics(),
            children: [_filesPane(), _terminalPane()],
          ),
        ),
      ]),
    ),
  );

  Widget _topBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    color: panel,
    child: ListenableBuilder(
      listenable: runner,
      builder: (context, _) {
        final running = runner.running;
        return Row(children: [
          IconButton(
            tooltip: tr('رجوع', 'Back'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Text(p.name, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: FilledButton.icon(
              onPressed: _toggleRun,
              style: FilledButton.styleFrom(
                  backgroundColor: running ? danger : accent, foregroundColor: bg),
              icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 18),
              label: Text(running ? tr('إيقاف', 'Stop') : tr('تشغيل', 'Run')),
            ),
          ),
        ]);
      },
    ),
  );

  Widget _card({required Widget child, VoidCallback? onTap}) => Material(
    color: panel,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: border)),
        child: child,
      ),
    ),
  );

  Widget _filesPane() => Column(children: [
    Expanded(
      child: ListView(padding: const EdgeInsets.all(12), children: [
        _card(
          onTap: () => _openFile('${p.path}/token.txt', isToken: true),
          child: Row(children: [
            Icon(Icons.key, size: 20, color: token.isEmpty ? warnC : accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('token.txt', textDirection: TextDirection.ltr,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  token.isEmpty
                      ? tr('فارغ — اضغط والصق التوكن', 'Empty — tap and paste the token')
                      : (tokenRe.hasMatch(token) ? tr('التوكن مضبوط', 'Token set') : tr('صيغة التوكن غير صحيحة', 'Invalid token format')),
                  style: TextStyle(
                      fontSize: 11,
                      color: token.isEmpty || !tokenRe.hasMatch(token) ? warnC : muted),
                ),
              ]),
            ),
            const Icon(Icons.edit_outlined, size: 18, color: muted),
          ]),
        ),
        const SizedBox(height: 14),
        Text(tr('ملفات الأوامر', 'COMMAND FILES'),
            style: const TextStyle(fontSize: 10, color: muted, letterSpacing: 1)),
        const SizedBox(height: 8),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(tr('لا توجد أوامر. اضغط "ملف أمر جديد".', 'No commands. Tap "New command file".'),
                textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 13)),
          ),
        ...files.map((f) {
          final name = stripPy(baseName(f.path));
          final ok = parseReply(f.readAsStringSync()) != null;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _card(
              onTap: () => _openFile(f.path),
              child: Row(children: [
                Icon(ok ? Icons.bolt : Icons.warning_amber_rounded, size: 20, color: ok ? accent : warnC),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    if (!ok)
                      Text(tr('ما فيه reply = "..."', 'No reply = "..." line'),
                          style: const TextStyle(fontSize: 11, color: warnC)),
                  ]),
                ),
                IconButton(
                  tooltip: tr('حذف', 'Delete'),
                  onPressed: () => _deleteCommand(f),
                  icon: const Icon(Icons.delete_outline, size: 20, color: danger),
                ),
              ]),
            ),
          );
        }),
      ]),
    ),
    Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _newCommand,
            icon: const Icon(Icons.add),
            label: Text(tr('ملف أمر جديد', 'New command file')),
            style: FilledButton.styleFrom(
                backgroundColor: accent, foregroundColor: bg, padding: const EdgeInsets.symmetric(vertical: 13)),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: tr('استيراد ملف .py', 'Import .py file'),
          onPressed: _import,
          icon: const Icon(Icons.file_open),
        ),
      ]),
    ),
  ]);

  Color _lvColor(Lv l) => switch (l) {
        Lv.ok => accent,
        Lv.warn => warnC,
        Lv.err => danger,
        Lv.info => const Color(0xFFB7C7D9),
      };

  Widget _terminalPane() => Container(
    color: const Color(0xFF070B14),
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    child: ListenableBuilder(
      listenable: runner,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(tr('الطرفية', 'TERMINAL'),
              style: const TextStyle(color: accent, fontSize: 11, letterSpacing: 1)),
          const SizedBox(width: 10),
          Icon(Icons.circle, size: 9, color: runner.running ? accent : muted),
          const SizedBox(width: 5),
          Text(
            runner.running
                ? (runner.username != null ? '@${runner.username}' : tr('جارٍ الاتصال', 'Connecting'))
                : tr('متوقف', 'Stopped'),
            style: const TextStyle(color: muted, fontSize: 10),
          ),
          const Spacer(),
          IconButton(
            tooltip: tr('مسح', 'Clear'),
            visualDensity: VisualDensity.compact,
            onPressed: runner.clearLogs,
            icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: muted),
          ),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: runner.logs.isEmpty
              ? Text(tr('اضغط "تشغيل" لبدء البوت.', 'Press "Run" to start the bot.'),
                  style: const TextStyle(color: muted, fontSize: 12))
              : ListView.builder(
                  itemCount: runner.logs.length,
                  itemBuilder: (context, i) {
                    final l = runner.logs[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Text('[${l.time}] ${l.text}',
                          style: TextStyle(fontSize: 11.5, height: 1.4, color: _lvColor(l.lv))),
                    );
                  },
                ),
        ),
        Text(
          tr('أبقِ التطبيق مفتوحاً أثناء التشغيل. لا تشغّل نفس التوكن في مكانين.',
              'Keep the app open while running. Do not run the same token in two places.'),
          style: const TextStyle(color: muted, fontSize: 10),
        ),
      ]),
    ),
  );
}

// ======================= محرر الملف =======================

class FileEditor extends StatefulWidget {
  const FileEditor({super.key, required this.path, this.isToken = false});
  final String path;
  final bool isToken;
  @override
  State<FileEditor> createState() => _FileEditorState();
}

class _FileEditorState extends State<FileEditor> {
  late final TextEditingController c = TextEditingController(
      text: File(widget.path).existsSync() ? File(widget.path).readAsStringSync() : '');

  Future<void> _save({bool silent = false}) async {
    final text = widget.isToken ? c.text.trim() : c.text;
    await File(widget.path).writeAsString(text);
    if (!silent && mounted) notify(context, tr('تم الحفظ', 'Saved'));
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isToken ? 'token.txt' : stripPy(baseName(widget.path));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _save(silent: true);
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              color: panel,
              child: Row(children: [
                IconButton(
                  onPressed: () async {
                    await _save(silent: true);
                    if (mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(title, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                    tooltip: tr('حفظ', 'Save'), onPressed: _save, icon: const Icon(Icons.save_outlined)),
              ]),
            ),
            if (widget.isToken)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: panel2,
                child: Text(
                  tr('الصق توكن البوت فقط (من @BotFather). لا تشاركه مع أحد.',
                      'Paste only the bot token (from @BotFather). Never share it.'),
                  style: const TextStyle(fontSize: 12, color: warnC),
                ),
              ),
            Expanded(
              child: TextField(
                controller: c,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 14, height: 1.6, color: Color(0xFFDCE7F7)),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.all(14),
                  border: InputBorder.none,
                  hintText: widget.isToken ? '123456789:ABC...' : '',
                  hintStyle: const TextStyle(color: Color(0xFF65738A)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}