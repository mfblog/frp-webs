# Design System

## Direction

浅色优先的紧凑型运维控制台。界面使用稳定、熟悉的产品组件，不引入装饰性视觉效果。强调配置工作区、运行状态和日志排障之间的清晰层级。

## Color

使用现有蓝色作为唯一主强调色，并使用中性冷灰组织表面层级。

- `--color-bg`: `oklch(97.8% 0.006 255)`
- `--color-surface`: `oklch(100% 0 0)`
- `--color-surface-muted`: `oklch(96.2% 0.008 255)`
- `--color-border`: `oklch(88.5% 0.014 255)`
- `--color-ink`: `oklch(24% 0.025 255)`
- `--color-muted`: `oklch(45% 0.025 255)`
- `--color-primary`: `oklch(55% 0.2 257)`
- `--color-success`: `oklch(50% 0.12 170)`
- `--color-warning`: `oklch(62% 0.16 70)`
- `--color-danger`: `oklch(55% 0.2 25)`

## Typography

- UI 字体：`Inter, "PingFang SC", "Microsoft YaHei", system-ui, sans-serif`
- 配置和日志：`"SFMono-Regular", Consolas, "Liberation Mono", monospace`
- 标题采用 18–24px 的紧凑层级，不使用展示型大标题
- 正文 14px，辅助说明 12–13px，行高不低于 1.45

## Layout

- 顶部为紧凑状态栏，展示发现路径、版本和运行状态
- 桌面端主体使用约 `minmax(0, 7fr) minmax(280px, 3fr)` 双栏布局
- 左侧为配置编辑器，右侧为状态和服务操作
- 日志位于底部可调整高度区域，不使用模态弹窗
- 移动端切换为“配置 / 状态 / 日志”页签
- 所有 Flex/Grid 滚动子项必须设置 `min-height: 0` 和明确高度约束

## Components

- 按钮：主按钮仅用于保存并启动/重启；危险操作使用明确红色与文字标签
- 状态徽标：同时使用图标/文字与颜色表达状态
- 编辑器：保留原生文本编辑能力、等宽字体、未保存提示和 `Ctrl/Cmd+S`
- 日志面板：`overflow-y: auto`、`overscroll-behavior: contain`，支持自动跟随开关和跳到底部
- 消息：区分成功、警告、失败、冲突和加载状态，不使用阻塞式浏览器弹窗承载主要反馈

## Motion

- 仅使用 150–200ms 的状态过渡
- 禁止页面加载编排动画
- 尊重 `prefers-reduced-motion`

## Responsive behavior

- `>= 1024px`：配置与状态双栏，日志固定在底部
- `< 1024px`：单栏布局，状态区移至配置区下方
- `< 720px`：启用页签，操作按钮允许全宽排列，日志占满剩余视口

