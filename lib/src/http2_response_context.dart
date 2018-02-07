import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart' hide Header;
import 'package:http2/transport.dart';
import 'http2_request_context.dart';

class Http2ResponseContextImpl extends ResponseContext {
  final Angel app;
  final ServerTransportStream stream;
  final Http2RequestContextImpl _req;
  bool _useStream = false, _isClosed = false;

  Http2ResponseContextImpl(this.app, this.stream, this._req);

  @override
  RequestContext get correspondingRequest => _req;

  @override
  HttpResponse get io => null;

  @override
  bool get streaming => _useStream;

  @override
  bool get isOpen => !_isClosed;

  /// Write headers, status, etc. to the underlying [stream].
  void finalize() {
    var headers = <Header>[
      new Header.ascii(':status', statusCode.toString()),
    ];

    // Add all normal headers
    for (var key in this.headers.keys) {
      headers.add(new Header.ascii(key.toLowerCase(), this.headers[key]));
    }

    // Send all cookies
    for (var cookie in cookies) {
      headers.add(new Header.ascii('set-cookie', cookie.toString()));
    }

    stream.sendHeaders(headers);
  }

  @override
  void addError(Object error, [StackTrace stackTrace]) {
    Zone.current.handleUncaughtError(error, stackTrace);
    super.addError(error, stackTrace);
  }

  @override
  bool useStream() {
    if (!_useStream) {
      // If this is the first stream added to this response,
      // then add headers, status code, etc.
      finalize();

      willCloseItself = _useStream = _isClosed = true;
      releaseCorrespondingRequest();
      return true;
    }

    return false;
  }

  @override
  void end() {
    _isClosed = true;
    super.end();
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    if (_isClosed && !_useStream) throw ResponseContext.closed();
    var firstStream = useStream();

    Stream<List<int>> output = stream;

    if (encoders.isNotEmpty && correspondingRequest != null) {
      var allowedEncodings =
          (correspondingRequest.headers['accept-encoding'] ?? []).map((str) {
        // Ignore quality specifications in accept-encoding
        // ex. gzip;q=0.8
        if (!str.contains(';')) return str;
        return str.split(';')[0];
      });

      for (var encodingName in allowedEncodings) {
        Converter<List<int>, List<int>> encoder;
        String key = encodingName;

        if (encoders.containsKey(encodingName))
          encoder = encoders[encodingName];
        else if (encodingName == '*') {
          encoder = encoders[key = encoders.keys.first];
        }

        if (encoder != null) {
          if (firstStream) {
            this
                .stream
                .sendHeaders([new Header.ascii('content-encoding', key)]);
          }

          output = encoders[key].bind(output);
          break;
        }
      }
    }

    return output.forEach(this.stream.sendData);
  }

  @override
  void add(List<int> data) {
    if (_isClosed && !_useStream)
      throw ResponseContext.closed();
    else if (_useStream)
      stream.sendData(data);
    else
      buffer.add(data);
  }

  @override
  Future close() async {
    if (_useStream) {
      try {
        await stream.outgoingMessages.close();
      } catch(_) {
        // This only seems to occur on `MockHttpRequest`, but
        // this try/catch prevents a crash.
      }
    }

    _isClosed = true;
    await super.close();
    _useStream = false;
  }
}