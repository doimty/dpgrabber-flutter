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

构建：

```bash
flutter build apk --release
flutter build ios --release --no-codesign
flutter build windows --release
```

## CI

推 `main` 时触发 `.github/workflows/ci.yml`：analyze + test、APK、
未签名 IPA、Windows 构建，四者并行。

## 许可

暂无 license 文件。
