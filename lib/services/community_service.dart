import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'account_service.dart';
import 'backend_http.dart';

/// 社区 Payload 包
class CommunityPackage {
  final String id;
  final String kind; // system | block
  final String name;
  final String description;
  final String readme;
  final String status; // pending | approved | rejected
  final String authorId;
  final String authorName;
  final int downloads;
  final DateTime? createdAt;
  final DateTime? reviewedAt;
  final String reviewNote;
  final Map<String, dynamic> spec;

  const CommunityPackage({
    required this.id,
    required this.kind,
    required this.name,
    this.description = '',
    this.readme = '',
    this.status = 'pending',
    this.authorId = '',
    this.authorName = '',
    this.downloads = 0,
    this.createdAt,
    this.reviewedAt,
    this.reviewNote = '',
    this.spec = const {},
  });

  bool get isSystem => kind == 'system';
  bool get isRoot => kind == 'root';

  factory CommunityPackage.fromJson(Map<String, dynamic> json) =>
      CommunityPackage(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'system',
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        readme: json['readme']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
        authorId: json['authorId']?.toString() ?? '',
        authorName: json['authorName']?.toString() ?? '',
        downloads: (json['downloads'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
        reviewedAt: DateTime.tryParse(json['reviewedAt']?.toString() ?? ''),
        reviewNote: json['reviewNote']?.toString() ?? '',
        spec: (json['spec'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

class CommunityException implements Exception {
  final String message;
  const CommunityException(this.message);

  @override
  String toString() => message;
}

/// 社区帖子
class CommunityPost {
  final String id;
  final String authorId;
  final String authorName;
  final String title;
  final String content;
  final String excerpt;
  final List<String> tags;
  final String status;
  final int likes;
  final int commentCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String reviewNote;

  const CommunityPost({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.title,
    this.content = '',
    this.excerpt = '',
    this.tags = const [],
    this.status = 'pending',
    this.likes = 0,
    this.commentCount = 0,
    this.createdAt,
    this.updatedAt,
    this.reviewNote = '',
  });

  bool get isPending => status == 'pending';
  bool get isPublished => status == 'published';
  bool get isRejected => status == 'rejected';

  factory CommunityPost.fromJson(Map<String, dynamic> json) => CommunityPost(
        id: (json['id'] ?? '').toString(),
        authorId: (json['authorId'] ?? '').toString(),
        authorName: (json['authorName'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        content: (json['content'] ?? '').toString(),
        excerpt: (json['excerpt'] ?? '').toString(),
        tags: ((json['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
        status: (json['status'] ?? 'pending').toString(),
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString())?.toLocal(),
        updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString())?.toLocal(),
        reviewNote: (json['reviewNote'] ?? '').toString(),
      );
}

/// 社区评论
class CommunityComment {
  final String id;
  final String postId;
  final String authorId;
  final String authorName;
  final String content;
  final DateTime? createdAt;

  const CommunityComment({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.authorName,
    required this.content,
    this.createdAt,
  });

  factory CommunityComment.fromJson(Map<String, dynamic> json) => CommunityComment(
        id: (json['id'] ?? '').toString(),
        postId: (json['postId'] ?? '').toString(),
        authorId: (json['authorId'] ?? '').toString(),
        authorName: (json['authorName'] ?? '').toString(),
        content: (json['content'] ?? '').toString(),
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString())?.toLocal(),
      );
}

/// SLIPE 社区 API 客户端（复用账号后端与鉴权 token）
class CommunityService {
  CommunityService._();

  static final CommunityService instance = CommunityService._();

  final http.Client _client = BackendHttp.client;

  bool get isConfigured => AppConfig.isAccountBackendConfigured;

  Uri _u(String path) => Uri.parse('${AppConfig.accountBackendBase}$path');

  Map<String, String> _headers(String? token) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  Map<String, dynamic> _decode(http.Response res, String what) {
    Map<String, dynamic> data = const {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      } else if (decoded is Map) {
        data = decoded.cast<String, dynamic>();
      }
    } catch (_) {
      // 非 JSON 响应由下面按状态码兜底
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    final message = data['error']?.toString();
    if (message != null && message.isNotEmpty) {
      throw CommunityException(message);
    }
    throw CommunityException('$what（HTTP ${res.statusCode}）');
  }

  Future<String?> _token() async =>
      await AccountService.instance.savedToken;

  /// 社区公开包列表（仅审核通过）
  Future<List<CommunityPackage>> listPackages({String? kind, String? q}) async {
    final params = <String, String>{
      if (kind != null && kind.isNotEmpty) 'kind': kind,
      if (q != null && q.isNotEmpty) 'q': q,
    };
    final uri = _u('/api/community/packages').replace(queryParameters: params);
    final res = await _client
        .get(uri, headers: _headers(await _token()))
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取社区列表失败');
    final list = data['packages'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => CommunityPackage.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 我发布过的包（含待审核 / 已驳回）
  Future<List<CommunityPackage>> myPackages() async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .get(_u('/api/community/mine'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取我的发布失败');
    final list = data['packages'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => CommunityPackage.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 发布 Payload 到社区（进入待审核）
  Future<CommunityPackage> publish({
    required String kind,
    required String name,
    required String description,
    required Map<String, dynamic> spec,
    String readme = '',
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .post(
          _u('/api/community/publish'),
          headers: _headers(token),
          body: jsonEncode({
            'kind': kind,
            'name': name,
            'description': description,
            'spec': spec,
            'readme': readme,
          }),
        )
        .timeout(const Duration(seconds: 25));
    final data = _decode(res, '发布失败');
    final pkg = data['package'];
    if (pkg is Map) {
      return CommunityPackage.fromJson(pkg.cast<String, dynamic>());
    }
    throw const CommunityException('发布响应异常');
  }

  /// 下载（获取完整 spec），服务端会累计下载量
  Future<Map<String, dynamic>> download(String id) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .post(
          _u('/api/community/packages/${Uri.encodeComponent(id)}/download'),
          headers: _headers(token),
          body: jsonEncode({}),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '下载失败');
    final pkg = data['package'];
    if (pkg is Map && pkg['spec'] is Map) {
      return (pkg['spec'] as Map).cast<String, dynamic>();
    }
    throw const CommunityException('该社区包暂无有效定义');
  }

  // -------------------------------------------------------------------------
  // 论坛
  // -------------------------------------------------------------------------

  /// 帖子流
  Future<({List<CommunityPost> posts, bool hasMore, int total})> fetchFeed({
    String tab = 'latest',
    String query = '',
    int page = 1,
    int pageSize = 10,
  }) async {
    final params = <String, String>{
      'tab': tab,
      'page': '$page',
      'pageSize': '$pageSize',
      if (query.trim().isNotEmpty) 'q': query.trim(),
    };
    final uri = _u('/api/community/feed').replace(queryParameters: params);
    final res = await _client
        .get(uri, headers: _headers(await _token()))
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取帖子失败');
    final list = data['posts'];
    return (
      posts: list is List
          ? list
              .whereType<Map>()
              .map((e) => CommunityPost.fromJson(e.cast<String, dynamic>()))
              .toList()
          : <CommunityPost>[],
      hasMore: data['hasMore'] == true,
      total: (data['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// 发帖
  Future<({CommunityPost post, bool needReview})> createPost({
    required String title,
    required String content,
    List<String> tags = const [],
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .post(
          _u('/api/community/posts'),
          headers: _headers(token),
          body: jsonEncode({'title': title, 'content': content, 'tags': tags}),
        )
        .timeout(const Duration(seconds: 25));
    final data = _decode(res, '发布失败');
    final post = data['post'];
    if (post is Map) {
      return (
        post: CommunityPost.fromJson(post.cast<String, dynamic>()),
        needReview: data['needReview'] == true,
      );
    }
    throw const CommunityException('发布响应异常');
  }

  Future<({CommunityPost post, bool liked})> fetchPost(String id) async {
    final res = await _client
        .get(
          _u('/api/community/posts/${Uri.encodeComponent(id)}'),
          headers: _headers(await _token()),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取帖子失败');
    final post = data['post'];
    if (post is Map) {
      return (
        post: CommunityPost.fromJson(post.cast<String, dynamic>()),
        liked: data['liked'] == true,
      );
    }
    throw const CommunityException('帖子不存在');
  }

  Future<void> deletePost(String id) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .delete(
          _u('/api/community/posts/${Uri.encodeComponent(id)}'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 15));
    _decode(res, '删除失败');
  }

  Future<({bool liked, int likes})> toggleLike(String id) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .post(
          _u('/api/community/posts/${Uri.encodeComponent(id)}/like'),
          headers: _headers(token),
          body: jsonEncode({}),
        )
        .timeout(const Duration(seconds: 15));
    final data = _decode(res, '点赞失败');
    return (
      liked: data['liked'] == true,
      likes: (data['likes'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<CommunityComment>> fetchComments(String postId) async {
    final res = await _client
        .get(
          _u('/api/community/posts/${Uri.encodeComponent(postId)}/comments'),
          headers: _headers(await _token()),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取评论失败');
    final list = data['comments'];
    return list is List
        ? list
            .whereType<Map>()
            .map((e) => CommunityComment.fromJson(e.cast<String, dynamic>()))
            .toList()
        : const [];
  }

  Future<CommunityComment> createComment(String postId, String content) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .post(
          _u('/api/community/posts/${Uri.encodeComponent(postId)}/comments'),
          headers: _headers(token),
          body: jsonEncode({'content': content}),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '评论失败');
    final comment = data['comment'];
    if (comment is Map) {
      return CommunityComment.fromJson(comment.cast<String, dynamic>());
    }
    throw const CommunityException('评论响应异常');
  }

  Future<void> reportPost(String postId, String reason) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .post(
          _u('/api/community/posts/${Uri.encodeComponent(postId)}/report'),
          headers: _headers(token),
          body: jsonEncode({'reason': reason}),
        )
        .timeout(const Duration(seconds: 15));
    _decode(res, '举报失败');
  }

  /// 我的帖子（含待审核/被驳回）
  Future<List<CommunityPost>> myPosts() async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const CommunityException('请先登录 SLIPE 账号');
    }
    final res = await _client
        .get(_u('/api/community/posts/mine'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取我的帖子失败');
    final list = data['posts'];
    return list is List
        ? list
            .whereType<Map>()
            .map((e) => CommunityPost.fromJson(e.cast<String, dynamic>()))
            .toList()
        : const [];
  }

  /// 社区公约
  Future<String> fetchCovenant() async {
    final res = await _client
        .get(_u('/api/community/covenant'))
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取社区公约失败');
    return (data['covenant'] ?? '').toString();
  }

  /// 公开社区设置（首帖审核 / 关键词数量）
  Future<({bool firstPostReview, int keywordCount})> fetchPublicSettings() async {
    final res = await _client
        .get(_u('/api/community/settings'))
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取社区设置失败');
    return (
      firstPostReview: data['firstPostReview'] != false,
      keywordCount: (data['keywordCount'] as num?)?.toInt() ?? 0,
    );
  }
}
