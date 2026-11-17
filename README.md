# dpgrabber-flutter

多陪抢单 Flutter 三端合一：Android / iOS / Windows 共用一套 Dart 代码。

由 [dpgrabber-standalone](https://github.com/doimty/dpgrabber-standalone)
的三个原生端（PC PySide6 / Android Kotlin / iOS Swift）重写而来，
协议与行为以 `dpgrabber-standalone` 的 `PROTOCOL.md` 为准。

## 平台

| 平台 | 最低版本 | 包名 / 产物 |
|---|---|---|
| Android | minSdk 24 | `com.doimty.dpgrabber`，APK |
| iOS | 15.0 | 未签名 IPA（自行重签） |
| Windows | 10 | exe + 依赖 |

## 开发

需要 Flutter 3.47.9 stable（与 CI 钉死同一版本）。

```bash
flutter pub get
flutter analyze
flutter test
```

## UI（移植自 wenxi）

UI 基建移植自 [z7786/wenxi](https://github.com/z7786/wenxi)（文析助手），
位于 `lib/wenxi_ui/`：

| 文件 | 来源 | 说明 |
|---|---|---|
| `appearance.dart` | wenxi `domain/appearance.dart` | 色板 / 玻璃风格（`WenxiPalette` 改为 class，`wenxiPaletteFor` 把 dpgrabber 六主题适配进 wenxi 管线） |
| `app_theme.dart` | wenxi `ui/app_theme.dart` | `appTheme()` + `AppAppearance` ThemeExtension |
| `liquid_glass.dart` | wenxi `ui/liquid_glass.dart` | 液态玻璃（fragment shader 折射）+ `LiquidGlassButton` |
| `liquid_bottom_navigation.dart` | wenxi `ui/liquid_bottom_navigation.dart` | 弹簧动画液态底栏（SVG 换 Material 图标，去掉传输角标） |
| `app_navigation.dart` | wenxi `ui/app_navigation.dart` | 88px 玻璃侧栏 + 液态底栏（多陪抢单三目的地） |
| `app_switch.dart` / `loading_indicator.dart` / `app_text_scale.dart` / `desktop_mouse_back.dart` / `skeleton_loading.dart` / `theme_reveal.dart` | wenxi 同名文件 | 通用组件；`theme_reveal` 去掉了 Android 原生截屏通道 |

接线：`main.dart` 用 `appTheme()` 构建 MaterialApp（dpgrabber 主题 id
与玻璃档位仍由 `AppState` 持有并映射），`ui/navigation.dart` 的
`AppShell` 使用 `AppNavigation`。页面内自绘颜色仍走 `theme/palette.dart`
（PORTING_CONTRACT §9 的 36 键）。

液态玻璃 shader 来自 wenxi（`assets/shaders/liquid_glass.frag`，源自
Kyant 的 AndroidLiquidGlass / Backdrop，Apache-2.0，见
`assets/licenses/AndroidLiquidGlass-LICENSE.txt`）。

构建：

```bash
flutter build apk --release
flutter build ios --release --no-codesign
flutter build windows --release
```

## 与 DPPP（PC 版）的行为差异

dpgrabber-flutter 的登录、轮询、筛选、确认与通知逻辑对齐 DPPP
（`doimty/dpgrabber-standalone` 的 PC 端，源码 `pc/`）：同一套端点与
AES-256-CBC 解密、默认参数逐键一致（`poll_interval_sec=0.6±0.2`、
`confirm_wait_by_shop={92:5.0, 50/105/1391:3.0}`）、通知仍然只在抢到
订单时推送（serverchan / bark / pushplus / webhook），token 均不落盘、
每次启动重新登录。

真实差异只有两点：

- **多账号是切换式轮转**（定时切到下一个账号配置），不是 DPPP 的
  多线程并发抢单。
- **三端合一**：DPPP 是 Windows 桌面程序；Flutter 版用同一份 Dart
  代码跑 Android / iOS / Windows，UI 移植自 wenxi。

协议细节以 dpgrabber-standalone 的 `PROTOCOL.md` 为准。

## CI

推 `main` 时触发 `.github/workflows/ci.yml`：analyze + test、APK、
未签名 IPA、Windows 构建，四者并行。

## 许可

暂无 license 文件。
