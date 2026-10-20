# UI 改造 · 2026-10-20

## 本轮实现

- 以 pipa_A.jpg 为参考，通过图像编辑生成透明琴身素材，移除布景和松弛琴弦。原图保留，衍生素材位于 App/Assets.xcassets/PipaInstrument.imageset/pipa.png。
- 暖纸色背景、墨色文字、朱砂色状态及浅金色细节；五个技法按钮保留。
- 图片、琴弦、选中标记及命中检测统一使用素材坐标和等比缩放。相品视觉位置按素材标定，不再用音高公式推测图片中的位置。
- 头部和琴身外不触发音符；最后一品以下为开放弦演奏区。
- 音色、音量和技法速度放入演奏设置。新增音位面板，提供 4 × 32 个大触点，方便手机高把位演奏及 VoiceOver 使用。
- 横屏采用琴身与控制区并排布局。减少动态效果时停用弦振位移。
- 未改变 DSP 核心和音源。素材是基于实物照片生成的衍生图，不是原始照片的像素级复刻。

## 验证

- iOS Simulator Debug 构建通过（arm64 / x86_64）。
- iPhone 17 Pro 与 iPad mini (A17 Pro) 模拟器均已启动并截图检查，截图位于 UIPreviews/。
- Scripts/verify-ui-geometry.swift 检查四种尺寸的 512 个弦／音位中心命中，以及等比缩放、边界排除和空弦区映射，全部通过。
- 自动界面控制连接超时，尚未完成所有按钮的端到端自动点击验证；应继续在真机验证触感、多次技法触发和横屏交互。

复现坐标检查：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -module-cache-path /tmp/pipa-swift-cache Core/PipaTuning.swift App/PipaGeometry.swift Scripts/verify-ui-geometry.swift -o /tmp/pipa-geometry-check
/tmp/pipa-geometry-check
```

本目录未检测到 Git 仓库，改造前的四个 UI 源文件与工程配置已保存到 UIBackups/。
