[English](README.md) | 中文

# fizz

基于 Zig 的终端 UI 框架，遵循 Elm 架构（Model-Update-View），灵感来自 [Bubble Tea](https://github.com/charmbracelet/bubbletea)。

零外部依赖，纯 Zig 实现。适用于计数器、表单、列表、仪表盘、交互式工具等通用 TUI 场景。

## 特性

- Elm 架构：`Model.init` → `Model.update` → `Model.view`，comptime 契约校验
- 完整输入支持：ASCII、UTF-8、CSI、SS3、Kitty 键盘协议、SGR 鼠标
- 异步命令系统：单命令、批量并行、序列串行、定时器（`tick`/`every`）、外部进程
- 渲染优化：帧缓冲批量输出、View 差分渲染、BSU/ESU 同步（减少闪烁）
- 终端特性：Alt Screen、光标控制、OSC 52 剪贴板、括号粘贴、颜色配置（no_color → truecolor）
- 线程安全消息队列（128 槽环形缓冲区）
- 函数式配置选项（FPS、颜色、窗口大小、输入过滤等）
- SIGWINCH 窗口变化处理
- 支持 headless/测试模式（nil 渲染器）

## 快速开始

### 安装

**方式 A：zig fetch（推荐）**

```bash
zig fetch --save=fizz git+https://github.com/wsafight/fizz.git
```

`build.zig` 中接入：

```zig
const fizz_dep = b.dependency("fizz", .{
    .target = b.standardTargetOptions(.{}),
    .optimize = b.standardOptimizeOption(.{}),
});
app_module.addImport("fizz", fizz_dep.module("fizz"));
```

**方式 B：本地 vendor**

将 `src` 目录放入项目（如 `third_party/fizz/src`），在 `build.zig` 中注册模块：

```zig
const fizz_module = b.createModule(.{
    .root_source_file = b.path("third_party/fizz/src/fizz.zig"),
    .target = target,
    .optimize = optimize,
});
app_module.addImport("fizz", fizz_module);
```

### 最小示例

```zig
const std = @import("std");
const fizz = @import("fizz");

const Model = struct {
    count: i32 = 0,
    buf: [64]u8 = undefined,

    pub fn init(_: *Model) ?fizz.Cmd {
        return null;
    }

    pub fn update(self: *Model, m: fizz.Msg) ?fizz.Cmd {
        switch (m) {
            .key_press => |kp| {
                if (kp.code == .char and kp.char == 'q') return fizz.cmd.quit_cmd;
                if (kp.code == .char and kp.char == '+') self.count += 1;
                if (kp.code == .char and kp.char == '-') self.count -= 1;
            },
            else => {},
        }
        return null;
    }

    pub fn view(self: *Model) []const u8 {
        return std.fmt.bufPrint(&self.buf, "Count: {d}  (q=quit, +/- to change)", .{self.count}) catch "?";
    }
};

pub fn main() !void {
    var p = fizz.Program(Model).init(std.fs.File.stdout(), Model{});
    defer p.deinit();
    _ = try p.run();
}
```

## 核心概念

| 概念 | 说明 |
|------|------|
| `Program(ModelType)` | 运行时核心，管理事件循环、raw mode、线程、渲染 |
| `Msg` | 事件消息 tagged union（按键、鼠标、窗口变化、剪贴板、自定义等） |
| `Cmd` | 异步命令（`simple`/`batch`/`sequence`/`tick`/`every`/`exec`） |
| `View` | 渲染输出，包含文本内容与终端状态控制 |
| `OptionFn` | 函数式配置（`withFps`/`withColorProfile`/`withFilter` 等） |

### Model 契约

Model 需实现三个方法（comptime 校验）：

```zig
pub fn init(self: *Self) ?Cmd                // 初始化，可返回首条命令
pub fn update(self: *Self, msg: Msg) ?Cmd    // 处理事件，可返回后续命令
pub fn view(self: *Self) []const u8           // 渲染为字符串（或返回 View）
```

### 命令系统

```zig
fizz.cmd.quit_cmd                              // 退出
fizz.cmd.tick(ns_per_s, &callback)             // 单次定时
fizz.cmd.every(ns_per_s, &callback)            // 重复定时
fizz.cmd.batch(&.{ cmd_a, cmd_b })             // 并行执行
fizz.cmd.sequence(&.{ cmd_a, cmd_b })          // 串行执行
fizz.cmd.execProcess(argv)                     // 外部进程
fizz.cmd.setClipboard(content)                 // 系统剪贴板写入
fizz.cmd.setPrimaryClipboard(content)          // 主选区写入
fizz.cmd.clearScreen()                         // 清屏
```

## 项目结构

```
src/
├── fizz.zig              # 包入口，统一导出公开 API
├── model.zig             # comptime Model 契约验证
├── msg.zig               # Msg tagged union
├── cmd.zig               # Cmd tagged union
├── queue.zig             # 线程安全环形缓冲区
├── view.zig              # View 结构体
├── options.zig           # 函数式 ProgramOption
├── program/
│   ├── program.zig       # 事件循环、raw mode、公共 API
│   ├── commands.zig      # 命令执行：worker 池、batch、sequence、tick
│   ├── handlers.zig      # 消息处理、终端 I/O、渲染器管理
│   └── program_test.zig  # Program 集成测试
├── renderer/
│   ├── renderer.zig      # Renderer 接口（手动 vtable）
│   ├── cursed.zig        # 终端渲染器：帧缓冲、差分、同步输出
│   └── nil.zig           # 空渲染器（headless/测试）
├── input/
│   ├── key.zig           # 按键解析（ASCII/UTF-8/CSI/SS3/Kitty）
│   ├── mouse.zig         # SGR 鼠标事件解析
│   └── reader.zig        # 输入读取线程
├── platform/
│   ├── tty.zig           # Raw mode（termios）
│   └── signals.zig       # SIGWINCH + 终端尺寸查询
├── color.zig             # RgbColor + 感知亮度
├── cursor.zig            # 光标位置/形状/颜色
├── clipboard.zig         # OSC 52 剪贴板
├── paste.zig             # 括号粘贴
├── keyboard.zig          # Kitty 键盘增强
├── termcap.zig           # 终端能力查询
├── profile.zig           # 颜色配置文件
├── screen.zig            # WindowSize / ModeReport
├── focus.zig             # Focus/Blur
├── raw.zig               # 原始转义序列
├── environ.zig           # 环境变量快照
├── exec.zig              # 外部进程执行
├── logging.zig           # 文件日志
└── tests.zig             # 聚合测试入口
```

## 构建与测试

```bash
zig build              # 编译（Debug）
zig build run          # 运行 counter 示例
zig build test         # 运行全部单元测试
```

## 平台支持

目标 POSIX 系统（Linux、macOS），依赖 termios、SIGWINCH、pipe、poll。

## 参考

- [Bubble Tea](https://github.com/charmbracelet/bubbletea) — Go 语言 TUI 框架，fizz 的灵感来源
