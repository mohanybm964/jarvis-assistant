import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

void main() => runApp(const JarvisApp());

enum ProviderType { openai, gemini, openrouter, anthropic, ollama }

extension ProviderTypeX on ProviderType {
  String get label => switch (this) {
    ProviderType.openai => 'OpenAI',
    ProviderType.gemini => 'Gemini',
    ProviderType.openrouter => 'OpenRouter',
    ProviderType.anthropic => 'Anthropic',
    ProviderType.ollama => 'Ollama (Local)',
  };
}

class ChatMessage {
  ChatMessage({required this.role, required this.content});
  final String role;
  final String content;
  Map<String, dynamic> toJson() => {'role': role, 'content': content};
  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage(role: j['role'], content: j['content']);
}

class Conversation {
  Conversation({required this.id, required this.title, required this.messages});
  final String id;
  String title;
  final List<ChatMessage> messages;
  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'messages': messages.map((e) => e.toJson()).toList()};
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'],
        title: j['title'],
        messages: (j['messages'] as List)
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class LocalStore {
  static const _prefsKey = 'jarvis_history_web';
  Future<List<Conversation>> load() async {
    String? raw;
    if (kIsWeb) {
      raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/jarvis_history.json');
      if (await f.exists()) raw = await f.readAsString();
    }
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> save(List<Conversation> conversations) async {
    final raw = jsonEncode(conversations.map((e) => e.toJson()).toList());
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).setString(_prefsKey, raw);
    } else {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/jarvis_history.json').writeAsString(raw);
    }
  }
}

class ApiKeys {
  static const _storage = FlutterSecureStorage();
  static String key(ProviderType p) => 'api_key_${p.name}';
  static Future<String?> read(ProviderType p) => _storage.read(key: key(p));
  static Future<void> write(ProviderType p, String value) =>
      _storage.write(key: key(p), value: value);
}

class AiService {
  Future<String> send({
    required ProviderType provider,
    required String model,
    required List<ChatMessage> messages,
    String? apiKey,
    String ollamaBaseUrl = 'http://localhost:11434',
  }) async {
    return switch (provider) {
      ProviderType.openai => _openAI(model, messages, apiKey!),
      ProviderType.gemini => _gemini(model, messages, apiKey!),
      ProviderType.openrouter => _openRouter(model, messages, apiKey!),
      ProviderType.anthropic => _anthropic(model, messages, apiKey!),
      ProviderType.ollama => _ollama(model, messages, ollamaBaseUrl),
    };
  }

  Future<String> _openAI(String model, List<ChatMessage> m, String key) async {
    final r = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
      body: jsonEncode({'model': model, 'messages': m.map((e) => e.toJson()).toList()}),
    );
    _check(r);
    return jsonDecode(r.body)['choices'][0]['message']['content'];
  }

  Future<String> _gemini(String model, List<ChatMessage> m, String key) async {
    final contents = m.map((e) => {
      'role': e.role == 'assistant' ? 'model' : 'user',
      'parts': [{'text': e.content}]
    }).toList();
    final r = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'contents': contents}),
    );
    _check(r);
    return jsonDecode(r.body)['candidates'][0]['content']['parts'][0]['text'];
  }

  Future<String> _openRouter(
    String model,
    List<ChatMessage> m,
    String key,
  ) async {
    final r = await http.post(
      Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
        'X-OpenRouter-Title': 'JARVIS Assistant',
      },
      body: jsonEncode({
        'model': model,
        'messages': m.map((e) => e.toJson()).toList(),
      }),
    );

    _check(r);

    final body = jsonDecode(r.body);
    final content = body['choices']?[0]?['message']?['content'];

    if (content is String && content.isNotEmpty) {
      return content;
    }

    throw Exception('OpenRouter returned an empty response.');
  }

  Future<String> _anthropic(String model, List<ChatMessage> m, String key) async {
    final r = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json'
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'messages': m.map((e) => e.toJson()).toList()
      }),
    );
    _check(r);
    return jsonDecode(r.body)['content'][0]['text'];
  }

  Future<String> _ollama(String model, List<ChatMessage> m, String base) async {
    final r = await http.post(
      Uri.parse('$base/api/chat'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'stream': false,
        'messages': m.map((e) => e.toJson()).toList()
      }),
    );
    _check(r);
    return jsonDecode(r.body)['message']['content'];
  }

  void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;

    String message = 'Request failed';

    try {
      final body = jsonDecode(r.body);
      final error = body['error'];
      if (error is Map && error['message'] is String) {
        message = error['message'];
      }
    } catch (_) {}

    if (r.statusCode == 401 || r.statusCode == 403) {
      message = 'API key rejected. Check the key in Settings.';
    } else if (r.statusCode == 429) {
      message = 'Gemini quota exceeded. Wait for quota reset or use another provider.';
    }

    throw Exception(message);
  }

  Future<List<String>> cloudModels(
    ProviderType provider,
    String apiKey,
  ) async {
    late http.Response r;

    switch (provider) {
      case ProviderType.openai:
        r = await http.get(
          Uri.parse('https://api.openai.com/v1/models'),
          headers: {'Authorization': 'Bearer $apiKey'},
        );
        _check(r);
        final data = jsonDecode(r.body)['data'] as List? ?? [];
        final result = data
            .map((e) => e['id']?.toString() ?? '')
            .where((id) =>
                id.isNotEmpty &&
                (id.startsWith('gpt-') ||
                    id.startsWith('o1') ||
                    id.startsWith('o3') ||
                    id.startsWith('o4')))
            .toSet()
            .toList();
        result.sort();
        return result;

      case ProviderType.openrouter:
        r = await http.get(
          Uri.parse(
            'https://openrouter.ai/api/v1/models?output_modalities=text',
          ),
          headers: {
            'Authorization': 'Bearer $apiKey',
          },
        );

        _check(r);

        final data = jsonDecode(r.body)['data'] as List? ?? [];

        final result = data
            .map((e) => e['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();

        result.sort();

        return result;

      case ProviderType.gemini:
        r = await http.get(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
          ),
        );
        _check(r);
        final data = jsonDecode(r.body)['models'] as List? ?? [];
        final result = <String>[];

        for (final item in data) {
          final methods =
              (item['supportedGenerationMethods'] as List? ?? [])
                  .map((e) => e.toString())
                  .toList();

          final name = item['name']?.toString() ?? '';

          if (methods.contains('generateContent') &&
              name.startsWith('models/')) {
            result.add(name.substring('models/'.length));
          }
        }

        result.sort();
        return result.toSet().toList();

      case ProviderType.anthropic:
        r = await http.get(
          Uri.parse('https://api.anthropic.com/v1/models?limit=100'),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
        );
        _check(r);
        final data = jsonDecode(r.body)['data'] as List? ?? [];
        final result = data
            .map((e) => e['id']?.toString() ?? '')
            .where((id) => id.startsWith('claude-'))
            .toSet()
            .toList();
        result.sort();
        return result;

      case ProviderType.ollama:
        return [];
    }
  }

  Future<List<String>> ollamaModels(String base) async {
    final r = await http.get(Uri.parse('$base/api/tags'));
    _check(r);
    return (jsonDecode(r.body)['models'] as List)
        .map<String>((e) => e['name'] as String)
        .toList();
  }

  Stream<Map<String, dynamic>> pullOllama(
    String base,
    String model,
  ) async* {
    final request = http.Request(
      'POST',
      Uri.parse('$base/api/pull'),
    );

    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'name': model,
      'stream': true,
    });

    final response = await request.send();

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw Exception(
        'Ollama HTTP ${response.statusCode}: $body',
      );
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;

      final data = jsonDecode(line);

      if (data is Map<String, dynamic>) {
        yield data;
      }
    }
  }
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JARVIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D9FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF050A0F),
        useMaterial3: true,
      ),
      home: const JarvisHome(),
    );
  }
}

class JarvisHome extends StatefulWidget {
  const JarvisHome({super.key});
  @override
  State<JarvisHome> createState() => _JarvisHomeState();
}

class _JarvisHomeState extends State<JarvisHome> {
  final store = LocalStore();
  final ai = AiService();
  final tts = FlutterTts();
  final input = TextEditingController();
  final uuid = const Uuid();

  List<Conversation> chats = [];
  Conversation? active;
  ProviderType provider = ProviderType.openai;
  String model = 'gpt-4o-mini';
  bool ttsEnabled = false;
  bool busy = false;
  String ollamaBase = 'http://localhost:11434';

  static const models = {
    ProviderType.openai: ['gpt-4o-mini', 'gpt-4o'],
    ProviderType.gemini: ['gemini-2.5-flash'],
    ProviderType.openrouter: ['openrouter/auto', 'openrouter/free'],
    ProviderType.anthropic: ['claude-3-5-sonnet-latest', 'claude-3-5-haiku-latest'],
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    chats = await store.load();
    if (chats.isNotEmpty) active = chats.first;
    if (mounted) setState(() {});
  }

  Future<void> _newChat() async {
    final c = Conversation(id: uuid.v4(), title: 'New conversation', messages: []);
    setState(() {
      chats.insert(0, c);
      active = c;
    });
    await store.save(chats);
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || busy) return;
    if (active == null) await _newChat();
    input.clear();
    setState(() {
      busy = true;
      active!.messages.add(ChatMessage(role: 'user', content: text));
      if (active!.messages.length == 1) {
        active!.title = text.length > 32 ? '${text.substring(0, 32)}…' : text;
      }
    });
    await store.save(chats);
    try {
      final key = provider == ProviderType.ollama ? null : await ApiKeys.read(provider);
      if (provider != ProviderType.ollama && (key == null || key.isEmpty)) {
        throw Exception('Add an API key in Settings.');
      }
      final reply = await ai.send(
        provider: provider,
        model: model,
        messages: active!.messages,
        apiKey: key,
        ollamaBaseUrl: ollamaBase,
      );
      setState(() => active!.messages.add(ChatMessage(role: 'assistant', content: reply)));
      await store.save(chats);
      if (ttsEnabled) await tts.speak(reply);
    } catch (e) {
      if (active != null &&
          active!.messages.isNotEmpty &&
          active!.messages.last.role == 'user' &&
          active!.messages.last.content == text) {
        active!.messages.removeLast();
        await store.save(chats);
      }

      if (mounted) {
        setState(() {});

        final message =
            e.toString().replaceFirst('Exception: ', '');

        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _setProvider(ProviderType p) {
    setState(() {
      provider = p;
      model = p == ProviderType.ollama ? 'llama3.2' : models[p]!.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;
    return Scaffold(
      appBar: AppBar(
        title: const Text('JARVIS // PERSONAL INTELLIGENCE'),
        actions: [
          IconButton(
            tooltip: ttsEnabled ? 'Disable voice' : 'Enable voice',
            onPressed: () => setState(() => ttsEnabled = !ttsEnabled),
            icon: Icon(ttsEnabled ? Icons.volume_up : Icons.volume_off),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsPage(
                  provider: provider,
                  model: model,
                  ollamaBase: ollamaBase,
                  onChanged: (p, m, base) => setState(() {
                    provider = p;
                    model = m;
                    ollamaBase = base;
                  }),
                ),
              ),
            ),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'About',
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'JARVIS Assistant',
              applicationVersion: '1.0.0',
              children: const [
                Text('Developer: Mohan'),
                SelectableText('Email: mohanybm829@gmail.com'),
                SizedBox(height: 12),
                Text('Local-first chat history. No cloud synchronization.'),
              ],
            ),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      drawer: wide ? null : Drawer(child: _sidebar()),
      body: Row(
        children: [
          if (wide) SizedBox(width: 280, child: _sidebar()),
          Expanded(child: _chat()),
        ],
      ),
    );
  }

  Widget _sidebar() => Container(
        decoration: const BoxDecoration(
          border: Border(right: BorderSide(color: Color(0x3329D9FF))),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: _newChat,
                icon: const Icon(Icons.add),
                label: const Text('NEW SESSION'),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: chats.length,
                itemBuilder: (_, i) => ListTile(
                  selected: active?.id == chats[i].id,
                  title: Text(chats[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => setState(() => active = chats[i]),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(provider.label),
              subtitle: Text(model),
            ),
          ],
        ),
      );

  Widget _chat() => Column(
        children: [
          Expanded(
            child: active == null || active!.messages.isEmpty
                ? const Center(child: JarvisCore())
                : ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: active!.messages.length,
                    itemBuilder: (_, i) {
                      final m = active!.messages[i];
                      final user = m.role == 'user';
                      return Align(
                        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 760),
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: user ? const Color(0xFF103040) : const Color(0xFF0A151D),
                            border: Border.all(color: const Color(0x5533DFFF)),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: SelectableText(m.content),
                        ),
                      );
                    },
                  ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Enter command...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(onPressed: _send, icon: const Icon(Icons.arrow_upward)),
                ],
              ),
            ),
          ),
        ],
      );
}

class JarvisCore extends StatelessWidget {
  const JarvisCore({super.key});
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF00D9FF), width: 2),
              boxShadow: const [BoxShadow(color: Color(0x5500D9FF), blurRadius: 35)],
            ),
            child: const Icon(Icons.blur_circular, size: 100, color: Color(0xFF00D9FF)),
          ),
          const SizedBox(height: 24),
          const Text('SYSTEM ONLINE', style: TextStyle(letterSpacing: 5)),
          const SizedBox(height: 8),
          const Text('Cloud APIs or private local inference'),
        ],
      );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.provider,
    required this.model,
    required this.ollamaBase,
    required this.onChanged,
  });
  final ProviderType provider;
  final String model;
  final String ollamaBase;
  final void Function(ProviderType, String, String) onChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProviderType provider;
  late String model;
  late TextEditingController key;
  late TextEditingController base;
  final pull = TextEditingController();
  final ai = AiService();
  List<String> localModels = [];
  List<String> cloudModelList = [];
  bool loading = false;
  bool loadingModels = false;
  String ollamaStatus = 'Not connected';
  double? pullProgress;

  @override
  void initState() {
    super.initState();
    provider = widget.provider;
    model = widget.model;
    key = TextEditingController();
    base = TextEditingController(text: widget.ollamaBase);
    _loadKey();
    _refreshOllama();
  }

  Future<void> _loadKey() async {
    key.text = await ApiKeys.read(provider) ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _refreshOllama() async {
    try {
      localModels = await ai.ollamaModels(base.text.trim());
      if (provider == ProviderType.ollama && localModels.isNotEmpty && !localModels.contains(model)) {
        model = localModels.first;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _pull() async {
    final requestedModel = pull.text.trim();

    if (requestedModel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter an Ollama model name first.'),
        ),
      );
      return;
    }

    setState(() {
      loading = true;
      pullProgress = null;
      ollamaStatus = 'Connecting to Ollama...';
    });

    try {
      await for (final event in ai.pullOllama(
        base.text.trim(),
        requestedModel,
      )) {
        final status =
            event['status']?.toString() ?? 'Downloading...';

        final completed = event['completed'];
        final total = event['total'];

        double? progress;

        if (completed is num &&
            total is num &&
            total > 0) {
          progress = completed / total;
        }

        if (!mounted) return;

        setState(() {
          ollamaStatus = status;
          pullProgress = progress;
        });
      }

      await _refreshOllama();

      if (!mounted) return;

      setState(() {
        model = requestedModel;
        ollamaStatus = 'Model ready: $requestedModel';
        pullProgress = 1.0;
      });

      pull.clear();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$requestedModel downloaded successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      final raw =
          e.toString().replaceFirst('Exception: ', '');

      final message =
          raw.contains('Connection refused')
              ? 'Cannot connect to Ollama at ${base.text.trim()}. Start an Ollama server first or enter the server LAN address.'
              : raw;

      setState(() {
        ollamaStatus = message;
        pullProgress = null;
      });

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  List<String> get available {
    if (provider == ProviderType.ollama) {
      return localModels.isEmpty ? [model] : localModels;
    }

    if (cloudModelList.isNotEmpty) {
      return cloudModelList;
    }

    return _JarvisHomeState.models[provider]!;
  }

  Future<void> _fetchCloudModels() async {
    if (provider == ProviderType.ollama) return;

    final apiKey = key.text.trim();

    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter an API key first.')),
        );
      }
      return;
    }

    setState(() => loadingModels = true);

    try {
      final fetched = await ai.cloudModels(provider, apiKey);

      if (fetched.isEmpty) {
        throw Exception('No compatible chat models were returned.');
      }

      if (!mounted) return;

      setState(() {
        cloudModelList = fetched;
        if (!cloudModelList.contains(model)) {
          model = cloudModelList.first;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${cloudModelList.length} models loaded.'),
        ),
      );
    } catch (e) {
      if (mounted) {
        final message =
            e.toString().replaceFirst('Exception: ', '');

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => loadingModels = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SYSTEM CONFIGURATION')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<ProviderType>(
              value: provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: ProviderType.values
                  .map((p) => DropdownMenuItem(value: p, child: Text(p.label)))
                  .toList(),
              onChanged: (p) async {
                if (p == null) return;
                provider = p;
                cloudModelList = [];
                await _loadKey();

                if (provider == ProviderType.ollama) {
                  await _refreshOllama();
                } else if (key.text.trim().isNotEmpty) {
                  await _fetchCloudModels();
                }

                if (available.isNotEmpty &&
                    !available.contains(model)) {
                  model = available.first;
                }

                setState(() {});
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: available.contains(model) ? model : available.first,
              decoration: const InputDecoration(labelText: 'Model'),
              items: available.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (m) => setState(() => model = m!),
            ),
            const SizedBox(height: 16),
            if (provider != ProviderType.ollama) ...[
              TextField(
                controller: key,
                obscureText: true,
                decoration: InputDecoration(labelText: '${provider.label} API key'),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: loadingModels
                    ? null
                    : () async {
                        await ApiKeys.write(
                          provider,
                          key.text.trim(),
                        );

                        await _fetchCloudModels();
                      },
                child: Text(
                  loadingModels
                      ? 'FETCHING MODELS...'
                      : 'SAVE API KEY & FETCH MODELS',
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed:
                    loadingModels ? null : _fetchCloudModels,
                child: const Text('REFRESH MODELS'),
              ),
            ] else ...[
              TextField(
                controller: base,
                decoration: const InputDecoration(labelText: 'Ollama base URL'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(onPressed: _refreshOllama, child: const Text('REFRESH LOCAL MODELS')),
              const SizedBox(height: 16),
              TextField(
                controller: pull,
                decoration: const InputDecoration(
                  labelText: 'Pull model from Ollama library',
                  hintText: 'Example: llama3.2',
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: loading ? null : _pull,
                child: Text(
                  loading ? 'PULLING MODEL...' : 'PULL MODEL',
                ),
              ),
              const SizedBox(height: 16),
              if (loading || ollamaStatus != 'Not connected') ...[
                Text(
                  ollamaStatus,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                if (loading)
                  LinearProgressIndicator(
                    value: pullProgress,
                  ),
                if (pullProgress != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${(pullProgress! * 100).toStringAsFixed(1)}%',
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                widget.onChanged(provider, model, base.text.trim());
                Navigator.pop(context);
              },
              child: const Text('APPLY CONFIGURATION'),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Local-only history'),
              subtitle: Text('Conversation history stays on this device. No cloud synchronization is implemented.'),
            ),
          ],
        ),
      );
}
