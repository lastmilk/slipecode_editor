import 'package:flutter/material.dart';

import '../models/scene.dart';

/// 场景注册表：内置五个场景的文案、强调色、图标与二三级选项。
///
/// 顺序即场景大厅的展示顺序。
class SceneRegistry {
  SceneRegistry._();

  static const List<SceneProjectType> _codingTypes = [
    SceneProjectType(
      id: 'paradigm_new',
      name: '新范式',
      description: '设计稿 + 三层 Payload + AI 生成。',
      badge: '推荐',
      route: 'loader',
    ),
    SceneProjectType(
      id: 'paradigm_classic',
      name: '传统范式',
      description: 'Flutter / Android / Node / Web 内置模板。',
      route: 'classic',
    ),
  ];

  static const List<SceneElement> _codingElements = [
    SceneElement(
      id: 'mobile',
      name: '移动应用',
      description: '手机端原生体验，一屏一交互。',
      icon: Icons.phone_iphone,
    ),
    SceneElement(
      id: 'desktop',
      name: '桌面应用',
      description: '面向 Windows / macOS / Linux 的本地应用。',
      icon: Icons.desktop_windows_outlined,
    ),
    SceneElement(
      id: 'web',
      name: '网页站点',
      description: '浏览器即开即用的站点与落地页。',
      icon: Icons.language,
    ),
    SceneElement(
      id: 'component',
      name: '组件库',
      description: '可复用的 UI 组件与设计系统。',
      icon: Icons.widgets_outlined,
    ),
    SceneElement(
      id: 'admin',
      name: '后台工具',
      description: '数据看板与内部运营工具。',
      icon: Icons.space_dashboard_outlined,
    ),
  ];

  static const List<SceneElement> _videoElements = [
    SceneElement(
      id: 'promo',
      name: '营销宣传片',
      description: '品牌短片与产品发布视频。',
      icon: Icons.campaign_outlined,
    ),
    SceneElement(
      id: 'explainer',
      name: '知识讲解',
      description: '结构化讲解与教程内容。',
      icon: Icons.school_outlined,
    ),
    SceneElement(
      id: 'poster',
      name: '动态海报',
      description: '社交媒体上的动态视觉海报。',
      icon: Icons.photo_size_select_actual_outlined,
    ),
    SceneElement(
      id: 'data',
      name: '数据动画',
      description: '数据可视化与动态图表。',
      icon: Icons.insights,
    ),
  ];

  static const List<SceneProjectType> _videoTypes = [
    SceneProjectType(
      id: 'remotion',
      name: 'Remotion (React)',
      description: '用 React 组件逐帧描述画面，适合数据驱动与批量产出。',
    ),
    SceneProjectType(
      id: 'html_canvas',
      name: 'HTML + Canvas + GSAP',
      description: 'Canvas 绘制搭配 GSAP 时间轴，轻量直接。',
    ),
    SceneProjectType(
      id: 'threejs',
      name: 'Three.js 3D',
      description: '三维场景与相机运动，适合产品演示。',
    ),
  ];

  static const List<SceneElement> _autoElements = [
    SceneElement(
      id: 'schedule',
      name: '定时任务',
      description: '按 Cron 周期自动执行。',
      icon: Icons.schedule,
    ),
    SceneElement(
      id: 'event',
      name: '事件触发',
      description: '由 Webhook 或消息事件唤起。',
      icon: Icons.bolt_outlined,
    ),
    SceneElement(
      id: 'batch',
      name: '批量处理',
      description: '大批量数据的清洗与转换。',
      icon: Icons.layers_outlined,
    ),
    SceneElement(
      id: 'report',
      name: '周期报告',
      description: '定期汇总并推送报告。',
      icon: Icons.summarize_outlined,
    ),
  ];

  static const List<SceneProjectType> _autoTypes = [
    SceneProjectType(
      id: 'dify_import',
      name: 'Dify 工作流导入',
      description: '导入已有 Dify 应用，交给调度器按计划运行。',
    ),
    SceneProjectType(
      id: 'blank',
      name: '空白工作流',
      description: '从零配置触发、处理与输出节点。',
    ),
    SceneProjectType(
      id: 'preset_daily',
      name: '日报摘要',
      description: '每日汇总信息并生成摘要推送。',
    ),
    SceneProjectType(
      id: 'preset_alert',
      name: '监控告警',
      description: '指标越界时触发通知与处置流程。',
    ),
    SceneProjectType(
      id: 'preset_asset',
      name: '素材巡检',
      description: '巡检素材完整性与更新状态。',
    ),
  ];

  static const List<SceneElement> _textElements = [
    SceneElement(
      id: 'word',
      name: 'Word 文档',
      description: '长文撰写与版式排布。',
      icon: Icons.description_outlined,
    ),
    SceneElement(
      id: 'ppt',
      name: 'PPT 演示',
      description: '演示文稿与汇报提纲。',
      icon: Icons.slideshow_outlined,
    ),
    SceneElement(
      id: 'excel',
      name: 'Excel 表格',
      description: '结构化数据与计算表。',
      icon: Icons.table_chart_outlined,
    ),
    SceneElement(
      id: 'pdf',
      name: 'PDF 文档',
      description: '定稿分发与打印阅读。',
      icon: Icons.picture_as_pdf_outlined,
    ),
  ];

  static const SceneProjectType _textNovel = SceneProjectType(
    id: 'novel',
    name: '小说',
    description: '章节化长篇创作，保持人物与设定一致。',
  );
  static const SceneProjectType _textMarketing = SceneProjectType(
    id: 'marketing',
    name: '营销文案',
    description: '多平台口径的推广与种草内容。',
  );
  static const SceneProjectType _textResearch = SceneProjectType(
    id: 'research',
    name: '研究报告',
    description: '资料归纳、论证结构与结论输出。',
  );
  static const SceneProjectType _textContract = SceneProjectType(
    id: 'contract',
    name: '合同',
    description: '条款化文本，强调严谨与可追溯。',
  );
  static const SceneProjectType _textDataAnalysis = SceneProjectType(
    id: 'data_analysis',
    name: '数据分析',
    description: '表格建模、指标拆解与分析结论。',
  );
  static const SceneProjectType _textDeck = SceneProjectType(
    id: 'deck',
    name: '演示稿',
    description: '汇报节奏与要点提炼。',
  );

  static const List<SceneProjectType> _textTypes = [
    _textNovel,
    _textMarketing,
    _textResearch,
    _textContract,
    _textDataAnalysis,
    _textDeck,
  ];

  static const Map<String, List<SceneProjectType>> _textTypesByElement = {
    'word': [_textNovel, _textMarketing, _textResearch, _textContract],
    'ppt': [_textDeck, _textMarketing],
    'excel': [_textDataAnalysis],
    'pdf': [_textResearch, _textContract, _textNovel],
  };

  static const List<SceneElement> _chatElements = [
    SceneElement(
      id: 'roleplay',
      name: '角色扮演',
      description: '可对话、有性格的虚拟角色。',
      icon: Icons.theater_comedy_outlined,
    ),
    SceneElement(
      id: 'world',
      name: '世界观构建',
      description: '设定地理、势力与历史脉络。',
      icon: Icons.public,
    ),
    SceneElement(
      id: 'memory',
      name: '记忆库管理',
      description: '管理角色的长期记忆条目。',
      icon: Icons.psychology_outlined,
    ),
    SceneElement(
      id: 'story',
      name: '剧情推演',
      description: '多角色共同推动剧情走向。',
      icon: Icons.auto_stories_outlined,
    ),
  ];

  static const List<SceneProjectType> _chatTypes = [
    SceneProjectType(
      id: 'single',
      name: '单角色',
      description: '与一个角色深度对话。',
    ),
    SceneProjectType(
      id: 'group',
      name: '多角色群聊',
      description: '多个角色同场互动。',
    ),
    SceneProjectType(
      id: 'long_memory',
      name: '长期记忆角色',
      description: '跨会话保留记忆与关系。',
    ),
  ];

  /// 五个场景，顺序即大厅顺序。
  static const List<SceneDefinition> scenes = [
    SceneDefinition(
      id: 'vibe_coding',
      name: 'VibeCoding',
      tagline: '界面设计与代码的全新范式。',
      accent: Color(0xFF00F07A),
      symbol: SceneSymbolKind.coding,
      isPrimary: true,
      elements: _codingElements,
      types: _codingTypes,
      typesByElement: {
        'mobile': _codingTypes,
        'desktop': _codingTypes,
        'web': _codingTypes,
        'component': _codingTypes,
        'admin': _codingTypes,
      },
    ),
    SceneDefinition(
      id: 'vibe_video',
      name: 'VibeVideo',
      tagline: '视频制作的不二之选。',
      accent: Color(0xFFA78BFA),
      symbol: SceneSymbolKind.video,
      elements: _videoElements,
      types: _videoTypes,
    ),
    SceneDefinition(
      id: 'auto',
      name: 'Auto',
      tagline: 'AI 替你做完一切。',
      accent: Color(0xFF38BDF8),
      symbol: SceneSymbolKind.auto,
      elements: _autoElements,
      types: _autoTypes,
    ),
    SceneDefinition(
      id: 'text',
      name: 'Text',
      tagline: '自动化富文本撰写。',
      accent: Color(0xFFFB923C),
      symbol: SceneSymbolKind.text,
      elements: _textElements,
      types: _textTypes,
      typesByElement: _textTypesByElement,
    ),
    SceneDefinition(
      id: 'chat',
      name: 'Chat',
      tagline: '属于你的人。',
      accent: Color(0xFFF472B6),
      symbol: SceneSymbolKind.chat,
      elements: _chatElements,
      types: _chatTypes,
    ),
  ];

  /// 按 id 查找场景。
  static SceneDefinition? byId(String id) {
    for (final scene in scenes) {
      if (scene.id == id) return scene;
    }
    return null;
  }
}
