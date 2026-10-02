import 'dart:typed_data';

import 'package:flutter_starterkit/core/network/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('API contracts', () {
    test('copies request path maps and body bytes in both directions', () {
      final sourceBody = Uint8List.fromList([1, 2, 3]);
      final query = {'page': '1'};
      final headers = {'accept': 'application/json'};
      final request = ApiRequest(
        method: ApiMethod.get,
        path: 'items',
        query: query,
        headers: headers,
        body: sourceBody,
      );
      sourceBody[0] = 9;
      query['page'] = '2';
      headers['accept'] = 'text/plain';
      final exposed = request.body!;
      exposed[1] = 9;
      expect(request.body, [1, 2, 3]);
      expect(request.query, {'page': '1'});
      expect(request.headers, {'accept': 'application/json'});
      expect(() => request.headers['x'] = 'value', throwsUnsupportedError);
    });

    test(
      'rejects unsafe paths, reserved headers, and normalized duplicates',
      () {
        for (final path in [
          '/absolute',
          'https://example.test/x',
          '../escape',
          '%2e%2e/x',
          'a%2fb',
        ]) {
          expect(
            () => ApiRequest(method: ApiMethod.get, path: path),
            throwsArgumentError,
            reason: path,
          );
        }
        expect(
          () => ApiRequest(
            method: ApiMethod.get,
            path: 'items',
            headers: {'Cookie': 'session'},
          ),
          throwsArgumentError,
        );
        expect(
          () => ApiRequest(
            method: ApiMethod.get,
            path: 'items',
            headers: {'Accept': 'a', 'accept': 'b'},
          ),
          throwsArgumentError,
        );
        expect(
          () => ApiRequest(
            method: ApiMethod.get,
            path: 'items',
            headers: {'Authorization': 'Bearer private'},
          ),
          throwsArgumentError,
        );
      },
    );

    test('copies bounded response bytes and multi-value headers', () {
      final sourceBody = Uint8List.fromList([4, 5]);
      final sourceHeaders = {
        'Set-Cookie': ['a=1', 'b=2'],
      };
      final response = ApiResponse(
        statusCode: 200,
        headers: sourceHeaders,
        body: sourceBody,
      );
      sourceBody[0] = 0;
      sourceHeaders['Set-Cookie']!.add('c=3');
      final exposed = response.body..[1] = 0;
      expect(exposed, [4, 0]);
      expect(response.body, [4, 5]);
      expect(response.headers['set-cookie'], ['a=1', 'b=2']);
      expect(
        () => response.headers['set-cookie']!.add('x'),
        throwsUnsupportedError,
      );
    });
  });
}
