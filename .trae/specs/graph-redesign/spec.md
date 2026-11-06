# 有向图编排器重塑 - Product Requirements Document

## Overview
- **Summary**: 对 SLIPE 设计稿有向图编排器进行交互与数据模型重塑，将其升级为类 Unreal Engine Blueprint 的节点连线编排体验，并移除 Loader 项目中的"手动组装"入口。
- **Purpose**: 让用户以更直观的方式编排 System/Block Payload 之间的跳转与依赖关系，提升设计稿编排效率与准确性。
- **Target Users**: 使用 SLIPE 编辑器创建设计稿与 Loader 项目的开发者。

## Goals
- 节点可自由拖动定位，并支持双指缩放画布。
- 连线的起点限定为 Block Payload，终点可为 System 或 Block Payload。
- 底部模块列表改为可收起的抽屉式面板，通过拖拽（而非点击）将端放入画布。
- 采用 UE Blueprint 式的"从引脚拖线"建立连接，彻底废弃"连线模式"开关。
- Loader 项目创建流程不再提供"手动组装"，仅允许从设计稿生成。

## Non-Goals
- 不修改 Root Payload 的选择与参数编辑逻辑。
- 不改变 System/Block Payload 的注册中心与参数定义。
- 不改变 Loader 项目生成的目录结构与 .md 内容格式（仅在跳转关系描述中补充 Block 粒度信息）。
- 不引入新的第三方依赖库。

## Background & Context
- 当前 `PayloadGraphEditor`（`lib/widgets/payload_graph_editor.dart`）使用「连线模式」开关：开启后依次点击两个 System 节点创建有向边；边仅在 System 节点之间建立。
- 画布使用双层 `SingleChildScrollView`，仅支持平移不支持缩放；节点拖拽在非连线模式下生效。
- 底部 System 调色板为横向 `ActionChip` 列表，点击即添加。
- `DesignEdge` 仅有 `fromNodeId`/`toNodeId`（均指 System 节点），无法表达 Block 粒度的跳转。
- `BlockPayloadInstance` 没有实例级 ID，无法被边精确引用。
- `create_loader_project_screen.dart` 提供"采用设计稿 / 手动组装"二选一；手动组装使用 `PayloadAssemblerView`（列表式编排，非图）。

## Functional Requirements

### FR-1: 画布交互（拖动定位 + 双指缩放）
- 画布支持双指捏合缩放（scale 范围 0.5x ~ 2.5x）。
- 画布支持单指拖动平移（空白区域）。
- System 节点可拖动改变位置；拖动时不触发画布平移。
- 缩放下节点位置与连线保持视觉一致。

### FR-2: 连接对象规则
- 边的起点必须是某个 System 节点下的 Block Payload 实例。
- 边的终点可以是 System 节点本身，或某个 System 节点下的 Block Payload 实例。
- 不允许 System → 任何方向 的起点连接。
- 同一对 (起点, 终点) 不允许重复边。

### FR-3: 底部抽屉式模块列表
- 底部调色板改为可收起/展开的抽屉（默认收起为一条栏，展开显示全部 System Payload）。
- System Payload 通过拖拽放入画布，不再支持点击添加。
- 拖拽放下时在指针位置创建节点。

### FR-4: UE 式引脚拖线连线
- 每个 Block Payload 实例在卡片内显示一个**输出引脚**（右侧，作为跳转起点）。
- 每个 System 节点显示一个**输入引脚**（左侧）；每个 Block 实例也显示一个**输入引脚**（左侧）。
- 用户从输出引脚按下并拖动到输入引脚松开，即创建一条有向边。
- 拖动过程中显示一条从输出引脚到指针的实时连线（live wire）。
- 连线类型（跳转 / 依赖）在拖线后通过就近浮层选择，或默认跳转并可在关系列表中切换。
- 废弃原"连线模式"开关与"先点起点再点终点"逻辑。

### FR-5: Loader 项目移除手动组装
- `CreateLoaderProjectScreen` 不再显示"Payload 组装方式"分段开关。
- 始终采用"采用设计稿"流程；无设计稿时引导用户前往创建设计稿。
- 移除 `PayloadAssemblerView` 的使用（保留 `PayloadParamsSheet`）。

## Non-Functional Requirements
- **NFR-1（兼容性）**: 已有设计稿数据（含旧 system→system 边）加载时尽量迁移：源端取其首个 Block 作为起点（无 Block 则丢弃该边），终点保留为 System 节点。
- **NFR-2（生成一致性）**: `loader.json` 与 PAYLOAD.md 中跳转关系的描述需包含 Block 粒度信息（源 Block 名、目标 Block 名或 System 名），不破坏现有生成流程。
- **NFR-3（性能）**: 缩放与拖线动画流畅，无明显卡顿（节点数 ≤ 20、边数 ≤ 40）。

## Constraints
- **Technical**: 纯 Flutter 实现，不引入新依赖；使用 `GestureDetector`/`InteractiveViewer` 与 `CustomPaint`。
- **Dependencies**: 数据模型变更需同步 `design_draft.dart`、`payload_graph_editor.dart`、`loader_project_service.dart`。

## Assumptions
- 连线类型选择采用"拖线后弹出类型选择浮层"的简化方案（默认跳转）。
- Block 实例 ID 采用 `blk_<microseconds>` 在创建时生成。
- 缩放以画布中心或手势中心为锚点（使用 Flutter 内置 `TransformationController`）。

## Acceptance Criteria

### AC-1: 节点可拖动定位
- **Type**: `rule`
- **Given**: 画布中存在至少一个 System 节点
- **When**: 用户按住节点并拖动
- **Then**: 节点跟随指针移动，松开后位置保留并持久化到设计稿
- **Pass Condition**: 拖动后 `sys.x`/`sys.y` 改变且 `onChanged` 触发
- **Evidence**: 拖动节点并检查坐标更新

### AC-2: 画布支持双指缩放
- **Type**: `rule`
- **Given**: 画布非空
- **When**: 用户双指捏合
- **Then**: 画布整体缩放，节点与连线同步缩放，缩放范围 0.5~2.5
- **Pass Condition**: 缩放下视觉比例正确且不超出范围
- **Evidence**: 双指缩放操作观察

### AC-3: 边的起点必须是 Block
- **Type**: `rule`
- **Given**: 画布中存在节点
- **When**: 尝试从非 Block 输出引脚（如 System 节点）拖出连线
- **Then**: 无法开始拖线（System 无输出引脚）
- **Pass Condition**: System 节点不渲染输出引脚，仅 Block 渲染
- **Evidence**: 视觉检查 System 无右侧输出引脚

### AC-4: 边的终点可为 System 或 Block
- **Type**: `rule`
- **Given**: 从某 Block 输出引脚开始拖线
- **When**: 拖到 System 输入引脚或 Block 输入引脚松开
- **Then**: 创建一条边，目标分别为该 System 或该 Block
- **Pass Condition**: `DesignEdge.toBlockId` 为 null（System）或目标 Block 实例 ID
- **Evidence**: 创建边后检查 edge 字段

### AC-5: 底部抽屉可收起并支持拖拽添加
- **Type**: `rule`
- **Given**: 编辑器打开
- **When**: 用户点击抽屉手柄展开，拖动某 System Payload 到画布松开
- **Then**: 在松开位置创建对应 System 节点
- **Pass Condition**: 松手后 `draft.systems` 增加一项且坐标接近落点
- **Evidence**: 拖拽添加操作

### AC-6: 引脚拖线创建连接，废弃连线模式
- **Type**: `rule`
- **Given**: 画布中存在含 Block 的节点
- **When**: 从 Block 输出引脚拖到某输入引脚松开
- **Then**: 实时连线跟随指针，松开后生成边；界面无"连线模式"开关
- **Pass Condition**: 工具栏不含连线模式 FilterChip；拖线生成边成功
- **Evidence**: UI 检查与拖线操作

### AC-7: Loader 项目无手动组装入口
- **Type**: `rule`
- **Given**: 进入创建 Loader 项目页
- **When**: 查看页面
- **Then**: 无"Payload 组装方式"分段开关，仅显示设计稿选择流程
- **Pass Condition**: 页面不含 SegmentedButton 与手动组装区
- **Evidence**: 页面渲染检查

### AC-8: 旧设计稿边迁移
- **Type**: `rule`
- **Given**: 旧设计稿含 system→system 边且源系统含 Block
- **When**: 加载该设计稿
- **Then**: 边的起点迁移为源系统首个 Block，终点保留 System
- **Pass Condition**: `fromBlockId` 非空且指向源系统首个 Block
- **Evidence**: 加载旧 JSON 检查 edges

### AC-9: 生成文档包含 Block 粒度跳转信息
- **Type**: `rule`
- **Given**: 设计稿含 Block→Block 边并生成 Loader 项目
- **When**: 查看 PAYLOAD.md / loader.json
- **Then**: 跳转关系描述含源 Block 名与目标名
- **Pass Condition**: 文档中出现源 Block 名
- **Evidence**: 生成后 grep 文档

### AC-10: 连线交互流畅度
- **Type**: `rubric`
- **Dimension**: 拖线与缩放的视觉流畅度与跟手程度
- **Scale**: 1-5
- **Anchors**: 1 = 严重卡顿/跟手差；3 = 可用但偶有掉帧；5 = 流畅跟手
- **Pass Threshold**: >= 4
- **Evidence**: 实际操作拖线与缩放观察

## Open Questions
- [ ] 连线类型（跳转/依赖）在拖线后是弹浮层选择还是默认跳转后在关系列表改？→ 采用默认跳转 + 关系列表可改（简化）。
