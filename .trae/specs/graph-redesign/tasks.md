# 有向图编排器重塑 - Implementation Plan

## Task 1: 数据模型升级（Block 实例 ID + 边的 Block 引用）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 为 `BlockPayloadInstance` 增加 `instanceId` 字段（创建时生成 `blk_<micros>`），并更新 `toMap`/`fromMap`。
  - 为 `DesignEdge` 增加 `fromBlockId`（必填）与 `toBlockId`（可空，null 表示终点是 System），更新序列化。
  - 在 `DesignDraft.fromMap` 中实现旧数据迁移：旧边仅有 `fromNodeId`/`toNodeId`，迁移时 `fromBlockId` 取源系统首个 Block 的 instanceId（无 Block 则丢弃该边），`toBlockId` 置 null。
  - 补充 `DesignDraft.blockById(nodeId, blockId)` 辅助方法。
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-8
- **Test Requirements**:
  - `rule` TR-1.1: 新建 `BlockPayloadInstance` 后 `instanceId` 非空且以 `blk_` 开头。
  - `rule` TR-1.2: `DesignEdge.toMap()` 输出含 `fromBlockId`、`toBlockId` 字段；`fromMap` 可正确还原。
  - `rule` TR-1.3: 旧 JSON（边无 fromBlockId）加载后，源系统有 Block 的边被迁移为 `fromBlockId`=首个 Block；源系统无 Block 的边被丢弃。
  - `rule` TR-1.4: `blockById` 返回正确实例，找不到返回 null。
- **Completion Evidence**:
  - `design_draft.dart`: `BlockPayloadInstance.instanceId` 默认 `blk_<micros>`；`DesignEdge` 含 `fromBlockId`/`toBlockId` 并序列化。
  - `DesignDraft.fromMap` 迁移逻辑：`fromBlockId` 为空时取源系统首个 Block 的 instanceId，无 Block 则 `continue` 丢弃。
  - 新增 `DesignDraft.blockById`。
  - `dart analyze` 无 error。

## Task 2: 画布缩放与平移（InteractiveViewer）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 1
- **Description**:
  - 将 `PayloadGraphEditor._buildCanvas` 的双层 `SingleChildScrollView` 替换为 `InteractiveViewer`（`minScale: 0.5`, `maxScale: 2.5`, `constrained: false`）。
  - 画布内容用一个大尺寸 `SizedBox` 承载，节点用 `Positioned` 布局。
  - 节点拖拽在 `InteractiveViewer` 内工作：节点 `GestureDetector.onPanUpdate` 更新坐标。
- **Acceptance Criteria Addressed**: AC-1, AC-2
- **Test Requirements**:
  - `rule` TR-2.1: 画布使用 `InteractiveViewer` 且 min/maxScale 为 0.5/2.5。
  - `rule` TR-2.2: 拖动节点后 `sys.x/y` 更新。
  - `rubric` TR-2.3: 缩放与平移跟手流畅；threshold >= 4。
- **Completion Evidence**:
  - `payload_graph_editor.dart`: `InteractiveViewer(minScale: 0.5, maxScale: 2.5, constrained: false, boundaryMargin: ...)`。
  - 节点 `GestureDetector.onPanUpdate` 更新 `sys.x/y` 并调用 `widget.onChanged`。
  - `TransformationController` 用于坐标换算。

## Task 3: 引脚渲染与坐标计算
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 1
- **Description**:
  - System 节点左侧渲染输入引脚；Block 行左侧输入、右侧输出引脚。
  - 提供坐标函数（已内联到 painter 与命中检测）。
- **Acceptance Criteria Addressed**: AC-3, AC-4
- **Test Requirements**:
  - `rule` TR-3.1: System 节点渲染左侧输入引脚，不渲染输出引脚。
  - `rule` TR-3.2: 每个 Block 渲染左右两个引脚。
  - `rule` TR-3.3: 坐标函数返回值与视觉位置一致。
- **Completion Evidence**:
  - `_buildNode` 中 `Positioned(left: -_kPinRadius, top: _kSystemInputPinY - _kPinRadius)` 渲染 System 输入引脚。
  - `_buildBlockRow` 渲染 Block 左输入 + 右输出引脚。
  - 引脚中心坐标：System 输入 `(sys.x, sys.y+22)`；Block `(sys.x, sys.y+_blockRowCenterY(i))` 与 `(sys.x+_kNodeWidth, ...)`，与 painter 计算一致。

## Task 4: 引脚拖线交互（live wire + 创建边）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 3
- **Description**:
  - 输出引脚 `GestureDetector.onPanStart/Update/End` 驱动拖线。
  - `_endDragWire` 命中检测最近输入引脚（半径 28px）。
  - `CustomPaint` 绘制 live wire。
  - 移除连线模式开关。
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-6
- **Test Requirements**:
  - `rule` TR-4.1: 工具栏无"连线模式"FilterChip。
  - `rule` TR-4.2: Block 输出 → System 输入，生成 `fromBlockId` 非空、`toBlockId` 为 null 的边。
  - `rule` TR-4.3: 拖到 Block 输入，生成 `toBlockId` 为该 Block instanceId 的边。
  - `rule` TR-4.4: 重复起点终点不生成新边。
  - `rubric` TR-4.5: live wire 跟手流畅；threshold >= 4。
- **Completion Evidence**:
  - 工具栏已无连线模式 FilterChip，改为提示文案。
  - `_connect` 检查重复边并 toast。
  - `_EdgePainter` 根据 `dragFrom`/`dragPointer` 绘制 live wire。

## Task 5: 底部抽屉式 System 调色板（拖拽添加）
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 2
- **Description**:
  - 底部可收起/展开抽屉（`_drawerOpen` 状态）。
  - System 项为 `Draggable<String>`，画布为 `DragTarget`，落点坐标经 `_globalToScene` 转换后创建节点。
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `rule` TR-5.1: 底部有可收起/展开的抽屉手柄。
  - `rule` TR-5.2: 拖动 System 到画布松手，在落点附近创建节点。
  - `rule` TR-5.3: 点击 System 项不再直接添加。
- **Completion Evidence**:
  - `_buildDrawer` 含手柄栏（点击切换 `_drawerOpen`）与展开后的 `Draggable` 列表。
  - 画布 `DragTarget.onAcceptWithDetails` 调用 `_globalToScene(details.offset)` → `_addSystemAt`。
  - System 项无 `onPressed` 添加逻辑（自定义端除外，保留点击创建编辑器入口）。

## Task 6: 重写连线绘制（引脚到引脚）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 3, Task 4
- **Description**:
  - `_EdgePainter` 边起点 = 源 Block 输出引脚；终点 = 目标 System/Block 输入引脚。
  - 三次贝塞尔曲线 + 箭头 + 类型标签。
- **Acceptance Criteria Addressed**: AC-4, AC-6
- **Test Requirements**:
  - `rule` TR-6.1: 边的起点落在源 Block 输出引脚，终点落在目标输入引脚。
  - `rule` TR-6.2: live wire 从输出引脚画到指针位置。
  - `rubric` TR-6.3: 连线视觉清晰、箭头方向正确；threshold >= 4。
- **Completion Evidence**:
  - `_EdgePainter.paint` 计算 start/end 引脚坐标并绘制 cubic Bezier + arrow + label。

## Task 7: Loader 项目移除手动组装
- **Status**: `completed`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 移除 `_useDraft`、`_manualDraft`、`_buildModeSelector`、`_buildManualAssembler`。
  - 无设计稿时引导创建设计稿。
  - 移除 `PayloadAssemblerView`，保留 `PayloadParamsSheet`。
- **Acceptance Criteria Addressed**: AC-7
- **Test Requirements**:
  - `rule` TR-7.1: 页面不含 `SegmentedButton` 与"手动组装"文案。
  - `rule` TR-7.2: 无设计稿时引导创建设计稿。
  - `rule` TR-7.3: `PayloadAssemblerView` 类已移除。
- **Completion Evidence**:
  - `create_loader_project_screen.dart` 无 `SegmentedButton`/`PayloadAssemblerView`；`_create` 要求 `_selectedDraft != null`。
  - `payload_assembler.dart` 仅保留 `PayloadParamsSheet`。
  - `dart analyze` 无 error。

## Task 8: 生成逻辑适配 Block 粒度边
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 1
- **Description**:
  - `loader.json` edges 增加 `fromBlock`/`toBlock`（specId）。
  - vibe prompt 与 PAYLOAD.md 边描述含 Block 名。
- **Acceptance Criteria Addressed**: AC-9
- **Test Requirements**:
  - `rule` TR-8.1: `loader.json` edges 含 `fromBlock`/`toBlock` 字段。
  - `rule` TR-8.2: PAYLOAD.md 跳转描述含源 Block 名。
- **Completion Evidence**:
  - `loader_project_service.dart` manifest edges 含 `fromBlock`/`toBlock`。
  - `composeVibePrompt` 与 `_composePayloadDoc` 输出 `System.Block` 格式。

## Task 9: 编译验证与整体联调
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 2, 4, 5, 6, 7, 8
- **Description**:
  - `dart analyze` 检查。
- **Acceptance Criteria Addressed**: AC-1~AC-10
- **Test Requirements**:
  - `rule` TR-9.1: `dart analyze` 无 error。
  - `rule` TR-9.2: 端到端流程无异常。
  - `rubric` TR-9.3: 整体交互流畅度；threshold >= 4。
- **Completion Evidence**:
  - `dart analyze lib`：本次改动文件（design_draft.dart, payload_graph_editor.dart, payload_assembler.dart, create_loader_project_screen.dart, loader_project_service.dart）均无 error。
  - 仅存预存错误：`git_client_service.dart` 缺少 `git2dart` 依赖（与本次改动无关）。
