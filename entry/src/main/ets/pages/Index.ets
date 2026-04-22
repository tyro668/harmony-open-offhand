import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BuiltinModelPreset, BuiltinModelProvider, OffhandRuntimeSettings } from '../ime/common/ImeTypes';
import {
  getDefaultBuiltinModelSelection,
  listBuiltinModelProviders,
  resolveBuiltinModelSelection
} from '../ime/config/BuiltinModels';
import { cloneRuntimeSettings, createDefaultRuntimeSettings, OffhandSettingsStore } from '../settings/OffhandSettingsStore';

const SETTINGS_LOG_DOMAIN: number = 0xFF10;
const SETTINGS_LOG_TAG: string = 'OffhandSettingsPage';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';
const DEFAULT_MODEL_SELECTION = getDefaultBuiltinModelSelection();
const BUILTIN_MODEL_PROVIDERS = listBuiltinModelProviders();

const PAGE_BACKGROUND = '#F4F7FB';
const CARD_BACKGROUND = '#FFFFFF';
const CARD_BORDER = '#E7EDF5';
const CARD_SHADOW: ShadowOptions = {
  radius: 10,
  color: '#140A2540',
  offsetX: 0,
  offsetY: 6
};
const ICON_BADGE_BACKGROUND = '#ECFBF9';
const PRIMARY_BLUE = '#1976F3';
const SOFT_GRAY = '#EEF3F8';
const TEXT_PRIMARY = '#121826';
const TEXT_SECONDARY = '#667085';
const TEXT_MUTED = '#96A0AE';
const DIVIDER_COLOR = '#EEF2F6';
const SUCCESS_GREEN = '#19A79C';
const ERROR_ORANGE = '#C46B29';

@Entry
@Component
struct Index {
  @State private loaded: boolean = false;
  @State private saveStatus: string = '加载中';
  @State private microphonePermissionStatus: string = '检查中';
  @State private enablePreviewText: boolean = true;
  @State private enableVoice: boolean = true;
  @State private enableCloudPolish: boolean = true;
  @State private enablePersonalization: boolean = true;
  @State private autoInsertVoiceResult: boolean = false;
  @State private autoPolishVoiceResult: boolean = true;
  @State private asrEndpoint: string = '';
  @State private llmProviderId: string = DEFAULT_MODEL_SELECTION.provider.providerId;
  @State private llmPresetId: string = DEFAULT_MODEL_SELECTION.preset.presetId;
  @State private availableModelPresetIds: string[] = DEFAULT_MODEL_SELECTION.provider.models.map(
    (preset: BuiltinModelPreset): string => preset.presetId
  );
  @State private llmApiKey: string = '';
  @State private llmStyle: string = 'clean_conversational';
  @State private defaultEntryMode: string = 'keyboard';
  private readonly settingsStore: OffhandSettingsStore = new OffhandSettingsStore();
  private readonly atManager = abilityAccessCtrl.createAtManager();
  private readonly builtinProviders: BuiltinModelProvider[] = BUILTIN_MODEL_PROVIDERS;
  private pendingSave: Promise<void> = Promise.resolve();

  aboutToAppear(): void {
    void this.loadSettings();
  }

  aboutToDisappear(): void {
    // Flush any pending auto-save plus the latest in-memory state before the
    // page is torn down so back-navigation never drops the most recent edit
    // (API key / provider / model).
    this.commitSettingsChange();
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        this.renderHeader()
        this.renderInputCard()
        this.renderModelCard()
        this.renderPermissionCard()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BACKGROUND)
  }

  @Builder
  private renderHeader() {
    Column({ space: 10 }) {
      Row() {
        this.renderBackIndicator()
        Blank()
        this.renderHeaderTitle()
        Blank()
        Column()
          .width(44)
          .height(44)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Column()
          .width(12)
          .height(12)
          .borderRadius(6)
          .backgroundColor(this.resolveHeaderStatusColor())

        Text(this.saveStatus)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.resolveHeaderStatusColor())
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 4, bottom: 2 })
  }

  @Builder
  private renderBackIndicator() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .backgroundColor('rgba(255,255,255,0.72)')
  }

  @Builder
  private renderHeaderTitle() {
    Column({ space: 0 }) {
      Text('Offhand 输入法')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .layoutWeight(1)
  }

  @Builder
  private renderInputCard() {
    Column({ space: 0 }) {
      this.renderCardHeader('section-input', '输入设置')
      this.renderToggleSettingRow('voice', '语音输入', this.enableVoice, (): void => {
        this.enableVoice = !this.enableVoice;
        this.commitSettingsChange();
      })
      this.renderToggleSettingRow('polish', '文本润色', this.enableCloudPolish, (): void => {
        this.enableCloudPolish = !this.enableCloudPolish;
        this.commitSettingsChange();
      })
      this.renderToggleSettingRow('magic', '语音后自动润色', this.autoPolishVoiceResult,
        (): void => {
          this.autoPolishVoiceResult = !this.autoPolishVoiceResult;
          this.commitSettingsChange();
        })
      this.renderLaunchModeRow()
    }
    .width('100%')
    .backgroundColor(CARD_BACKGROUND)
    .borderRadius(26)
    .border({ width: 1, color: CARD_BORDER })
    .shadow(CARD_SHADOW)
  }

  @Builder
  private renderModelCard() {
    Column({ space: 0 }) {
      this.renderCardHeader('section-model', '润色模型')

      Column({ space: 22 }) {
        this.renderDropdownSection('供应商',
          this.builtinProviders.map((provider: BuiltinModelProvider): SelectOption => {
            return { value: provider.providerName };
          }),
          this.resolveProviderIndex(this.llmProviderId),
          (index: number): void => {
            let provider = this.builtinProviders[index];
            if (provider) {
              this.selectProvider(provider);
              this.commitSettingsChange();
            }
          })

        this.renderDropdownSection('模型',
          this.availableModelPresetIds.map((presetId: string): SelectOption => {
            return { value: this.resolvePresetName(presetId) };
          }),
          this.resolvePresetIndex(this.llmPresetId),
          (index: number): void => {
            let presetId = this.availableModelPresetIds[index];
            if (presetId) {
              this.llmPresetId = presetId;
              this.commitSettingsChange();
            }
          })

        this.renderInputField('API Key', '输入 API Key', this.llmApiKey,
          (value: string): void => {
            // Live editing only updates local state; we persist on commit
            // (blur / Enter / explicit 保存 button) so a rapid series of
            // keystrokes doesn't fire an async save storm that can race and
            // lose the last value.
            this.llmApiKey = value;
          },
          (): void => {
            this.commitSettingsChange();
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 20 })
    }
    .width('100%')
    .backgroundColor(CARD_BACKGROUND)
    .borderRadius(26)
    .border({ width: 1, color: CARD_BORDER })
    .shadow(CARD_SHADOW)
  }

  @Builder
  private renderDropdownSection(
    title: string,
    options: SelectOption[],
    selectedIndex: number,
    onSelect: (index: number) => void
  ) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      Select(options)
        .selected(selectedIndex >= 0 ? selectedIndex : 0)
        .value(selectedIndex >= 0 && selectedIndex < options.length ? options[selectedIndex].value as string : '')
        .font({ size: 16, weight: FontWeight.Medium })
        .fontColor(TEXT_PRIMARY)
        .selectedOptionFont({ size: 16, weight: FontWeight.Bold })
        .selectedOptionFontColor(PRIMARY_BLUE)
        .optionFont({ size: 16, weight: FontWeight.Medium })
        .optionFontColor(TEXT_PRIMARY)
        .backgroundColor(SOFT_GRAY)
        .borderRadius(14)
        .width('100%')
        .height(48)
        .onSelect((index: number, _text?: string): void => {
          onSelect(index);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderPermissionCard() {
    Column({ space: 0 }) {
      this.renderCardHeader('permission', '权限')

      Column({ space: 16 }) {
        Row({ space: 12 }) {
          this.renderStatusPill(this.resolvePermissionLabel(), this.resolvePermissionColor())
          Blank()
          this.renderMiniActionButton('授权麦克风', PRIMARY_BLUE, '#FFFFFF', (): void => {
            void this.requestMicrophonePermission();
          })
        }
        .width('100%')

        Text(this.microphonePermissionStatus)
          .fontSize(14)
          .fontColor(TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 20 })
    }
    .width('100%')
    .backgroundColor(CARD_BACKGROUND)
    .borderRadius(26)
    .border({ width: 1, color: CARD_BORDER })
    .shadow(CARD_SHADOW)
  }

  @Builder
  private renderCardHeader(iconKind: string, title: string) {
    Column({ space: 0 }) {
      Row({ space: 14 }) {
        this.renderIconBadge(iconKind)

        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
      .alignItems(VerticalAlign.Center)

      Column()
        .width('100%')
        .height(1)
        .backgroundColor(DIVIDER_COLOR)
    }
    .width('100%')
  }

  @Builder
  private renderIconBadge(iconKind: string) {
    Row() {
      this.renderNamedIcon(iconKind, 22, 22)
    }
    .width(42)
    .height(42)
    .borderRadius(21)
    .backgroundColor(ICON_BADGE_BACKGROUND)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private renderToggleSettingRow(iconKind: string, title: string, enabled: boolean, action: () => void) {
    Column({ space: 0 }) {
      Row({ space: 14 }) {
        this.renderInlineIcon(iconKind)

        Text(title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        this.renderSwitch(enabled, action)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
      .alignItems(VerticalAlign.Center)

      Column()
        .width('100%')
        .height(1)
        .margin({ left: 18, right: 18 })
      .backgroundColor(DIVIDER_COLOR)
    }
    .width('100%')
  }

  @Builder
  private renderLaunchModeRow() {
    Row({ space: 14 }) {
      this.renderInlineIcon('launch')

      Text('默认启动')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      this.renderSegmentedControl()
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 18 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderInlineIcon(iconKind: string) {
    Row() {
      this.renderNamedIcon(iconKind, 22, 22)
    }
    .width(36)
    .height(36)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private renderNamedIcon(iconKind: string, width: number, height: number) {
    if (iconKind === 'section-input') {
      Image($r('app.media.ime_icon_feature_mic'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'voice') {
      Image($r('app.media.ime_icon_key_voicepad'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'polish') {
      Image($r('app.media.ime_icon_feature_style'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'magic') {
      Image($r('app.media.ime_icon_bottom_magic'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'launch') {
      Image($r('app.media.ime_icon_settings_gear'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'section-model') {
      Image($r('app.media.ime_icon_feature_tool'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'permission') {
      Image($r('app.media.ime_icon_settings_sound'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else if (iconKind === 'field') {
      Image($r('app.media.ime_icon_settings_edit'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    } else {
      Image($r('app.media.ime_icon_settings_gear'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
    }
  }

  @Builder
  private renderSwitch(enabled: boolean, action: () => void) {
    Button() {
      Row() {
        Column()
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor('#FFFFFF')
          .shadow({
            radius: 4,
            color: '#18000000',
            offsetX: 0,
            offsetY: 2
          })
      }
      .width(84)
      .height(46)
      .padding({ left: 5, right: 5, top: 0, bottom: 0 })
      .justifyContent(enabled ? FlexAlign.End : FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(enabled ? PRIMARY_BLUE : '#D9E3F1')
      .borderRadius(23)
    }
    .width(84)
    .height(46)
    .backgroundColor('rgba(0,0,0,0)')
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .onClick((): void => {
      action();
    })
  }

  @Builder
  private renderSegmentedControl() {
    Row({ space: 0 }) {
      this.renderSegmentOption('keyboard', '键盘')
      this.renderSegmentOption('voice', '语音')
    }
    .height(50)
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .backgroundColor(SOFT_GRAY)
    .borderRadius(18)
  }

  @Builder
  private renderSegmentOption(value: string, label: string) {
    Button(label)
      .width(104)
      .height(42)
      .fontSize(16)
      .fontWeight(this.defaultEntryMode === value ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.defaultEntryMode === value ? '#FFFFFF' : TEXT_SECONDARY)
      .backgroundColor(this.defaultEntryMode === value ? PRIMARY_BLUE : 'rgba(0,0,0,0)')
      .borderRadius(14)
      .onClick((): void => {
        this.defaultEntryMode = value;
        this.commitSettingsChange();
      })
  }

  @Builder
  private renderChipSection(
    title: string,
    ids: string[],
    resolveLabel: (id: string) => string,
    isSelected: (id: string) => boolean,
    onSelect: (id: string) => void
  ) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(ids, (id: string) => {
          this.renderChoiceChip(resolveLabel(id), isSelected(id), (): void => {
            onSelect(id);
          })
        }, (id: string): string => id)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderChoiceChip(label: string, selected: boolean, onClick: () => void) {
    Button(label)
      .height(48)
      .fontSize(16)
      .fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(selected ? '#FFFFFF' : TEXT_PRIMARY)
      .backgroundColor(selected ? PRIMARY_BLUE : SOFT_GRAY)
      .borderRadius(24)
      .padding({ left: 22, right: 22 })
      .margin({ right: 12, bottom: 12 })
      .onClick((): void => {
        onClick();
      })
  }

  @Builder
  private renderInputField(
    title: string,
    placeholder: string,
    value: string,
    onChange: (value: string) => void,
    onCommit?: () => void
  ) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      Row({ space: 12 }) {
        this.renderInlineIcon('field')

        TextInput({ text: value, placeholder: placeholder })
          .layoutWeight(1)
          .height(52)
          .fontSize(16)
          .backgroundColor('rgba(0,0,0,0)')
          .placeholderColor(TEXT_MUTED)
          .onChange((nextValue: string): void => {
            onChange(nextValue);
          })
          .onBlur((): void => {
            if (onCommit) {
              onCommit();
            }
          })
          .onSubmit((): void => {
            if (onCommit) {
              onCommit();
            }
          })

        if (onCommit) {
          Button('保存')
            .height(36)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor(PRIMARY_BLUE)
            .borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onClick((): void => {
              onCommit();
            })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14, top: 0, bottom: 0 })
      .backgroundColor('#F7FAFD')
      .border({ width: 1, color: '#DCE5F0' })
      .borderRadius(18)
    }
    .width('100%')
  }

  @Builder
  private renderStatusPill(label: string, color: string) {
    Row({ space: 8 }) {
      Column()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(color)

      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
    }
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor('#F7FAFD')
    .borderRadius(18)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderMiniActionButton(label: string, backgroundColor: string, fontColor: string, action: () => void) {
    Button(label)
      .height(42)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(fontColor)
      .backgroundColor(backgroundColor)
      .borderRadius(16)
      .padding({ left: 16, right: 16 })
      .onClick((): void => {
        action();
      })
  }

  private resolveHeaderStatusColor(): string {
    if (this.loaded) {
      return SUCCESS_GREEN;
    }
    if (this.saveStatus.indexOf('无法') >= 0) {
      return ERROR_ORANGE;
    }
    return SUCCESS_GREEN;
  }

  private resolvePermissionLabel(): string {
    if (this.microphonePermissionStatus.indexOf('已授权') >= 0) {
      return '麦克风已授权';
    }
    if (this.microphonePermissionStatus.indexOf('请求中') >= 0 || this.microphonePermissionStatus.indexOf('检查中') >= 0) {
      return '麦克风检查中';
    }
    return '麦克风未授权';
  }

  private resolvePermissionColor(): string {
    return this.microphonePermissionStatus.indexOf('已授权') >= 0 ? SUCCESS_GREEN : ERROR_ORANGE;
  }

  private resolveProviderName(providerId: string): string {
    for (let index = 0; index < this.builtinProviders.length; index++) {
      let provider = this.builtinProviders[index];
      if (provider.providerId === providerId) {
        return provider.providerName;
      }
    }
    return providerId;
  }

  private resolvePresetName(presetId: string): string {
    let provider = this.getSelectedProvider();
    for (let index = 0; index < provider.models.length; index++) {
      let preset = provider.models[index];
      if (preset.presetId === presetId) {
        return preset.displayName;
      }
    }
    return presetId;
  }

  private resolveProviderById(providerId: string): BuiltinModelProvider {
    for (let index = 0; index < this.builtinProviders.length; index++) {
      let provider = this.builtinProviders[index];
      if (provider.providerId === providerId) {
        return provider;
      }
    }
    return this.builtinProviders[0];
  }

  private resolveProviderIndex(providerId: string): number {
    for (let index = 0; index < this.builtinProviders.length; index++) {
      if (this.builtinProviders[index].providerId === providerId) {
        return index;
      }
    }
    return 0;
  }

  private resolvePresetIndex(presetId: string): number {
    for (let index = 0; index < this.availableModelPresetIds.length; index++) {
      if (this.availableModelPresetIds[index] === presetId) {
        return index;
      }
    }
    return 0;
  }

  private getSelectedProvider(): BuiltinModelProvider {
    return this.resolveProviderById(this.llmProviderId);
  }

  private selectProvider(provider: BuiltinModelProvider): void {
    this.applyProviderSelection(provider.providerId, '');
  }

  private applyProviderSelection(providerId: string, preferredPresetId: string): void {
    let resolvedProvider = this.resolveProviderById(providerId);
    let presetIds = this.listModelPresetIds(resolvedProvider);
    let resolvedPresetId = presetIds.length > 0 ? presetIds[0] : '';
    if (preferredPresetId.length > 0 && presetIds.indexOf(preferredPresetId) >= 0) {
      resolvedPresetId = preferredPresetId;
    }
    this.llmProviderId = resolvedProvider.providerId;
    this.availableModelPresetIds = presetIds.slice();
    this.llmPresetId = resolvedPresetId;
  }

  private listModelPresetIds(provider: BuiltinModelProvider): string[] {
    let presetIds: string[] = [];
    for (let index = 0; index < provider.models.length; index++) {
      presetIds.push(provider.models[index].presetId);
    }
    return presetIds;
  }

  private async loadSettings(): Promise<void> {
    let hostContext = this.resolveHostContext();
    if (!hostContext) {
      this.loaded = false;
      this.saveStatus = '无法读取配置';
      this.microphonePermissionStatus = '不可用';
      return;
    }
    let settings = await this.settingsStore.load(hostContext);
    this.applySettings(settings);
    this.loaded = true;
    this.saveStatus = '已加载';
    await this.refreshMicrophonePermissionStatus(hostContext);
  }

  private async saveSettings(): Promise<void> {
    let hostContext = this.resolveHostContext();
    if (!hostContext) {
      this.loaded = false;
      this.saveStatus = '无法保存';
      hilog.warn(SETTINGS_LOG_DOMAIN, SETTINGS_LOG_TAG,
        'saveSettings aborted: host context unavailable');
      return;
    }
    let snapshot = this.buildSettings();
    try {
      await this.settingsStore.save(hostContext, snapshot);
      this.loaded = true;
      this.saveStatus = '已保存';
      hilog.info(SETTINGS_LOG_DOMAIN, SETTINGS_LOG_TAG,
        'saved: provider=%{public}s preset=%{public}s apiKeyLen=%{public}d',
        snapshot.llmProviderId, snapshot.llmPresetId, snapshot.llmApiKey.length);
    } catch (error) {
      this.saveStatus = '保存失败';
      hilog.error(SETTINGS_LOG_DOMAIN, SETTINGS_LOG_TAG,
        'saveSettings failed: %{public}s', (error as Error).message ?? String(error));
    }
  }

  // Fire-and-forget wrapper used by in-card controls so every tweak is
  // persisted immediately. Serializes through `pendingSave` so rapid
  // consecutive changes (dropdown click → auto-save, then another click)
  // don't race each other at the preferences layer and drop writes.
  private commitSettingsChange(): void {
    let runner = (): Promise<void> => {
      return this.saveSettings();
    };
    this.pendingSave = this.pendingSave.then(runner, runner);
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
    this.applyProviderSelection(next.llmProviderId, next.llmPresetId);
    this.llmApiKey = next.llmApiKey;
    this.llmStyle = next.llmStyle;
    this.defaultEntryMode = next.defaultEntryMode === 'voice' ? 'voice' : 'keyboard';
  }

  private buildSettings(): OffhandRuntimeSettings {
    let selection = resolveBuiltinModelSelection(this.llmProviderId, this.llmPresetId);
    return {
      enablePreviewText: this.enablePreviewText,
      enableVoice: this.enableVoice,
      enableCloudPolish: this.enableCloudPolish,
      enablePersonalization: this.enablePersonalization,
      autoInsertVoiceResult: this.autoInsertVoiceResult,
      autoPolishVoiceResult: this.autoPolishVoiceResult,
      asrEndpoint: this.asrEndpoint.trim(),
      llmProviderId: selection.provider.providerId,
      llmPresetId: selection.preset.presetId,
      llmApiKey: this.llmApiKey.trim(),
      llmStyle: this.llmStyle.trim().length > 0 ? this.llmStyle.trim() : createDefaultRuntimeSettings().llmStyle,
      defaultEntryMode: this.defaultEntryMode === 'voice' ? 'voice' : 'keyboard'
    };
  }

  private async requestMicrophonePermission(): Promise<void> {
    let hostContext = this.resolveHostContext() as common.UIAbilityContext | undefined;
    if (!hostContext) {
      this.microphonePermissionStatus = '不可用';
      return;
    }
    this.microphonePermissionStatus = '请求中';
    try {
      let result = await this.atManager.requestPermissionsFromUser(hostContext, [MICROPHONE_PERMISSION]);
      let granted = result.authResults.some((value: number): boolean => {
        return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      });
      this.microphonePermissionStatus = granted ? '已授权' : '未授权';
    } catch (_) {
      this.microphonePermissionStatus = '请求失败';
    }
    await this.refreshMicrophonePermissionStatus(hostContext);
  }

  private async refreshMicrophonePermissionStatus(context?: common.Context): Promise<void> {
    let hostContext = context ?? this.resolveHostContext();
    if (!hostContext) {
      this.microphonePermissionStatus = '不可用';
      return;
    }
    try {
      let grantStatus = this.atManager.checkAccessTokenSync(
        hostContext.applicationInfo.accessTokenId,
        MICROPHONE_PERMISSION
      );
      this.microphonePermissionStatus = grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ?
        '已授权' :
        '未授权';
    } catch (_) {
      this.microphonePermissionStatus = '不可用';
    }
  }

  private resolveHostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext() as common.Context | undefined;
  }
}
