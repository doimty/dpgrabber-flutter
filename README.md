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

## 与原版（duopei-poller）的行为差异

协议层（登录端点/参数、AES-256-CBC 解密、randomList 轮询、confirm 确认、
20s 确认窗口、0.5s 重试、60s 去重 TTL、IP 风控 60s 冷却）与原版一致。
行为层差异（多为独立版的有意取舍）：

- **只做大厅单**：原版的指定单（assigned）全链路未移植（PC 独立版同样裁剪）。
- **多账号是切换式轮转**，不是原版的多线程并发抢单。
- **默认无确认前等待**：原版实测"确认无需先进页，空等只会推后首次确认"，
  因此 `confirm_wait_by_shop` 默认为空，发现订单立即确认（可按店铺自行配置）。
- **轮询间隔默认 0.6±0.2s**，比原版的 2–3s 更快（PC 竞品画像节奏），
  请求频率与风控暴露更高；求稳可把 `poll_interval_sec` 调回 2.0。
- **通知渠道更多且失败也推送**：serverchan / bark / pushplus / webhook，
  成功与失败/未知结果都会推送（对齐原版 notify_result），pending/skipped 静默。
- **token 不持久化**：每次启动重新登录（原版把 token 存文件实现冷启动免登录）。
- 额外能力：金额上限、备注黑白名单、商品类型过滤、busy 冷却、自动停止、
  语音播报、店员周统计、备用 AES 密钥、店员席位探测。

## CI

推 `main` 时触发 `.github/workflows/ci.yml`：analyze + test、APK、
未签名 IPA、Windows 构建，四者并行。

## 许可

暂无 license 文件。
