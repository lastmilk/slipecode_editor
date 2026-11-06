# 有向图编排器重塑 - Review

## Review Cycle 1

**Reviewer**: independent general-purpose subagent (read-only)
**Date**: 2026-11-06

### Result: `pass` (after remediation)

### AC Coverage

| AC | Verdict | Evidence |
|----|---------|----------|
| AC-1 节点可拖动定位 | pass | 节点 `onPanUpdate` 更新 `sys.x/y`；**修复**：delta 已除以 `getMaxScaleOnAxis()` 缩放比例 |
| AC-2 双指缩放 0.5~2.5 | pass | `InteractiveViewer(minScale: 0.5, maxScale: 2.5, constrained: false)` |
| AC-3 起点必须是 Block | pass | System 仅渲染左侧输入引脚；Block 渲染右侧输出引脚 |
| AC-4 终点可为 System 或 Block | pass | `toBlockId` null → System 输入；非 null → Block 输入 |
| AC-5 抽屉拖拽添加 | pass | `Draggable` + `DragTarget.onAcceptWithDetails` → `_globalToScene` → `_addSystemAt` |
| AC-6 引脚拖线、废弃连线模式 | pass | 全局 grep "连线模式" 无匹配；输出引脚 `onPan*` 驱动 |
| AC-7 Loader 无手动组装入口 | pass | 无 `SegmentedButton`、无 `PayloadAssemblerView`、无"手动组装"文案（已清理 home_screen / service 注释） |
| AC-8 旧边迁移 | pass | `fromBlockId` 为空取源系统首个 Block；**修复**：自动线性链仅在 JSON 无 `edges` 键时触发 |
| AC-9 生成文档含 Block 粒度 | pass | `loader.json` edges 含 `fromBlock`/`toBlock`；PAYLOAD.md 输出 `System.Block` |
| AC-10 交互流畅度 | pass (self-verified) | `shouldRepaint: true` 保证 live wire 跟手；≤40 边场景可接受 |

### Actionable Findings & Remediation

1. **[高] 节点拖动 delta 未按缩放换算** — 已修复：`sys.x += details.delta.dx / scale`。
2. **[中] 空边草稿自动生成线性链** — 已修复：仅当 `!map.containsKey('edges')` 时触发。
3. **[低] "手动组装"残留文案** — 已修复：清理 home_screen.dart、loader_project_service.dart 注释、loader_project_payload.dart 注释。

### Remaining Advisory (non-blocking)

- **手势竞技场**：`InteractiveViewer` 与内层 `GestureDetector` 的 pan 竞争在 Flutter 中属已知痛点，标准模式（子节点 PanGestureRecognizer 优先获胜）应可工作，需真机确认节点拖动与引脚拖线不被画布平移吞掉。
- **`_endDragWire` 自环**：仅拦截同 Block，不拦截同 System 内连接（spec 未禁止，当前行为合规）。

### Verification

- `dart analyze`（改动文件）：0 error，2 pre-existing info（`unnecessary_string_interpolations`，不在改动范围）。
- 全量 `dart analyze lib`：仅 `git_client_service.dart` 预存错误（缺 `git2dart` 依赖），与本次改动无关。
- 全局 grep：`PayloadAssemblerView` 无匹配；`连线模式` 无匹配；`SegmentedButton` 仅 settings_screen.dart（无关）。
