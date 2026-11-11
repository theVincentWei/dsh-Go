/// AI gateway: OpenAI-compatible /v1/chat/completions and /v1/models, with a
/// DSH session pool as the upstream — mini programs inherit the engine's
/// provider, tools and memory, no keys of their own (拍板 §4.1③ v0.2).
///
/// MVP shape: one resident DSH session, requests serialised through a queue
/// (design default: per-app concurrency 1 overall for M2). Streaming maps
/// TextDeltaChunk → OpenAI `data:` chunks; non-streaming waits for turn end.
/// Requires `engine.launchUrl` in the config; without it every endpoint
/// answers 503 so the rest of AppHub keeps working.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'config.dart';
import 'db.dart';

class AiGateway {
  AiGateway(this.cfg, this.db, String launchUrlFile)
      : launchUrl = _resolveLaunchUrl(cfg.engineLaunchUrl, launchUrlFile);

  static String _resolveLaunchUrl(String staticUrl, String launchUrlFile) {
    if (staticUrl.isNotEmpty) return staticUrl;
    if (launchUrlFile.isEmpty) return '';
    try {
      // The supervisor keeps this file current across engine restarts (the
      // token rotates each boot). It may hold either the raw launch line
      // ("dsh web: http://…?token=…") or the bare URL — accept both.
      final Iterable<String> lines =
          File(launchUrlFile).readAsLinesSync().reversed;
      for (final String line in lines) {
        final String trimmed = line.trim();
        if (trimmed.startsWith('http')) return trimmed;
        if (trimmed.contains('dsh web:')) {
          return trimmed.substring(trimmed.indexOf('dsh web:') + 'dsh web:'.length).trim();
        }
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  final AppConfig cfg;
  final Db db;

  /// The engine's launch URL with ?token=… — empty until the operator fills
  /// it in (the token is per-process and rotates; minted by `dsh web`).
  final String launchUrl;

  DshClient? _client;
  String? _sessionId;
  Future<void>? _queue; // serialises turns on the resident session.
  int _cursor = 1 << 62;

  bool get configured => launchUrl.isNotEmpty;

  shelf.Response _json(Object? body, [int status = 200]) => shelf.Response(status,
      body: jsonEncode(body),
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'});

  shelf_router.Router get router {
    final router = shelf_router.Router()
      ..post('/v1/chat/completions', _completions)
      ..get('/v1/models', _models);
    return router;
  }

  bool _authorized(shelf.Request request) {
    final String token = cfg.deviceToken;
    if (token.isEmpty) return true; // LAN trust (M1 stance)
    return (request.headers['authorization'] ?? '') == 'Bearer $token';
  }

  shelf.Response _err(int status, String message) => shelf.Response(status,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{'message': message, 'type': 'apphub_error'},
      }),
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'});

  Future<DshClient> _clientReady() async {
    if (_client != null) return _client!;
    _client = await DshClient.connect(launchUrl: launchUrl);
    _sessionId = (await _client!.createSession(cwd: cfg.engineAppsDir)).sessionId;
    return _client!;
  }

  /// One DSH turn; [onDelta] receives streamed text deltas when non-null.
  Future<String> _turn(String prompt, {void Function(String delta)? onDelta}) async {
    // Serialise: one resident session, one turn at a time (design default).
    final Future<void> previous = _queue ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _queue = gate.future;
    await previous;

    final DshClient client = await _clientReady();
    final String sessionId = _sessionId!;
    final Completer<String> done = Completer<String>();
    final StringBuffer text = StringBuffer();
    _cursor = 1 << 62;
    bool promptSent = false;

    StreamSubscription<DshEvent>? sub;
    Timer? watchdog;
    final Completer<SessionSnapshotEvent> snapshotSeen =
        Completer<SessionSnapshotEvent>();
    try {
      sub = client.watch(sessionId).listen((DshEvent event) {
        switch (event) {
          case SessionSnapshotEvent():
            if (!snapshotSeen.isCompleted) snapshotSeen.complete(event);
          case AssistantChunkEvent(:final chunk):
            if (chunk is TextDeltaChunk) {
              text.write(chunk.text);
              onDelta?.call(chunk.text);
            }
          case AssistantMessageEvent(:final message):
            // A committed assistant message also carries the full text —
            // covers transports that batch deltas.
            if (message.text.isNotEmpty && !done.isCompleted && text.isEmpty) {
              text.write(message.text);
            }
          case TurnEndedEvent(:final seq):
            if (promptSent && seq > _cursor && !done.isCompleted) {
              done.complete(text.toString());
            }
          case SessionErrorEvent(:final message):
            if (!done.isCompleted) done.completeError(StateError(message));
          default:
            break;
        }
      }, onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      });

      final SessionSnapshotEvent snapshot =
          await snapshotSeen.future.timeout(const Duration(seconds: 15));
      _cursor = snapshot.cursor;
      promptSent = true;
      await client.prompt(sessionId, prompt);
      watchdog = Timer(const Duration(seconds: 120), () {
        if (!done.isCompleted) {
          unawaited(client.cancel(sessionId));
          done.completeError(TimeoutException('dsh turn exceeded 120s'));
        }
      });
      return await done.future;
    } finally {
      watchdog?.cancel();
      await sub?.cancel();
      gate.complete();
    }
  }

  String _composePrompt(List<dynamic> messages) {
    final StringBuffer buffer = StringBuffer();
    for (final dynamic message in messages) {
      if (message is! Map<String, Object?>) continue;
      final String role = message['role'] as String? ?? 'user';
      final Object? content = message['content'];
      final String text = content is String
          ? content
          : jsonEncode(content); // tool-style parts pass through as JSON
      if (role == 'system') {
        buffer
          ..writeln('[系统说明]')
          ..writeln(text)
          ..writeln();
      } else if (role == 'user') {
        buffer.writeln('用户:$text');
      } else if (role == 'assistant') {
        buffer.writeln('助手:$text');
      }
    }
    buffer
      ..writeln()
      ..writeln('请直接回答上面最后一句话。不要复述本提示的结构。');
    return buffer.toString();
  }

  Future<shelf.Response> _completions(shelf.Request request) async {
    if (!_authorized(request)) return _err(401, 'unauthorized');
    if (!configured) {
      return _err(503, 'engine not configured: set engine.launchUrl in apphub config');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return _err(400, 'body must be JSON');
    }
    if (decoded is! Map<String, Object?>) return _err(400, 'body must be a JSON object');
    final List<dynamic> messages = decoded['messages'] as List<dynamic>? ?? const <dynamic>[];
    if (messages.isEmpty) return _err(400, 'messages required');
    final bool stream = decoded['stream'] == true;
    final String prompt = _composePrompt(messages);

    await db.exec(
        'INSERT INTO ai_usage (app_id, tokens) VALUES (?, ?)',
        [request.headers['x-dsh-app'] ?? 'unknown', prompt.length]);

    if (!stream) {
      try {
        final String text = await _turn(prompt);
        return _json(<String, Object?>{
          'id': 'apphub-${DateTime.now().millisecondsSinceEpoch}',
          'object': 'chat.completion',
          'choices': <Object?>[
            <String, Object?>{
              'index': 0,
              'message': <String, Object?>{'role': 'assistant', 'content': text},
              'finish_reason': 'stop',
            },
          ],
        });
      } on TimeoutException {
        return _err(504, 'engine turn timed out');
      } catch (error) {
        return _err(502, 'engine error: $error');
      }
    }

    // SSE streaming: OpenAI chunk shape over the engine's deltas.
    final StreamController<List<int>> output = StreamController<List<int>>();
    void send(Object? chunkBody) {
      output.add(utf8.encode('data: ${jsonEncode(chunkBody)}\n\n'));
    }

    unawaited(() async {
      try {
        send(<String, Object?>{
          'id': 'apphub-${DateTime.now().millisecondsSinceEpoch}',
          'object': 'chat.completion.chunk',
          'choices': <Object?>[
            <String, Object?>{
              'index': 0,
              'delta': <String, Object?>{'role': 'assistant'},
              'finish_reason': null,
            },
          ],
        });
        final String text = await _turn(prompt, onDelta: (String delta) {
          send(<String, Object?>{
            'id': 'apphub-stream',
            'object': 'chat.completion.chunk',
            'choices': <Object?>[
              <String, Object?>{
                'index': 0,
                'delta': <String, Object?>{'content': delta},
                'finish_reason': null,
              },
            ],
          });
        });
        send(<String, Object?>{
          'id': 'apphub-stream',
          'object': 'chat.completion.chunk',
          'choices': <Object?>[
            <String, Object?>{
              'index': 0,
              'delta': <String, Object?>{},
              'finish_reason': 'stop',
            },
          ],
        });
        await db.audit('ai-gateway', 'completion', '${text.length} chars');
        output.add(utf8.encode('data: [DONE]\n\n'));
        await output.close();
      } catch (error) {
        output.add(utf8.encode('data: ${jsonEncode(<String, Object?>{'error': '$error'})}\n\n'));
        await output.close();
      }
    }());

    return shelf.Response(200,
        body: output.stream,
        headers: <String, String>{
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
        });
  }

  Future<shelf.Response> _models(shelf.Request request) async {
    if (!configured) return _err(503, 'engine not configured');
    try {
      final DshClient client = await _clientReady();
      final catalog = await client.listModels();
      return _json(<String, Object?>{
        'object': 'list',
        'data': <Object?>[
          for (final model in catalog.models)
            <String, Object?>{
              'id': '${model.provider}/${model.id}',
              'object': 'model',
              'owned_by': model.provider,
            },
        ],
      });
    } catch (error) {
      return _err(502, 'engine error: $error');
    }
  }
}
