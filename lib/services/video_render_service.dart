import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'resource_download_service.dart';
import 'video_editor_service.dart';

/// 一次导出的结果。
@immutable
class VideoRenderResult {
  const VideoRenderResult({
    required this.ok,
    required this.message,
    this.outputDir,
    this.outputFile,
    this.log = '',
  });

  final bool ok;
  final String message;

  /// 合成工程目录（index.html / project.json / render.sh）。
  final String? outputDir;

  /// 真实导出的成片（ffmpeg 可用且素材全为图片时）。
  final String? outputFile;

  final String log;
}

/// 视频导出服务：把时间线编排为可渲染的合成工程。
///
/// 流程：
/// 1. 在 `<项目根>/.vibevideo/build/` 写入 `project.json`、`index.html`
///    与 `render.sh`（自包含，可直接用 HyperFrames 或浏览器录制）。
/// 2. 若安装了 HyperFrames 内核，记录其路径供命令行渲染。
/// 3. 若本机有 ffmpeg 且素材全部为图片，直接合成 MP4。
class VideoRenderService {
  VideoRenderService._();

  static final VideoRenderService instance = VideoRenderService._();

  Future<VideoRenderResult> render(
    VideoProjectData project, {
    String? rootPath,
  }) async {
    final base = (rootPath != null && rootPath.trim().isNotEmpty)
        ? p.join(rootPath, '.vibevideo')
        : p.join(Directory.systemTemp.path, 'vibevideo');
    final buildDir = Directory(p.join(base, 'build'));
    try {
      await buildDir.create(recursive: true);
    } catch (e) {
      return VideoRenderResult(ok: false, message: '无法创建输出目录：$e');
    }

    final buffer = StringBuffer();
    try {
      final projectJson = const JsonEncoder.withIndent('  ').convert(
        project.toJson(),
      );
      await File(p.join(buildDir.path, 'project.json'))
          .writeAsString(projectJson);
      await File(p.join(buildDir.path, 'index.html'))
          .writeAsString(_buildHtml(project));
      buffer.writeln('已生成合成工程：${buildDir.path}');

      final hyperFrames = await _kernelPath('hyperframes');
      final blender = await _kernelPath('blender');
      if (hyperFrames != null) {
        buffer.writeln('HyperFrames 内核：$hyperFrames');
      }
      if (blender != null) {
        buffer.writeln('Blender 内核：$blender');
        final script = File(p.join(buildDir.path, 'blender_scene.py'));
        await script.writeAsString(_buildBlenderScript(project));
        buffer.writeln('已生成 Blender 场景脚本：${script.path}');
      }

      final renderScript = File(p.join(buildDir.path, 'render.sh'));
      await renderScript.writeAsString(_buildRenderScript(project, hyperFrames));
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', renderScript.path]);
      }
      buffer.writeln('渲染脚本：${renderScript.path}');

      // 素材全为图片时用 ffmpeg 直接出片。
      final imagesOnly = project.clips.isNotEmpty &&
          project.clips.every((clip) {
            final asset = project.assetOf(clip.assetId);
            return asset != null && asset.kind == VideoAssetKind.image;
          });
      if (imagesOnly && await _hasFfmpeg()) {
        final output = p.join(buildDir.path, 'output.mp4');
        final log = await _renderImagesWithFfmpeg(project, buildDir, output);
        if (await File(output).exists()) {
          buffer.writeln(log);
          return VideoRenderResult(
            ok: true,
            message: '已导出成片：$output',
            outputDir: buildDir.path,
            outputFile: output,
            log: buffer.toString(),
          );
        }
        buffer.writeln('ffmpeg 合成失败，已保留合成工程：$log');
      }

      return VideoRenderResult(
        ok: true,
        message: hyperFrames != null
            ? '已生成合成工程，可运行 render.sh 用 HyperFrames 渲染'
            : '已生成合成工程（未检测到 HyperFrames 内核，可在浏览器中预览/录制）',
        outputDir: buildDir.path,
        log: buffer.toString(),
      );
    } catch (e) {
      return VideoRenderResult(
        ok: false,
        message: '导出失败：$e',
        outputDir: buildDir.path,
        log: buffer.toString(),
      );
    }
  }

  Future<String?> _kernelPath(String id) async {
    try {
      return await ResourceDownloadService.instance.installPath(id);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasFfmpeg() async {
    try {
      final result = await Process.run('which', ['ffmpeg']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String> _renderImagesWithFfmpeg(
    VideoProjectData project,
    Directory buildDir,
    String output,
  ) async {
    final listFile = File(p.join(buildDir.path, 'concat.txt'));
    final lines = StringBuffer();
    for (final clip in project.clips) {
      final asset = project.assetOf(clip.assetId);
      if (asset == null) continue;
      final safe = asset.path.replaceAll("'", "'\\''");
      lines.writeln("file '$safe'");
      lines.writeln('duration ${clip.duration.toStringAsFixed(3)}');
    }
    // concat 需要最后一张重复一次来撑满最后一帧
    final last = project.clips.isEmpty
        ? null
        : project.assetOf(project.clips.last.assetId);
    if (last != null) {
      final safe = last.path.replaceAll("'", "'\\''");
      lines.writeln("file '$safe'");
    }
    await listFile.writeAsString(lines.toString());

    final result = await Process.run('ffmpeg', [
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listFile.path,
      '-vsync',
      'vfr',
      '-vf',
      'scale=${project.width}:${project.height}:force_original_aspect_ratio=decrease,'
          'pad=${project.width}:${project.height}:(ow-iw)/2:(oh-ih)/2:color=0x0A0A0C',
      '-pix_fmt',
      'yuv420p',
      '-r',
      project.fps.toStringAsFixed(0),
      output,
    ]);
    final log = '${result.stdout}\n${result.stderr}';
    return log.length > 1500 ? log.substring(log.length - 1500) : log;
  }

  String _buildRenderScript(VideoProjectData project, String? hyperFrames) {
    final duration = project.totalDuration.toStringAsFixed(2);
    final hf = hyperFrames == null ? '' : '''
if [ -d "$hyperFrames" ]; then
  echo "[HyperFrames] 内核目录：$hyperFrames"
  if command -v npx >/dev/null 2>&1; then
    ( cd "$hyperFrames" && npx hyperframes render "\$PWD/index.html" -o "\$PWD/output.mp4" --duration $duration ) && exit 0
  fi
fi
''';
    return '''#!/usr/bin/env bash
# 由 SLIPE VibeVideo 自动生成。
set -e
cd "\$(dirname "\$0")"
DURATION=$duration
$hf
echo "未检测到可用的 HyperFrames 渲染器。"
echo "你可以在浏览器中打开 index.html 预览，或用录制工具导出。"
echo "若能联网，可执行：npx hyperframes render index.html -o output.mp4 --duration \$DURATION"
''';
  }

  String _buildHtml(VideoProjectData project) {
    final data = jsonEncode({
      'name': project.name,
      'width': project.width,
      'height': project.height,
      'fps': project.fps,
      'background': project.background,
      'clips': [
        for (final clip in project.clips)
          {
            'title': clip.title,
            'text': clip.text,
            'duration': clip.duration,
            'transition': clip.transition,
            'asset': project.assetOf(clip.assetId)?.path ?? '',
            'kind': project.assetOf(clip.assetId)?.kind.name ?? 'text',
          },
      ],
    });
    return '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<title>${_escapeHtml(project.name)} · VibeVideo</title>
<style>
  html,body{margin:0;height:100%;background:${_cssBackground(project.background)};overflow:hidden;
    font-family:Inter,system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;}
  #stage{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;overflow:hidden;}
  .clip{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
    opacity:0;transition:opacity .5s ease, transform .5s ease;}
  .clip.active{opacity:1;}
  .clip.fade{opacity:0;}
  .clip.slide{transform:translateX(6%);}
  .clip.zoom{transform:scale(1.06);}
  .clip img,.clip video{width:100%;height:100%;object-fit:contain;}
  .caption{position:absolute;left:6%;bottom:8%;max-width:80%;color:#fff;
    text-shadow:0 2px 18px rgba(0,0,0,.6);}
  .caption h1{font-size:clamp(28px,5vw,72px);margin:0 0 .25em;letter-spacing:.02em;}
  .caption p{font-size:clamp(14px,2vw,26px);margin:0;opacity:.82;line-height:1.5;}
  .empty{color:rgba(255,255,255,.5);font-size:18px;}
</style>
</head>
<body>
<div id="stage"><div class="empty">（尚无片段，请在 VibeVideo 中添加素材）</div></div>
<script>
const PROJECT = $data;
const stage = document.getElementById('stage');
const clips = PROJECT.clips || [];
let index = 0, playing = true, timer = null;

function build() {
  stage.innerHTML = '';
  clips.forEach((clip, i) => {
    const el = document.createElement('div');
    el.className = 'clip';
    if (clip.transition) el.classList.add(clip.transition);
    if (clip.kind === 'image' && clip.asset) {
      const img = document.createElement('img');
      img.src = 'file://' + clip.asset;
      el.appendChild(img);
    } else if (clip.kind === 'video' && clip.asset) {
      const v = document.createElement('video');
      v.src = 'file://' + clip.asset; v.muted = true; v.loop = true;
      el.appendChild(v);
    }
    if (clip.title || clip.text) {
      const cap = document.createElement('div');
      cap.className = 'caption';
      cap.innerHTML = '<h1>' + escapeHtml(clip.title || '') + '</h1>' +
        '<p>' + escapeHtml(clip.text || '') + '</p>';
      el.appendChild(cap);
    }
    stage.appendChild(el);
  });
  if (clips.length) play(0);
}

function escapeHtml(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}

function play(i) {
  clearTimeout(timer);
  const nodes = [...stage.querySelectorAll('.clip')];
  if (!nodes.length) return;
  nodes.forEach(n => n.classList.remove('active'));
  index = (i + nodes.length) % nodes.length;
  const node = nodes[index];
  node.classList.add('active');
  const clip = clips[index];
  const video = node.querySelector('video');
  if (video) { video.currentTime = 0; video.play().catch(() => {}); }
  if (playing && clip) timer = setTimeout(() => play(index + 1), (clip.duration || 4) * 1000);
}

window.addEventListener('keydown', e => {
  if (e.code === 'Space') { playing = !playing; if (playing) play(index); else clearTimeout(timer); }
  if (e.code === 'ArrowRight') play(index + 1);
  if (e.code === 'ArrowLeft') play(index - 1);
});
build();
</script>
</body>
</html>''';
  }

  String _buildBlenderScript(VideoProjectData project) {
    final frames = <String>[];
    var start = 1;
    for (final clip in project.clips) {
      final asset = project.assetOf(clip.assetId);
      if (asset == null || asset.kind != VideoAssetKind.image) continue;
      final end = start + (clip.duration * project.fps).round();
      frames.add(
        '    ("${asset.path.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}", '
        '$start, $end),',
      );
      start = end;
    }
    return '''# 由 SLIPE VibeVideo 生成的 Blender 场景脚本（图片素材转 3D 平面）。
# 用法：blender --background --python blender_scene.py
import bpy

WIDTH, HEIGHT = ${project.width}, ${project.height}
FPS = ${project.fps.toStringAsFixed(0)}
# (图片路径, 起始帧, 结束帧)
SEQUENCES = [
${frames.join('\n')}
]

scene = bpy.context.scene
scene.render.resolution_x = WIDTH
scene.render.resolution_y = HEIGHT
scene.render.fps = FPS
scene.render.image_settings.file_format = 'PNG'

for i, (path, start, end) in enumerate(SEQUENCES):
    img = bpy.data.images.load(path, check_existing=True)
    mat = bpy.data.materials.new(name=f"vibe_mat_{i}")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    tex = nodes.new('ShaderNodeTexImage')
    tex.image = img
    nodes.get('Principled BSDF').inputs['Base Color'].default_value = (1, 1, 1, 1)
    mat.node_tree.links.new(tex.outputs['Color'], nodes.get('Principled BSDF').inputs['Base Color'])
    bpy.ops.mesh.primitive_plane_add(size=2)
    plane = bpy.context.object
    plane.data.materials.append(mat)
    plane.hide_render = False
    plane.hide_viewport = True
    plane.keyframe_insert('hide_render', frame=start)
    plane.hide_render = True
    plane.keyframe_insert('hide_render', frame=end)

scene.frame_end = int(${project.totalDuration.toStringAsFixed(2)} * FPS)
scene.camera.data.type = 'ORTHO'
''';
  }

  static String _cssBackground(String color) {
    final value = color.trim();
    if (RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(value)) {
      return value.startsWith('#') ? value : '#$value';
    }
    return '#0A0A0C';
  }

  static String _escapeHtml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
