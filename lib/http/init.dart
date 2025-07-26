import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart';
import 'package:brotli/brotli.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;

class Request {
  static const _gzipDecoder = GZipDecoder();
  static const _brotilDecoder = BrotliDecoder();

  static final Request _instance = Request._internal();
  static late AccountManager accountManager;
  static late final Dio dio;
  factory Request() => _instance;

  /// 设置cookie
  static Future<void> setCookie() async {
    accountManager = AccountManager();
    dio.interceptors.add(accountManager);
    Accounts.refresh();
    final List<Cookie> cookies = Accounts.main.cookieJar.toList();
    final webManager = web.CookieManager();
    await Future.wait(
      cookies.map(
        (item) => webManager.setCookie(
          url: web.WebUri(item.domain ?? ''),
          name: item.name,
          value: item.value,
          path: item.path ?? '',
          domain: item.domain,
          isSecure: item.secure,
          isHttpOnly: item.httpOnly,
        ),
      ),
    );

    if (Accounts.main.isLogin) {
      final coin = GStorage.userInfo.get('userInfoCache')?.money;
      if (coin == null) {
        setCoin();
      } else {
        GlobalData().coins = coin;
      }
    }
  }

  static Future<void> setCoin() async {
    final res = await UserHttp.getCoin();
    if (res['status']) {
      GlobalData().coins = res['data'];
    }
  }

  static Future<void> buvidActive(Account account) async {
    // 这样线程不安全, 但仍按预期进行
    if (account.activited) return;
    account.activited = true;
    try {
      // final html = await Request().get(Api.dynamicSpmPrefix,
      //     options: Options(extra: {'account': account}));
      // final String spmPrefix = _spmPrefixExp.firstMatch(html.data)!.group(1)!;
      final String randPngEnd = base64.encode(
        List<int>.generate(32, (_) => Utils.random.nextInt(256)) +
            List<int>.filled(4, 0) +
            [73, 69, 78, 68] +
            List<int>.generate(4, (_) => Utils.random.nextInt(256)),
      );

      String jsonData = json.encode({
        '3064': 1,
        '39c8':
            '${account is AnonymousAccount ? '333.1365' : '333.788'}.fp.risk',
        '3c43': {
          'adca': 'Linux',
          'bfe9': randPngEnd.substring(randPngEnd.length - 50),
        },
      });

      await Request().post(
        Api.activateBuvidApi,
        data: {'payload': jsonData},
        options: Options(contentType: Headers.jsonContentType),
      );
    } catch (_) {}
  }

  /*
   * config it and create
   */
  Request._internal() {
    //BaseOptions、Options、RequestOptions 都可以配置参数，优先级别依次递增，且可以根据优先级别覆盖参数
    BaseOptions options = BaseOptions(
      //请求基地址,可以包含子路径
      baseUrl: HttpString.apiBaseUrl,
      //连接服务器超时时间，单位是毫秒.
      connectTimeout: const Duration(milliseconds: 10000),
      //响应流上前后两次接受到数据的间隔，单位为毫秒。
      receiveTimeout: const Duration(milliseconds: 10000),
      //Http请求头.
      headers: {
        'user-agent': 'Dart/3.6 (dart:io)', // Http2Adapter不会自动添加标头
      },
      responseDecoder: responseDecoder, // Http2Adapter没有自动解压
      persistentConnection: true,
    );

    final bool enableSystemProxy = Pref.enableSystemProxy;
    final String systemProxyHost = Pref.systemProxyHost;
    final String systemProxyPort = Pref.systemProxyPort;

    final http11Adapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..idleTimeout = const Duration(seconds: 15)
          ..autoUncompress = false; // Http2Adapter没有自动解压, 统一行为
        // 设置代理
        if (enableSystemProxy) {
          client
            ..findProxy = ((_) => 'PROXY $systemProxyHost:$systemProxyPort')
            ..badCertificateCallback =
                (X509Certificate cert, String host, int port) => true;
        }
        return client;
      },
    );

    late Uri proxy;
    if (enableSystemProxy) {
      proxy = Uri(
        scheme: 'http',
        host: systemProxyHost,
        port: int.parse(systemProxyPort),
      );
    }

    dio = Dio(options)
      ..httpClientAdapter = Pref.enableHttp2
          ? Http2Adapter(
              ConnectionManager(
                idleTimeout: const Duration(seconds: 15),
                onClientCreate: enableSystemProxy
                    ? (_, config) {
                        config
                          ..proxy = proxy
                          ..onBadCertificate = (_) => true;
                      }
                    : Pref.badCertificateCallback
                    ? (_, config) {
                        config.onBadCertificate = (_) => true;
                      }
                    : null,
              ),
              fallbackAdapter: http11Adapter,
            )
          : http11Adapter;

    // 先于其他Interceptor
    dio.interceptors.add(RetryInterceptor(Pref.retryCount, Pref.retryDelay));

    // 日志拦截器 输出请求、响应内容
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          request: false,
          requestHeader: false,
          responseHeader: false,
        ),
      );
    }

    dio.transformer = BackgroundTransformer();
    dio.options.validateStatus = (int? status) {
      return status! >= 200 && status < 300;
    };
  }

  /*
   * get请求
   */
  Future<Response> get<T>(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return dio.get<T>(
        url,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * post请求
   */
  Future<Response> post<T>(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    // if (kDebugMode) debugPrint('post-data: $data');
    try {
      return dio.post<T>(
        url,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      AccountManager.toast(e);
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * 下载文件
   */
  Future<Response> downloadFile(
    String urlPath,
    String savePath, {
    CancelToken? cancelToken,
  }) async {
    try {
      return dio.download(
        urlPath,
        savePath,
        cancelToken: cancelToken,
        // onReceiveProgress: (int count, int total) {
        // 进度
        // if (kDebugMode) debugPrint("$count $total");
        // },
      );
      // if (kDebugMode) debugPrint('downloadFile success: ${response.data}');
    } on DioException catch (e) {
      // if (kDebugMode) debugPrint('downloadFile error: $e');
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        },
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * 取消请求
   *
   * 同一个cancel token 可以用于多个请求，当一个cancel token取消时，所有使用该cancel token的请求都会被取消。
   * 所以参数可选
   */
  void cancelRequests(CancelToken token) {
    token.cancel("cancelled");
  }

  static String headerUa({String type = 'mob'}) {
    return switch (type) {
      'mob' =>
        'Mozilla/5.0 (Linux; Android 10; SM-G975F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.101 Mobile Safari/537.36',
      _ =>
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
    };
  }

  static String responseDecoder(
    List<int> responseBytes,
    RequestOptions options,
    ResponseBody responseBody,
  ) {
    switch (responseBody.headers['content-encoding']?.firstOrNull) {
      case 'gzip':
        return utf8.decode(
          _gzipDecoder.decodeBytes(responseBytes),
          allowMalformed: true,
        );
      case 'br':
        return utf8.decode(
          _brotilDecoder.convert(responseBytes),
          allowMalformed: true,
        );
      default:
        return utf8.decode(responseBytes, allowMalformed: true);
    }
  }
}
