# sherpa-onnx SenseVoice 端侧离线语音识别方案

## 1. 方案结论

当前输入法的端侧 ASR 路线固定为 sherpa-onnx SenseVoice 离线方案，模型文件直接内置在应用包内，不额外下载。

采用模型：

```text
sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17
```

当前实现采用 stop-only 模式：

1. 录音期间只采集并缓存整段语音。
2. 不在录音过程中做分段识别，也不做实时预览。
3. 用户点击停止后，对整段录音做一次离线识别。
4. 键盘区域只在停止录音后显示最终转写结果。

## 2. 内置资源

```text
entry/src/main/resources/rawfile/asr/
└── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/
    ├── manifest.json
    ├── model.int8.onnx
    ├── tokens.txt
    └── LICENSE
```

当前运行所需文件：

1. `model.int8.onnx`
2. `tokens.txt`

## 3. 运行链路

```text
KeyboardPanel
  -> SessionManager
  -> VoiceCaptureService
  -> SenseVoiceLocalAsrProvider
     -> PCM16 -> Float32
     -> 16k 线性重采样
     -> 全量缓存整段录音
     -> SenseVoice OfflineRecognizer
```

关键文件：

1. `entry/src/main/ets/ime/voice/SenseVoiceLocalAsrProvider.ets`
2. `entry/src/main/ets/ime/voice/SenseVoiceModelInstaller.ets`
3. `entry/src/main/ets/ime/voice/VoiceCaptureService.ets`

## 4. 识别流程

### 4.1 采集与重采样

`VoiceCaptureService` 负责麦克风采集和录音生命周期。

`localAsr.captureSampleRate` 默认请求 `16000`。如果设备实际回退到 `44100` 或 `48000`，`SenseVoiceLocalAsrProvider` 会先把 PCM16 转成 Float32，再在本地线性重采样到 `16000 Hz`，随后把整段音频持续缓存起来。

### 4.2 停止后统一识别

Provider 当前不做 VAD 分段，也不做实时 partial：

1. 开始录音时初始化 `OfflineRecognizer`。
2. 每次 `readData` 回调都把音频追加到当前会话缓冲区。
3. 点击停止时，把完整缓冲区一次性送入 SenseVoice。
4. 执行一次 `decode`，返回整段录音的最终文本。

## 5. 配置语义

`voice.asrProvider`：

| 值 | 行为 |
| --- | --- |
| `auto` | 优先端侧 SenseVoice；端侧不可用时再尝试系统内置 ASR；再降级远程/mock。 |
| `sensevoice_local` | 强制端侧 SenseVoice。 |
| `builtin` | 强制系统内置 ASR。 |
| `remote` | 强制远程 ASR。 |

`voice.localAsr` 当前仍保留原有结构，但 stop-only 实现实际使用的字段主要是：

```json
{
  "enabled": true,
  "provider": "sherpa-onnx",
  "modelId": "sense-voice-zh-en-ja-ko-yue-2024-07-17-int8",
  "source": "sensevoice_local",
  "language": ["zh", "en", "ja", "ko", "yue"],
  "captureSampleRate": 16000,
  "numThreads": 1,
  "lazyLoad": true,
  "releaseOnKeyboardHide": true,
  "decodingMethod": "greedy_search",
  "maxActivePaths": 4
}
```

兼容策略：

1. 旧配置中的 `zipformer_bilingual_local` 会在加载时自动归一为 `sensevoice_local`。
2. `partialEmitIntervalMs`、`endpoint` 等旧字段目前仅为兼容保留，stop-only 实现不再使用。
3. 运行时关闭“系统内置语音识别”后，会强制使用 `sensevoice_local`。

## 6. 当前行为边界

1. 录音过程中不会显示实时识别文本。
2. 识别结果只在点击停止后返回。
3. 录音越长，停止后的单次 decode 延迟越高，但识别上下文更完整。