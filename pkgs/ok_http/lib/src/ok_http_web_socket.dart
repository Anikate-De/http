// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:jni/jni.dart';
import 'package:web_socket/web_socket.dart';

import 'jni/bindings.dart' as bindings;
import 'ok_http_client.dart';

/// A [WebSocket] implemented using the OkHttp library's
/// [WebSocket](https://square.github.io/okhttp/5.x/okhttp/okhttp3/-web-socket/index.html)
/// API.
class OkHttpWebSocket implements WebSocket {
  late bindings.OkHttpClient _client;
  late final bindings.WebSocket _webSocket;
  final _events = StreamController<WebSocketEvent>();
  String? _protocol;

  OkHttpWebSocket._() {
    // Add the WSInterceptor to prevent response parsing errors.
    _client = bindings.WSInterceptor.Companion
        .addWSInterceptor(bindings.OkHttpClient_Builder())
        .build();
  }

  /// Create a new WebSocket connection using `OkHttp`'s
  /// [WebSocket](https://square.github.io/okhttp/5.x/okhttp/okhttp3/-web-socket/index.html)
  /// API.
  ///
  /// The URL supplied in [url] must use the scheme ws or wss.
  ///
  /// If provided, the [protocols] argument indicates that subprotocols that
  /// the peer is able to select. See
  /// [RFC-6455 1.9](https://datatracker.ietf.org/doc/html/rfc6455#section-1.9).
  static Future<WebSocket> connect(Uri url,
          {Iterable<dynamic>? protocols}) async =>
      OkHttpWebSocket._()._connect(url, protocols);

  Future<WebSocket> _connect(Uri url, Iterable<dynamic>? protocols) async {
    if (!url.isScheme('ws') && !url.isScheme('wss')) {
      throw ArgumentError.value(
          url, 'url', 'only ws: and wss: schemes are supported');
    }

    final requestBuilder =
        bindings.Request_Builder().url1(url.toString().toJString());

    if (protocols != null) {
      requestBuilder.addHeader('Sec-WebSocket-Protocol'.toJString(),
          protocols.join(', ').toJString());
    }

    var openCompleter = Completer<WebSocket>();

    _client.newWebSocket(
        requestBuilder.build(),
        bindings.WebSocketListenerProxy(
            bindings.WebSocketListenerProxy_WebSocketListener.implement(
                bindings.$WebSocketListenerProxy_WebSocketListenerImpl(
          onOpen: (webSocket, response) {
            _webSocket = webSocket;

            var protocolHeader =
                response.header1('sec-websocket-protocol'.toJString());
            if (!protocolHeader.isNull) {
              _protocol = protocolHeader.toDartString();
              if (!(protocols?.contains(_protocol) ?? true)) {
                openCompleter
                    .completeError(WebSocketException('Protocol mismatch. '
                        'Expected one of $protocols, but received $_protocol'));
                return;
              }
            }

            openCompleter.complete(this);
          },
          onMessage: (bindings.WebSocket webSocket, JString string) {
            if (_events.isClosed) return;
            _events.add(TextDataReceived(string.toDartString()));
          },
          onMessage1:
              (bindings.WebSocket webSocket, bindings.ByteString byteString) {
            if (_events.isClosed) return;
            _events.add(
                BinaryDataReceived(byteString.toByteArray().toUint8List()));
          },
          onClosing:
              (bindings.WebSocket webSocket, int i, JString string) async {
            _okHttpClientClose();

            if (_events.isClosed) return;

            _events.add(CloseReceived(i, string.toDartString()));
            await _events.close();
          },
          onFailure: (bindings.WebSocket webSocket, JObject throwable,
              bindings.Response response) {
            if (_events.isClosed) return;

            var throwableString = throwable.toString();

            // If the throwable is:
            // - java.net.ProtocolException: Control frames must be final.
            // - java.io.EOFException
            // - java.net.SocketException: Socket closed
            // Then the connection was closed abnormally.
            if (throwableString.contains(RegExp(
                r'(java\.net\.ProtocolException: Control frames must be final\.|java\.io\.EOFException|java\.net\.SocketException: Socket closed)'))) {
              _events.add(CloseReceived(1006, 'closed abnormal'));
              unawaited(_events.close());
              return;
            }
            var error = WebSocketException(
                'Connection ended unexpectedly $throwableString');
            if (openCompleter.isCompleted) {
              _events.addError(error);
              return;
            }
            openCompleter.completeError(error);
          },
        ))));

    return openCompleter.future;
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }

    if (code != null && code != 1000 && !(code >= 3000 && code <= 4999)) {
      throw ArgumentError('Invalid argument: $code, close code must be 1000 or '
          'in the range 3000-4999');
    }
    if (reason != null && utf8.encode(reason).length > 123) {
      throw ArgumentError.value(reason, 'reason',
          'reason must be <= 123 bytes long when encoded as UTF-8');
    }

    unawaited(_events.close());

    // When no code is provided, cause an abnormal closure to send 1005.
    if (code == null) {
      _webSocket.cancel();
      return;
    }

    _webSocket.close(
        code, reason?.toJString() ?? JString.fromReference(jNullReference));
  }

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => _protocol ?? '';

  @override
  void sendBytes(Uint8List b) {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }
    _webSocket.send1(bindings.ByteString.of(b.toJArray()));
  }

  @override
  void sendText(String s) {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }
    _webSocket.send(s.toJString());
  }

  /// Closes the OkHttpClient using the recommended shutdown procedure.
  void _okHttpClientClose() {
    _client.dispatcher().executorService().shutdown();
    _client.connectionPool().evictAll();
    var cache = _client.cache();
    if (!cache.isNull) {
      cache.close();
    }
    _client.release();
  }
}