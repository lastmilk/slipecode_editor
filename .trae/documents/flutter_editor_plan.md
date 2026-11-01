# Flutter 安卓编辑器实现计划

## 项目概述

用 Flutter 开发一个运行在 Android 上的 Flutter 代码编辑器应用，支持：
1. **创建 Flutter 项目** - 调用 flutter create 命令生成项目骨架
2. **文件管理** - 浏览项目文件树、打开/保存/新建/删除文件
3. **代码高亮** - Dart 语言语法高亮显示

暂不支持：构建运行、热重载、调试等复杂功能。

## 仓库现状

- 工作目录：`c:\Users\Administrator\Documents\slipe`（基本为空，仅含 .gitignore）
- Flutter SDK：`C:\flutter`，版本 3.47.8 / Dart 3.13.7
- 目标平台：Android API 21+

## 技术选型

| 功能 | 方案 | 说明 |
|------|------|------|
| 代码编辑器 | `code_text_field` + `highlight` | 轻量且可定制，支持 Dart 语法 |
| 文件树 | 自绘 TreeView | 使用 `expansion_tile` 递归实现，配合 `dart:io` |
| 进程调用 | `dart:io` 的 `Process.run` | 调用 flutter create 命令 |
| 状态管理 | `Provider` | 轻量、适合中等复杂度应用 |
| 文件选择 | `file_picker` | 用于选择项目根目录 |
| 路径处理 | `path` 包 | 跨平台路径操作 |

## 项目结构

```
slipe/
├── lib/
│   ├── main.dart                      # 入口
│   ├── app.dart                       # MaterialApp 配置
│   ├── models/
│   │   ├── project.dart               # 项目模型
│   │   ├── file_node.dart             # 文件树节点
│   │   └── open_file.dart             # 已打开文件标签
│   ├── providers/
│   │   ├── project_provider.dart      # 项目状态管理
│   │   └── editor_provider.dart       # 编辑器标签页管理
│   ├── services/
│   │   ├── flutter_service.dart       # 调用 flutter create 命令
│   │   ├── file_service.dart          # 文件系统读写操作
│   │   └── syntax_service.dart        # Dart 语法高亮映射
│   ├── screens/
│   │   ├── home_screen.dart           # 主页：项目列表/打开项目
│   │   ├── create_project_screen.dart # 创建新项目表单
│   │   ├── editor_screen.dart         # 编辑器主界面（文件树+标签页+编辑区）
│   │   └── terminal_screen.dart       # 命令输出显示
│   └── widgets/
│       ├── file_tree.dart             # 文件树组件
│       ├── editor_tabs.dart           # 编辑器标签栏
│       ├── code_editor.dart            # 代码编辑器组件
│       └── dialogs.dart               # 通用对话框组件
├── pubspec.yaml
├── android/                           # Flutter 自动生成
└── README.md
```

## 实现步骤（按依赖顺序）

### 步骤 1：初始化 Flutter 项目
- 创建 Flutter 项目骨架（在 slipe 目录内执行 flutter create）
- 配置 `pubspec.yaml` 依赖：
  - `code_text_field: ^2.10.0`
  - `highlight: ^0.7.0`
  - `provider: ^6.1.0`
  - `file_picker: ^8.0.0`
  - `path: ^1.8.3`
  - `permission_handler: ^11.0.0`（Android 存储权限）
- 配置 Android `AndroidManifest.xml` 存储权限（READ_EXTERNAL_STORAGE, WRITE_EXTERNAL_STORAGE, MANAGE_EXTERNAL_STORAGE 对 Android 11+）

### 步骤 2：实现数据模型层
- `models/project.dart` - 项目信息（名称、路径、创建时间）
- `models/file_node.dart` - 文件树节点（名称、路径、类型、子节点）
- `models/open_file.dart` - 打开的文件（路径、内容、是否已修改）

### 步骤 3：实现服务层
- `services/flutter_service.dart`
  - `Future<ProcessResult> createProject(String projectName, String targetPath)` - 执行 `flutter create`
  - 解析 stdout/stderr 显示进度
- `services/file_service.dart`
  - `Stream<FileNode> loadDirectory(String path)` - 递归加载目录
  - `Future<String> readFile(String path)` - 读取文件内容
  - `Future<void> writeFile(String path, String content)` - 保存文件
  - `Future<void> createFile(String path, String name)` - 新建文件
  - `Future<void> createDirectory(String path, String name)` - 新建目录
  - `Future<void> deleteEntity(String path)` - 删除文件/目录
- `services/syntax_service.dart`
  - 使用 `highlight` 包的 Dart 语言定义
  - 构建 Dart 关键字/类型/字符串/注释的 TextStyle 映射
  - 提供 `TextEditingController` + `CodeController` 的集成

### 步骤 4：实现 Provider 状态管理
- `providers/project_provider.dart`
  - 当前项目路径
  - 文件树状态
  - 刷新文件树方法
- `providers/editor_provider.dart`
  - 已打开文件列表
  - 当前活跃文件
  - 打开/关闭/切换/保存文件方法

### 步骤 5：实现 UI 组件
- `widgets/code_editor.dart` - 基于 `code_text_field` + `highlight` 的语法高亮编辑器
- `widgets/file_tree.dart` - `ExpansionTile` 递归文件树，支持点击打开、右键菜单（新建/删除/重命名）
- `widgets/editor_tabs.dart` - 多标签页栏，显示已打开文件
- `widgets/dialogs.dart` - 新建文件/目录对话框、确认删除对话框

### 步骤 6：实现页面
- `screens/home_screen.dart` - 主页，显示最近项目列表 + "打开已有项目" + "创建新项目" 按钮
- `screens/create_project_screen.dart` - 项目名称输入、路径选择、模板选择（app/package/plugin），提交后显示命令执行进度
- `screens/editor_screen.dart` - 主编辑器界面：左侧文件树、右侧标签页+编辑区、底部状态栏
- `screens/terminal_screen.dart` - flutter create 等命令的实时输出显示

### 步骤 7：权限与存储适配
- Android 11+ 需要请求 `MANAGE_EXTERNAL_STORAGE` 权限才能访问外部存储
- 使用 `permission_handler` 处理动态权限请求
- 提示用户将应用加入"所有文件访问权限"白名单

### 步骤 8：组装与测试
- 在 `main.dart` 注册所有 Provider
- 实现简单的路由（Home → Create → Editor）
- 在真实 Android 设备上测试

## 关键依赖与考虑

### Android 存储权限（关键）
- **Android 10 (API 29)** 及以下：READ_EXTERNAL_STORAGE + WRITE_EXTERNAL_STORAGE
- **Android 11+ (API 30+)**：需要 MANAGE_EXTERNAL_STORAGE（"所有文件访问权限"）
- Flutter 应用默认只能访问自身沙盒目录，需要引导用户授权

### flutter create 参数
```bash
flutter create --org com.example --project-name my_app /target/path
```
需要指定目标路径（Android 上通常是 `/storage/emulated/0/` 或应用沙盒）

### code_text_field vs flutter_code_editor
选择 `code_text_field` 因为更轻量且社区成熟；`flutter_code_editor` 功能更多但包体积大。

### 文件监听
暂不实现文件外部变更监听（如热重载时），保存时直接写盘即可。

## 验证方法
1. `flutter analyze` 无 error/warning
2. `flutter run` 在 Android 设备上启动成功
3. 创建 Flutter 项目 → 检查磁盘上是否有完整生成的项目骨架
4. 打开文件 → 验证 Dart 代码语法高亮正确
5. 编辑并保存 → 用其他文件管理器打开文件确认内容已更新

## 风险与处理

| 风险 | 处理方案 |
|------|---------|
| Android 11+ 存储权限限制严格 | 在应用首次启动时请求 MANAGE_EXTERNAL_STORAGE，并提供设置引导 |
| flutter create 在 Android 上执行可能需要较长时间 | 显示实时进度输出 + 超时处理 |
| code_text_field 性能问题（大文件） | 对超过 1MB 的文件做只读提示，或限制加载大小 |
| Dart 3.x 新语法高亮不全 | highlight 包可能需要更新，预留 fallback 纯文本模式 |
| SDK 路径硬编码 | 将 flutter SDK 路径做成可配置项，默认尝试系统 PATH |

## 后续扩展（不在本次实现范围内）
- flutter run / build 命令执行
- 热重载支持
- Linter/Analyzer 错误提示
- Git 集成
- 多主题切换
- 插件市场
