import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';
import { OffhandRuntimeSettings } from '../ime/common/ImeTypes';
import { cloneRuntimeSettings, createDefaultRuntimeSettings, OffhandSettingsStore } from '../settings/OffhandSettingsStore';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';

@Entry
@Component
struct Index {
  @State private loaded: boolean = false;
  @State private saveStatus: string = 'Loading local settings...';
  @State private microphonePermissionStatus: string = 'Checking microphone permission...';
  @State private enablePreviewText: boolean = true;
  @State private enableVoice: boolean = true;
  @State private enableCloudPolish: boolean = true;
  @State private enablePersonalization: boolean = true;
  @State private autoInsertVoiceResult: boolean = false;
  @State private autoPolishVoiceResult: boolean = true;
  @State private asrEndpoint: string = '';
  @State private llmEndpoint: string = '';
  @State private llmStyle: string = 'clean_conversational';
  @State private validationPlainText: string = '';
  @State private validationEmailText: string = '';
  @State private validationUrlText: string = '';
  @State private validationPolishText: string = '';
  private readonly settingsStore: OffhandSettingsStore = new OffhandSettingsStore();
  private readonly atManager = abilityAccessCtrl.createAtManager();

  aboutToAppear(): void {
    void this.loadSettings();
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.renderHero();
        this.renderToggleSection();
        this.renderEndpointSection();
        this.renderActionSection();
        this.renderLiveValidationSection();
        this.renderDiagnosticsSection();
      }
      .padding(20)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F6F8')
  }

  @Builder
  private renderHero() {
    Column({ space: 8 }) {
      Text('Offhand IME Settings')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#101418')
        .width('100%')
        .textAlign(TextAlign.Start)

      Text('M5 本地设置与持久化已经接入。这里保存的配置会在输入法扩展下一次 inputStart 时自动生效。')
        .fontSize(14)
        .fontColor('#486581')
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(this.saveStatus)
        .fontSize(12)
        .fontColor(this.loaded ? '#0F766E' : '#7C2D12')
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderToggleSection() {
    Column({ space: 10 }) {
      this.renderSectionTitle('Feature Toggles', '本地设置会写入 preferences，并覆盖 rawfile 默认配置。')
      this.renderToggleRow('Preview Text', '组合态是否同步到宿主预览态', this.enablePreviewText, (): void => {
        this.enablePreviewText = !this.enablePreviewText;
      })
      this.renderToggleRow('Voice Input', '是否允许输入法侧语音入口', this.enableVoice, (): void => {
        this.enableVoice = !this.enableVoice;
      })
      this.renderToggleRow('Cloud Polish', '是否启用云端润色能力', this.enableCloudPolish, (): void => {
        this.enableCloudPolish = !this.enableCloudPolish;
      })
      this.renderToggleRow('Personalization', '是否允许个性化学习与用户词频积累', this.enablePersonalization, (): void => {
        this.enablePersonalization = !this.enablePersonalization;
      })
      this.renderToggleRow('Auto Polish Voice', '语音结束后是否自动请求润色建议', this.autoPolishVoiceResult, (): void => {
        this.autoPolishVoiceResult = !this.autoPolishVoiceResult;
      })
    }
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }

  @Builder
  private renderEndpointSection() {
    Column({ space: 12 }) {
      this.renderSectionTitle('Endpoints', '这里可以配置 ASR 与 LLM 的联调地址。留空时继续走本地 mock / fallback。')

      this.renderInputBlock('ASR Endpoint', 'https://asr.example.com/v1/transcribe', this.asrEndpoint,
        (value: string): void => {
          this.asrEndpoint = value;
        })

      this.renderInputBlock('LLM Endpoint', 'https://llm.example.com/v1/polish', this.llmEndpoint,
        (value: string): void => {
          this.llmEndpoint = value;
        })

      this.renderInputBlock('LLM Style', 'clean_conversational', this.llmStyle,
        (value: string): void => {
          this.llmStyle = value;
        })
    }
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }

  @Builder
  private renderActionSection() {
    Column({ space: 12 }) {
      this.renderSectionTitle('Actions', '保存后重新进入输入框即可看到新配置生效。')

      Row({ space: 10 }) {
        Button('Save Settings')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor('#0B6BCB')
          .borderRadius(14)
          .onClick(() => {
            void this.saveSettings();
          })

        Button('Reset Defaults')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor('#243B53')
          .backgroundColor('#D9E2EC')
          .borderRadius(14)
          .onClick(() => {
            void this.resetSettings();
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        Button('Grant Microphone')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor('#0F766E')
          .borderRadius(14)
          .onClick(() => {
            void this.requestMicrophonePermission();
          })

        Button('Refresh Permission')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor('#243B53')
          .backgroundColor('#D9E2EC')
          .borderRadius(14)
          .onClick(() => {
            void this.refreshMicrophonePermissionStatus();
          })
      }
      .width('100%')

      Text(this.microphonePermissionStatus)
        .fontSize(12)
        .fontColor('#334E68')
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }

  @Builder
  private renderLiveValidationSection() {
    Column({ space: 12 }) {
      this.renderSectionTitle('Live Validation',
        '这里提供普通、邮箱、URL 三种真实输入框。切到 Offhand 输入法后，可直接在真机上验证普通输入、邮箱/URL 场景、语音权限和润色建议。')

      this.renderValidationInputBlock('Plain Text Field', '在这里测试拼音、预览态、删除回退与语音/润色',
        this.validationPlainText, InputType.Normal, (value: string): void => {
          this.validationPlainText = value;
        })

      this.renderValidationInputBlock('Email Field', 'name@example.com',
        this.validationEmailText, InputType.Email, (value: string): void => {
          this.validationEmailText = value;
        })

      this.renderValidationInputBlock('URL Field', 'https://example.com',
        this.validationUrlText, InputType.URL, (value: string): void => {
          this.validationUrlText = value;
        })

      this.renderValidationInputBlock('Polish Text Field', '在这里输入一段口语化文本，然后点键盘上的 Polish',
        this.validationPolishText, InputType.Normal, (value: string): void => {
          this.validationPolishText = value;
        })
    }
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }

  @Builder
  private renderDiagnosticsSection() {
    Column({ space: 10 }) {
      this.renderSectionTitle('Device Validation', '当前代码已经具备真机联调入口，建议按下面顺序验证。')

      this.renderChecklistItem('1. 安装 HAP 到设备后，先进入 App 保存一次设置，再点 Grant Microphone 预先授权。')
      this.renderChecklistItem('2. 在普通文本框验证：拼音候选、英文候选、预览态、删除回退。')
      this.renderChecklistItem('3. 在邮箱或 URL 输入框验证：自动切英文候选，语音结果先进入键盘上方草稿区，再手动点插入。')
      this.renderChecklistItem('4. 如果输入法侧仍提示 denied，先回到 App 点 Refresh Permission，确认前台授权是否真正生效。')
      this.renderChecklistItem('5. 打开 Auto Polish Voice 后，验证语音结束后展示 Suggestion / Apply / Keep / Undo，且草稿不直接上屏。')
    }
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }

  @Builder
  private renderSectionTitle(title: string, description: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#101418')
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(description)
        .fontSize(12)
        .fontColor('#52606D')
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderToggleRow(title: string, description: string, enabled: boolean, action: () => void) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#102A43')
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(description)
          .fontSize(12)
          .fontColor('#52606D')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(enabled ? 'On' : 'Off')
        .width(76)
        .height(34)
        .fontSize(13)
        .fontColor(enabled ? '#FFFFFF' : '#243B53')
        .backgroundColor(enabled ? '#0F766E' : '#D9E2EC')
        .borderRadius(999)
        .onClick(() => {
          action();
        })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8FAFC')
    .borderRadius(16)
  }

  @Builder
  private renderInputBlock(title: string, placeholder: string, value: string, onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#102A43')
        .width('100%')
        .textAlign(TextAlign.Start)

      TextInput({ text: value, placeholder: placeholder })
        .width('100%')
        .height(44)
        .fontSize(13)
        .backgroundColor('#F8FAFC')
        .borderRadius(14)
        .padding({ left: 12, right: 12 })
        .onChange((nextValue: string): void => {
          onChange(nextValue);
        })
    }
    .width('100%')
  }

  @Builder
  private renderValidationInputBlock(title: string, placeholder: string, value: string, inputType: InputType,
    onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#102A43')
        .width('100%')
        .textAlign(TextAlign.Start)

      TextInput({ text: value, placeholder: placeholder })
        .type(inputType)
        .width('100%')
        .height(48)
        .fontSize(14)
        .backgroundColor('#F8FAFC')
        .borderRadius(14)
        .padding({ left: 12, right: 12 })
        .onChange((nextValue: string): void => {
          onChange(nextValue);
        })
    }
    .width('100%')
  }

  @Builder
  private renderChecklistItem(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#334E68')
      .width('100%')
      .textAlign(TextAlign.Start)
  }

  private async loadSettings(): Promise<void> {
    let hostContext = this.resolveHostContext();
    if (!hostContext) {
      this.loaded = false;
      this.saveStatus = 'UI host context unavailable';
      this.microphonePermissionStatus = 'Microphone permission unavailable: host context missing';
      return;
    }
    let settings = await this.settingsStore.load(hostContext);
    this.applySettings(settings);
    this.loaded = true;
    this.saveStatus = 'Local settings loaded';
    await this.refreshMicrophonePermissionStatus(hostContext);
  }

  private async saveSettings(): Promise<void> {
    let hostContext = this.resolveHostContext();
    if (!hostContext) {
      this.loaded = false;
      this.saveStatus = 'Unable to save: host context unavailable';
      return;
    }
    await this.settingsStore.save(hostContext, this.buildSettings());
    this.loaded = true;
    this.saveStatus = 'Settings saved. Re-enter a text field to refresh IME runtime config.';
  }

  private async resetSettings(): Promise<void> {
    let hostContext = this.resolveHostContext();
    if (!hostContext) {
      this.loaded = false;
      this.saveStatus = 'Unable to reset: host context unavailable';
      return;
    }
    let settings = await this.settingsStore.reset(hostContext);
    this.applySettings(settings);
    this.loaded = true;
    this.saveStatus = 'Settings reset to defaults';
  }

  private applySettings(settings: OffhandRuntimeSettings): void {
    let next = cloneRuntimeSettings(settings);
    this.enablePreviewText = next.enablePreviewText;
    this.enableVoice = next.enableVoice;
    this.enableCloudPolish = next.enableCloudPolish;
    this.enablePersonalization = next.enablePersonalization;
    this.autoInsertVoiceResult = next.autoInsertVoiceResult;
    this.autoPolishVoiceResult = next.autoPolishVoiceResult;
    this.asrEndpoint = next.asrEndpoint;
    this.llmEndpoint = next.llmEndpoint;
    this.llmStyle = next.llmStyle;
  }

  private buildSettings(): OffhandRuntimeSettings {
    return {
      enablePreviewText: this.enablePreviewText,
      enableVoice: this.enableVoice,
      enableCloudPolish: this.enableCloudPolish,
      enablePersonalization: this.enablePersonalization,
      autoInsertVoiceResult: this.autoInsertVoiceResult,
      autoPolishVoiceResult: this.autoPolishVoiceResult,
      asrEndpoint: this.asrEndpoint.trim(),
      llmEndpoint: this.llmEndpoint.trim(),
      llmStyle: this.llmStyle.trim().length > 0 ? this.llmStyle.trim() : createDefaultRuntimeSettings().llmStyle
    };
  }

  private async requestMicrophonePermission(): Promise<void> {
    let hostContext = this.resolveHostContext() as common.UIAbilityContext | undefined;
    if (!hostContext) {
      this.microphonePermissionStatus = 'Microphone permission request unavailable: host context missing';
      return;
    }
    this.microphonePermissionStatus = 'Requesting microphone permission...';
    try {
      let result = await this.atManager.requestPermissionsFromUser(hostContext, [MICROPHONE_PERMISSION]);
      let granted = result.authResults.some((value: number): boolean => {
        return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      });
      this.microphonePermissionStatus = granted ?
        'Microphone permission granted in EntryAbility' :
        'Microphone permission denied in EntryAbility';
    } catch (_) {
      this.microphonePermissionStatus = 'Microphone permission request failed';
    }
    await this.refreshMicrophonePermissionStatus(hostContext);
  }

  private async refreshMicrophonePermissionStatus(context?: common.Context): Promise<void> {
    let hostContext = context ?? this.resolveHostContext();
    if (!hostContext) {
      this.microphonePermissionStatus = 'Microphone permission unavailable: host context missing';
      return;
    }
    try {
      let grantStatus = this.atManager.checkAccessTokenSync(
        hostContext.applicationInfo.accessTokenId,
        MICROPHONE_PERMISSION
      );
      this.microphonePermissionStatus = grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ?
        'Microphone permission is granted' :
        'Microphone permission is not granted';
    } catch (_) {
      this.microphonePermissionStatus = 'Microphone permission status unavailable';
    }
  }

  private resolveHostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext() as common.Context | undefined;
  }
}
