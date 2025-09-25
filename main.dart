import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

class ChatMessage {
  final String role;
  String content;
  ChatMessage({required this.role, required this.content});
}

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  ChatNotifier(): super([]);
  void addUserMessage(String text) {
    state = [...state, ChatMessage(role: 'user', content: text)];
  }
  void addAssistantMessage(String text) {
    state = [...state, ChatMessage(role: 'assistant', content: text)];
  }
  void appendToLatestAssistant(String text) {
    final copy = [...state];
    for (var i = copy.length - 1; i >= 0; i--) {
      if (copy[i].role == 'assistant') {
        copy[i].content += text;
        state = copy;
        return;
      }
    }
    copy.add(ChatMessage(role: 'assistant', content: text));
    state = copy;
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, List<ChatMessage>>((ref) {
  return ChatNotifier();
});

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio();
  return dio;
});

void main() {
  runApp(const ProviderScope(child: ChatApp()));
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Q&A Streaming',
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _ctrl = TextEditingController();
  bool _isStreaming = false;

  Future<void> _sendQuestion(String text) async {
    if (text.trim().isEmpty) return;
    final chatNotifier = ref.read(chatProvider.notifier);
    chatNotifier.addUserMessage(text);
    _ctrl.clear();
    final allMessages = ref.read(chatProvider).map((m) => {'role': m.role, 'content': m.content}).toList();
    final dio = ref.read(dioProvider);
    setState(() { _isStreaming = true; });
    try {
      final response = await dio.post<ResponseBody>(
        'http://localhost:8000/chat',
        data: jsonEncode(allMessages),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          responseType: ResponseType.stream,
        ),
      );
      chatNotifier.addAssistantMessage('');
      final stream = response.data!.stream;
      final utf8Stream = stream.transform(utf8.decoder);
      final lineStream = utf8Stream.transform(const LineSplitter());
      String buffer = '';
      await for (final line in lineStream) {
        if (line.trim().isEmpty) {
          final dataLines = buffer.split('\n').where((l) => l.startsWith('data:')).map((l) => l.substring(5).trim()).toList();
          if (dataLines.isNotEmpty) {
            final dataRaw = dataLines.join('\n');
            try {
              final parsed = jsonDecode(dataRaw);
              final t = parsed['type'];
              if (t == 'delta' && parsed['text'] != null) {
                chatNotifier.appendToLatestAssistant(parsed['text']);
              }
            } catch (e) {
              chatNotifier.appendToLatestAssistant(dataRaw);
            }
          }
          buffer = '';
        } else {
          buffer += (buffer.isEmpty ? '' : '\n') + line;
        }
      }
    } catch (e) {
      ref.read(chatProvider.notifier).addAssistantMessage("\n[Error] ${e.toString()}");
    } finally {
      setState(() { _isStreaming = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('AI Q&A (Streaming)')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: messages.length,
              itemBuilder: (context, i) {
                final m = messages[i];
                final isUser = m.role == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.blue[100] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(m.content.isEmpty ? (isUser ? '' : '...') : m.content),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(hintText: 'Ask something...'),
                      onSubmitted: (v) {
                        if (!_isStreaming) _sendQuestion(v);
                      },
                    ),
                  ),
                ),
                IconButton(
                  icon: _isStreaming ? const CircularProgressIndicator() : const Icon(Icons.send),
                  onPressed: _isStreaming ? null : () => _sendQuestion(_ctrl.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
