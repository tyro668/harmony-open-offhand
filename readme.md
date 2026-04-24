# 鸿蒙原生的智能语音输入法

## ONNX 模型文件说明

由于 GitHub 对单个文件有 **100 MB** 的大小限制，以下 ONNX 模型文件**未被提交到本仓库**。在构建或运行本项目前，你需要手动下载并放置到对应目录。

### 需要手动下载的文件

| 文件 | 大小 | 放置路径 |
|------|------|----------|
| `model.int8.onnx` | ~228 MB | `entry/src/main/resources/rawfile/asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/model.int8.onnx` |
| `silero_vad.onnx` | ~644 KB | `entry/src/main/resources/rawfile/asr/silero_vad.onnx` |

### 一键下载脚本

在项目根目录执行以下命令：

```bash
# 1. 下载 SenseVoice 模型
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
tar xvf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
mkdir -p entry/src/main/resources/rawfile/asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17
cp sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/model.int8.onnx \
   entry/src/main/resources/rawfile/asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/
rm -rf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2 sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17

# 2. 下载 Silero VAD 模型
wget -P entry/src/main/resources/rawfile/asr \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
```

### 模型来源

- **SenseVoice** 模型转换自 [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice)，通过 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 导出为 ONNX 格式。
- **Silero VAD** 模型来自 [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx)。

> **提示**：`.gitignore` 中已配置 `*.onnx`，下载完成后请勿尝试将这些模型文件再次提交到 Git。
