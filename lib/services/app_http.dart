import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

/// One HTTP client for the whole app.
///
/// The top-level functions of the `http` package open a new connection for
/// every request and close it afterwards: each call pays a TCP and a TLS
/// handshake again. Starting a track takes three requests to the same hosts
/// (match, streams, playlist), and a Canvas lookup several more; through
/// this client they reuse the connections that are already open.
///
/// A connection kept open can be closed by the server just as it is used
/// again: a request that fails that way (or on a network that drops for an
/// instant) is sent once more instead of being reported as a failure.
final http.Client appHttp = RetryClient(
  IOClient(
    HttpClient()
      // Covers the pause between two requests of the same track, and stays
      // below the time servers keep an idle connection for.
      ..idleTimeout = const Duration(seconds: 40)
      ..connectionTimeout = const Duration(seconds: 12),
  ),
  retries: 1,
  when: (response) => false,
  whenError: (error, stackTrace) => error is http.ClientException || error is IOException,
  delay: (attempt) => Duration.zero,
);
