import { hilog } from '@kit.PerformanceAnalysisKit';
import { BuiltinModelPreset, BuiltinModelProvider, CandidateItem, KeyboardLayoutId, KeyboardLayoutOption, SubtypeSummary } from '../common/ImeTypes';
import { imeRuntime } from '../runtime/ImeRuntime';
import { KeyboardUiState, keyboardStateStore } from '../session/KeyboardStateStore';
import { listBuiltinModelProviders, resolveBuiltinModelSelection } from '../config/BuiltinModels';
import { LlmSelectionSnapshot } from '../session/SessionManager';

const PANEL_DOMAIN: number = 0xFF10;
const PANEL_TAG: string = 'KeyboardPanel';

const LETTER_ROW_TOP: string[] = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
const LETTER_ROW_MIDDLE: string[] = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
const LETTER_ROW_BOTTOM: string[] = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
const SIDE_PUNCTUATIONS: string[] = ['，', '。', '？', '！'];
const COMMON_SYMBOLS: string[] = ['，', '。', '？', '！', '@', '#', '/', '-', '_', ':', ';', '(', ')'];
// Candidate strip and feature row must share the same height so the
// keyboard body does not shift vertically when candidates show up. The
// strip overlays the toolbar position 1:1.
const FEATURE_ROW_HEIGHT: number = 40;
const TOP_ACCESSORY_HEIGHT: number = FEATURE_ROW_HEIGHT;
// iOS-style T9 keys: tighter corner radius gives a flatter, more grid-aligned
// look than the previous 18 which made keys feel floaty and slightly
// misaligned with neighbors.
const T9_KEY_RADIUS: number = 10;

interface NineGridKeyDescriptor {
  digit: string;
  label: string;
  action: 'digit' | 'text';
  value: string;
}

interface QwertyKeyDescriptor {
  hint: string;
  label: string;
  value: string;
}

const NINE_GRID_ROWS: NineGridKeyDescriptor[][] = [
  [
    { digit: '1', label: '分词', action: 'text', value: '\'' },
    { digit: '2', label: 'ABC', action: 'digit', value: '2' },
    { digit: '3', label: 'DEF', action: 'digit', value: '3' }
  ],
  [
    { digit: '4', label: 'GHI', action: 'digit', value: '4' },
    { digit: '5', label: 'JKL', action: 'digit', value: '5' },
    { digit: '6', label: 'MNO', action: 'digit', value: '6' }
  ],
  [
    { digit: '7', label: 'PQRS', action: 'digit', value: '7' },
    { digit: '8', label: 'TUV', action: 'digit', value: '8' },
    { digit: '9', label: 'WXYZ', action: 'digit', value: '9' }
  ]
];

const QWERTY_TOP_KEYS: QwertyKeyDescriptor[] = [
  { hint: '1', label: 'Q', value: 'q' },
  { hint: '2', label: 'W', value: 'w' },
  { hint: '3', label: 'E', value: 'e' },
  { hint: '4', label: 'R', value: 'r' },
  { hint: '5', label: 'T', value: 't' },
  { hint: '6', label: 'Y', value: 'y' },
  { hint: '7', label: 'U', value: 'u' },
  { hint: '8', label: 'I', value: 'i' },
  { hint: '9', label: 'O', value: 'o' },
  { hint: '0', label: 'P', value: 'p' }
];

const QWERTY_MIDDLE_KEYS: QwertyKeyDescriptor[] = [
  { hint: '~', label: 'A', value: 'a' },
  { hint: '@', label: 'S', value: 's' },
  { hint: '#', label: 'D', value: 'd' },
  { hint: '$', label: 'F', value: 'f' },
  { hint: '%', label: 'G', value: 'g' },
  { hint: '&', label: 'H', value: 'h' },
  { hint: '*', label: 'J', value: 'j' },
  { hint: '(', label: 'K', value: 'k' },
  { hint: ')', label: 'L', value: 'l' }
];

const QWERTY_BOTTOM_KEYS: QwertyKeyDescriptor[] = [
  { hint: '\'', label: 'Z', value: 'z' },
  { hint: '/', label: 'X', value: 'x' },
  { hint: '-', label: 'C', value: 'c' },
  { hint: '_', label: 'V', value: 'v' },
  { hint: ':', label: 'B', value: 'b' },
  { hint: ';', label: 'N', value: 'n' },
  { hint: '`', label: 'M', value: 'm' }
];

@Entry
@Component
struct KeyboardPanel {
  @State private uiState: KeyboardUiState = keyboardStateStore.getSnapshot();
  @State private showSettingsTray: boolean = false;
  @State private activeSettingsTab: string = 'common';
  @State private showSymbolPalette: boolean = false;
  @State private qwertyShiftEnabled: boolean = false;
  // Pulse ring state for the voice waiting circle. `voicePulseExpanded`
  // toggles every PULSE_INTERVAL_MS so the outer rings animate out/in
  // continuously while we are waiting for the user to keep speaking.
  @State private voicePulseExpanded: boolean = false;
  // LLM settings tab state: selection + API key editor buffers. These are
  // seeded from SessionManager.getLlmSelectionSnapshot when the tab opens.
  @State private llmDialogProviderId: string = '';
  @State private llmDialogPresetId: string = '';
  @State private llmDialogApiKey: string = '';
  @State private llmSaveStatus: string = '';
  private voicePulseTimer?: number;
  private unsubscribe?: () => void;

  // @Styles methods can only include universal attributes and are state-less;
  // we express the pressed state as a darker background so Column-based keys
  // (which lack a built-in ripple) get the same tactile feedback as Buttons.
  @Styles pressedWhiteKeyStyle() {
    .backgroundColor('#DDE0E6')
  }

  @Styles pressedGrayKeyStyle() {
    .backgroundColor('#AFB1B9')
  }

  aboutToAppear(): void {
    this.unsubscribe = keyboardStateStore.subscribe((state: KeyboardUiState): void => {
      this.uiState = state;
      if (!state.sessionActive) {
        if (!this.showSettingsTray) {
          this.showSymbolPalette = false;
          this.activeSettingsTab = 'common';
        }
        this.qwertyShiftEnabled = false;
      }
      if (state.keyboardLayout !== 'qwerty_26') {
        this.qwertyShiftEnabled = false;
      }
      this.syncVoicePulseAnimation(state);
    });
    this.syncVoicePulseAnimation(this.uiState);
  }

  aboutToDisappear(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
    this.stopVoicePulseAnimation();
  }

  private syncVoicePulseAnimation(state: KeyboardUiState): void {
    let shouldPulse = state.keyboardLayout === 'voice_panel'
      && state.voiceState === 'recording'
      && state.voiceEnabled;
    if (shouldPulse) {
      this.startVoicePulseAnimation();
    } else {
      this.stopVoicePulseAnimation();
    }
  }

  private startVoicePulseAnimation(): void {
    if (this.voicePulseTimer !== undefined) {
      return;
    }
    // Kick off the first expansion immediately so users see motion without
    // the initial 1400ms dead zone of a timer-driven toggle.
    this.voicePulseExpanded = true;
    this.voicePulseTimer = setInterval((): void => {
      this.voicePulseExpanded = !this.voicePulseExpanded;
    }, 1400);
  }

  private stopVoicePulseAnimation(): void {
    if (this.voicePulseTimer !== undefined) {
      clearInterval(this.voicePulseTimer);
      this.voicePulseTimer = undefined;
    }
    this.voicePulseExpanded = false;
  }

  build() {
    Stack() {
      if (!this.showSettingsTray) {
        Column({ space: 2 }) {
          this.renderTopAccessoryArea()
          this.renderVoiceDraftCard()
          this.renderPolishSuggestionStrip()

          if (this.uiState.keyboardLayout === 'voice_panel') {
            this.renderVoicePanel();
          } else if (this.uiState.keyboardLayout === 't9_9') {
            this.renderReferenceNineKeyKeyboard();
          } else {
            this.renderReferenceQwertyKeyboard();
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 0 })
        .backgroundColor('#D9DCE2')
      } else {
        Column({ space: 0 }) {
          this.renderSettingsOverlay()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 0 })
        .backgroundColor('#D9DCE2')
        .zIndex(10)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#D9DCE2')
  }

  @Builder
  private renderTopAccessoryArea() {
    Column() {
      if (this.shouldShowCandidateStrip()) {
        this.renderCandidateOrSymbolStrip()
      } else {
        this.renderFeatureRow()
      }
    }
    .width('100%')
    .height(FEATURE_ROW_HEIGHT)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private renderTopToolbar() {
    Row({ space: 12 }) {
      this.renderHeaderOutlineButton('◉', (): void => {
        this.showSettingsTray = !this.showSettingsTray;
      })

      this.renderHeaderOutlineButton('☺', (): void => {
        this.showSymbolPalette = !this.showSymbolPalette;
      })

      this.renderComposeCapsule()

      this.renderHeaderOutlineButton('+', (): void => {
        this.handlePrimaryToolbarAction();
      }, this.canUsePrimaryAction())

      this.renderHeaderSendButton()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
    .backgroundColor('#FFFFFF')
  }

  @Builder
  private renderReferenceQwertyTopToolbar() {
    Row({ space: 12 }) {
      this.renderReferenceQwertyHeaderButton('◉', (): void => {
        this.startOrStopVoice();
      })

      this.renderReferenceQwertyComposePanel()

      this.renderReferenceQwertyHeaderButton('☺︎', (): void => {
        this.showSymbolPalette = !this.showSymbolPalette;
      })

      this.renderReferenceQwertyHeaderButton('+', (): void => {
        this.handlePrimaryToolbarAction();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 14, top: 6, bottom: 4 })
    .backgroundColor('#FFFFFF')
  }

  @Builder
  private renderComposeCapsule() {
    Row({ space: 12 }) {
      Column()
        .width(3)
        .height(20)
        .backgroundColor('#69B24C')
        .borderRadius(999)

      Column({ space: 4 }) {
        Text(this.resolveComposeHeadline())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181B')
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(1)

        Text(this.resolveComposeSubline())
          .fontSize(9)
          .fontColor('#767881')
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .opacity(this.resolveComposeSubline().length > 0 ? 1 : 0)
      }
      .layoutWeight(1)
    }
    .layoutWeight(1)
    .height(50)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#F2F0EB')
    .borderRadius(25)
  }

  @Builder
  private renderReferenceQwertyComposePanel() {
    Row({ space: 14 }) {
      Column()
        .width(3)
        .height(28)
        .backgroundColor('#2B79FF')
        .borderRadius(999)

      Text(this.resolveComposeHeadline())
        .layoutWeight(1)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#15171B')
        .maxLines(1)
        .textAlign(TextAlign.Start)
    }
    .layoutWeight(1)
    .height(50)
    .padding({ left: 14, right: 14 })
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
  }

  @Builder
  private renderFeatureRow() {
    // Top feature bar matches the reference mockup: magic/AI entry point on
    // the far left, the T-shirt style switcher in the center, and the
    // smile-emoji / divider / chevron cluster on the right. The mic toggle
    // is intentionally not exposed here — voice is still reachable through
    // the dedicated mic key in the keyboard body, which keeps the top bar
    // uncluttered and in parity with the reference design.
    Row() {
      this.renderFeatureIconAssetButton('magic', (): void => {
        this.toggleSettingsOverlay();
      }, this.showSettingsTray)

      this.renderFeatureIconAssetButton('style', (): void => {
        this.toggleReferenceLayoutStyle();
      }, false, this.supportsNineKey() || this.supportsTwentySixKey())

      Row({ space: 10 }) {
        this.renderFeatureIconAssetButton('smile', (): void => {
          this.showSymbolPalette = !this.showSymbolPalette;
        }, this.showSymbolPalette)

        Column()
          .width(1)
          .height(28)
          .backgroundColor('#C5C8CF')
          .margin({ left: 2, right: 2 })

        this.renderFeatureIconAssetButton('chevron', (): void => {
          void imeRuntime.getSessionManager()?.handleKeyboardHide();
        })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
  }

  @Builder
  private renderSettingsOverlay() {
    Column({ space: 0 }) {
      this.renderSettingsHeader()

      Blank()
        .height(8)

      if (this.activeSettingsTab === 'llm') {
        // LLM tab takes the entire remaining space and renders its own
        // padding. We intentionally skip the pager dots and trailing Blank
        // used by common/input because the LLM editor needs the full panel
        // height for the provider/model chips + API key input.
        this.renderLlmSettingsGrid()
      } else {
        if (this.activeSettingsTab === 'input') {
          this.renderInputSettingsGrid()
        } else {
          this.renderCommonSettingsGrid()
        }

        Blank()
          .layoutWeight(1)

        Blank()
          .height(6)

        this.renderSettingsPager()

        Blank()
          .height(4)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 10, right: 10, top: 4, bottom: 0 })
  }

  @Builder
  private renderSettingsHeader() {
    Row({ space: 8 }) {
      Button() {
        this.renderSettingsIconAsset('collapse', 24, 24)
      }
        .width(42)
        .height(42)
        .backgroundColor('#D4D7DC')
        .borderRadius(21)
        .shadow(this.resolveGrayKeyShadow())
        .onClick(() => {
          this.closeSettingsOverlay();
        })

      Row({ space: 4 }) {
        this.renderSettingsTabButton('common', '常用功能')
        this.renderSettingsTabButton('input', '输入方式')
        this.renderSettingsTabButton('llm', '大模型')
      }
      .layoutWeight(1)
      .height(48)
      .padding({ left: 3, right: 3, top: 3, bottom: 3 })
      .backgroundColor('#D4D7DC')
      .borderRadius(24)

      Image($r('app.media.ime_icon_settings_avatar'))
        .width(42)
        .height(42)
        .objectFit(ImageFit.Cover)
        .borderRadius(21)
        .shadow(this.resolveGrayKeyShadow())
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderSettingsTabButton(tabId: string, label: string) {
    Button() {
      Text(label)
        .width('100%')
        .fontSize(12)
        .minFontSize(9)
        .maxFontSize(12)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(this.activeSettingsTab === tabId ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeSettingsTab === tabId ? '#17181B' : '#60636A')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
      .layoutWeight(1)
      .height(42)
      .padding({ left: 0, right: 0, top: 0, bottom: 0 })
      .backgroundColor(this.activeSettingsTab === tabId ? '#FFFFFF' : 'rgba(0,0,0,0)')
      .borderRadius(21)
      .shadow(this.resolveSettingsTabShadow(this.activeSettingsTab === tabId))
      .onClick(() => {
        this.activeSettingsTab = tabId;
        if (tabId === 'llm') {
          this.seedLlmDialogState();
        }
      })
  }

  @Builder
  private renderCommonSettingsGrid() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        this.renderSettingsTile('gear', '设置', (): void => {
          void imeRuntime.getSessionManager()?.openHostSettingsPage();
          this.closeSettingsOverlay();
        })
        this.renderSettingsTile('lexicon', '词库', (): void => {})
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 0, right: 0, bottom: 4 })
  }

  @Builder
  private renderInputSettingsGrid() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        this.renderSettingsTile('拼', '中文拼音（26 键）', (): void => {
          this.switchSettingsSubtype('zh-Hans-pinyin');
          if (this.supportsTwentySixKey()) {
            void imeRuntime.getSessionManager()?.switchKeyboardLayout('qwerty_26');
          }
          this.closeSettingsOverlay();
        }, !this.isEnglishSubtype() && this.uiState.keyboardLayout !== 'voice_panel')
        this.renderSettingsTile('EN', '英文输入', (): void => {
          this.switchSettingsSubtype('en-US-qwerty');
          this.closeSettingsOverlay();
        }, this.isEnglishSubtype())
        this.renderSettingsTile('voice', '语音输入', (): void => {
          // 切换到语音面板时，确保使用支持语音的子类型
          let voiceSubtype = this.findSubtypeById('zh-CN-voice');
          if (voiceSubtype.length > 0) {
            void imeRuntime.getSessionManager()?.switchSubtype(voiceSubtype);
          } else {
            let pinyinSubtype = this.findSubtypeById('zh-Hans-pinyin');
            if (pinyinSubtype.length > 0) {
              void imeRuntime.getSessionManager()?.switchSubtype(pinyinSubtype);
            }
          }
          void imeRuntime.getSessionManager()?.switchKeyboardLayout('voice_panel');
          this.closeSettingsOverlay();
        }, this.uiState.keyboardLayout === 'voice_panel')
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 0, right: 0, bottom: 4 })
  }

  // LLM settings tab: lets the user pick a provider + model and paste the
  // API Key directly inside the IME panel. This avoids the UIAbility-vs-IME
  // cross-sandbox isolation issue because the save path runs entirely in
  // the InputMethodExtensionAbility sandbox.
  @Builder
  private renderLlmSettingsGrid() {
    Column({ space: 0 }) {
      // Scrollable body — provider/model chips + API key + status.
      Scroll() {
        Column({ space: 10 }) {
          // Provider row — Flex with Wrap so extra providers don't overflow.
          Text('供应商')
            .fontSize(12)
            .fontColor('#60636A')
            .width('100%')
          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start,
            alignItems: ItemAlign.Center
          }) {
            ForEach(listBuiltinModelProviders(), (provider: BuiltinModelProvider) => {
              Button() {
                Text(provider.providerName)
                  .fontSize(12)
                  .fontColor(provider.providerId === this.llmDialogProviderId ? '#FFFFFF' : '#17181B')
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
              }
              .height(34)
              .margin({ right: 8, bottom: 8 })
              .padding({ left: 14, right: 14, top: 0, bottom: 0 })
              .backgroundColor(provider.providerId === this.llmDialogProviderId ? '#3478F6' : '#FFFFFF')
              .border({
                width: 1,
                color: provider.providerId === this.llmDialogProviderId ? '#3478F6' : '#E4E6EA'
              })
              .borderRadius(17)
              .onClick(() => {
                this.llmDialogProviderId = provider.providerId;
                this.llmDialogPresetId = provider.models.length > 0 ? provider.models[0].presetId : '';
              })
            }, (provider: BuiltinModelProvider) => provider.providerId)
          }
          .width('100%')

          // Model row
          Text('模型')
            .fontSize(12)
            .fontColor('#60636A')
            .width('100%')
          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start,
            alignItems: ItemAlign.Center
          }) {
            ForEach(this.resolveLlmModelsForSelectedProvider(), (preset: BuiltinModelPreset) => {
              Button() {
                Text(preset.displayName)
                  .fontSize(12)
                  .fontColor(preset.presetId === this.llmDialogPresetId ? '#FFFFFF' : '#17181B')
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
              }
              .height(34)
              .margin({ right: 8, bottom: 8 })
              .padding({ left: 14, right: 14, top: 0, bottom: 0 })
              .backgroundColor(preset.presetId === this.llmDialogPresetId ? '#3478F6' : '#FFFFFF')
              .border({
                width: 1,
                color: preset.presetId === this.llmDialogPresetId ? '#3478F6' : '#E4E6EA'
              })
              .borderRadius(17)
              .onClick(() => {
                this.llmDialogPresetId = preset.presetId;
              })
            }, (preset: BuiltinModelPreset) => preset.presetId)
          }
          .width('100%')

          // API Key editor
          Text('API Key')
            .fontSize(12)
            .fontColor('#60636A')
            .width('100%')
          Row({ space: 8 }) {
            TextInput({ placeholder: '粘贴 API Key', text: this.llmDialogApiKey })
              .type(InputType.Password)
              .fontSize(13)
              .height(40)
              .layoutWeight(1)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.llmDialogApiKey = value;
              })
            Button('清空')
              .height(40)
              .fontSize(13)
              .fontColor('#17181B')
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#E4E6EA' })
              .borderRadius(20)
              .padding({ left: 14, right: 14, top: 0, bottom: 0 })
              .onClick(() => {
                this.llmDialogApiKey = '';
                this.llmSaveStatus = '已清空 API Key，点击“保存”后生效。';
              })
          }
          .width('100%')

          if (this.llmSaveStatus.length > 0) {
            Text(this.llmSaveStatus)
              .fontSize(12)
              .fontColor('#3478F6')
              .width('100%')
          }

          // Trailing spacer so the last element isn't flush against the
          // fixed bottom action bar.
          Blank()
            .height(12)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 4, right: 4, top: 4, bottom: 4 })
      }
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .layoutWeight(1)

      // Fixed bottom action row — stays visible regardless of scroll.
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontColor('#17181B')
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E4E6EA' })
          .borderRadius(22)
          .onClick(() => {
            this.seedLlmDialogState();
            this.llmSaveStatus = '';
          })
        Button('保存')
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#3478F6')
          .borderRadius(22)
          .onClick(() => {
            this.saveLlmDialog();
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  private resolveLlmModelsForSelectedProvider(): BuiltinModelPreset[] {
    let providers: BuiltinModelProvider[] = listBuiltinModelProviders();
    for (let i: number = 0; i < providers.length; i++) {
      if (providers[i].providerId === this.llmDialogProviderId) {
        return providers[i].models;
      }
    }
    return [];
  }

  private seedLlmDialogState(): void {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      return;
    }
    let snap: LlmSelectionSnapshot = session.getLlmSelectionSnapshot();
    // Resolve against the builtin catalog so we always end up on a valid
    // provider/preset pair even if persisted settings are stale.
    let resolved = resolveBuiltinModelSelection(snap.providerId, snap.presetId);
    this.llmDialogProviderId = resolved.provider.providerId;
    this.llmDialogPresetId = resolved.preset.presetId;
    this.llmDialogApiKey = snap.apiKey;
    this.llmSaveStatus = '';
  }

  private saveLlmDialog(): void {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      this.llmSaveStatus = '保存失败：会话未就绪';
      return;
    }
    let providerId: string = this.llmDialogProviderId;
    let presetId: string = this.llmDialogPresetId;
    let apiKey: string = this.llmDialogApiKey;
    this.llmSaveStatus = '保存中…';
    session.updateLlmSelection(providerId, presetId, apiKey)
      .then((): void => {
        this.llmSaveStatus = 'API Key 已保存，润色将使用最新配置。';
      })
      .catch((error: Error): void => {
        this.llmSaveStatus = '保存失败：' + (error.message ?? String(error));
      });
  }

  @Builder
  private renderLayoutSettingsGrid() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        this.renderSettingsTile('9', '九键布局', (): void => {
          if (this.supportsNineKey()) {
            void imeRuntime.getSessionManager()?.switchKeyboardLayout('t9_9');
            this.closeSettingsOverlay();
          }
        }, this.uiState.keyboardLayout === 't9_9')
        this.renderSettingsTile('26', '26 键布局', (): void => {
          if (this.supportsTwentySixKey()) {
            void imeRuntime.getSessionManager()?.switchKeyboardLayout('qwerty_26');
            this.closeSettingsOverlay();
          }
        }, this.uiState.keyboardLayout === 'qwerty_26')
        this.renderSettingsTile('语', '语音面板', (): void => {
          void imeRuntime.getSessionManager()?.switchKeyboardLayout('voice_panel');
          this.closeSettingsOverlay();
        }, this.uiState.keyboardLayout === 'voice_panel')
        this.renderSettingsInfoTile('当前模式', this.resolveLayoutDisplayLabel(this.uiState.keyboardLayout))
      }
      .width('100%')

      Row({ space: 12 }) {
        this.renderSettingsInfoTile('编辑器', this.uiState.editorSummary.length > 0 ? this.uiState.editorSummary : '普通文本')
        this.renderSettingsInfoTile('候选页', `第 ${this.uiState.candidatePageNo + 1} 页`)
        this.renderSettingsInfoTile('快捷切换', this.resolveQuickSwitchLabel())
        this.renderSettingsTile('⟲', '关闭设置', (): void => {
          this.closeSettingsOverlay();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 0, right: 0, bottom: 4 })
  }

  @Builder
  private renderSettingsTile(icon: string, title: string, action: () => void, selected: boolean = false) {
    Button() {
      Column({ space: 10 }) {
        this.renderSettingsIconAsset(icon, 31, 31)

        Text(title)
          .fontSize(13)
          .minFontSize(10)
          .maxFontSize(13)
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(FontWeight.Medium)
          .fontColor('#4D5058')
          .textAlign(TextAlign.Center)
          .maxLines(2)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .height('100%')
      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    }
    .layoutWeight(1)
    .height(92)
    .backgroundColor(selected ? '#EDF3FF' : '#FFFFFF')
    .border({ width: 1, color: selected ? '#D5E4FF' : '#F5F6F8' })
    .borderRadius(20)
    .shadow(this.resolveWhiteKeyShadow())
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderSettingsInfoTile(title: string, value: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#6A6D75')
        .textAlign(TextAlign.Center)
        .maxLines(1)

      Text(value)
        .fontSize(12)
        .minFontSize(9)
        .maxFontSize(12)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202126')
        .textAlign(TextAlign.Center)
        .maxLines(3)
    }
    .layoutWeight(1)
    .height(92)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 6, right: 6 })
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F5F6F8' })
    .borderRadius(20)
    .shadow(this.resolveWhiteKeyShadow())
  }

  @Builder
  private renderSettingsPager() {
    Row({ space: 10 }) {
      ForEach([0, 1], (index: number) => {
        Column()
          .width(index === this.resolveSettingsPagerIndex() ? 18 : 7)
          .height(7)
          .backgroundColor(index === this.resolveSettingsPagerIndex() ? '#286CFF' : '#D0D3DA')
          .borderRadius(999)
      }, (index: number): string => `${index}`)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4 })
  }

  @Builder
  private renderStatusChipRow() {
    Scroll() {
      Row({ space: 8 }) {
        this.renderStatusChip(`字段 ${this.uiState.securitySummary}`)
        this.renderStatusChip(`语音 ${this.uiState.voiceEnabled ? '开' : '关'}`)
        this.renderStatusChip(`润色 ${this.uiState.polishEnabled ? '开' : '关'}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
  }

  @Builder
  private renderStatusChip(label: string) {
    Text(label)
      .fontSize(10)
      .fontColor('#5F5F63')
      .padding({ top: 5, right: 8, bottom: 5, left: 8 })
      .backgroundColor('#F2F2F5')
      .borderRadius(999)
  }

  @Builder
  private renderTrayPill(label: string, selected: boolean, action: () => void) {
    Button(label)
      .type(ButtonType.Capsule)
      .fontSize(12)
      .fontColor(selected ? '#FFFFFF' : '#46484D')
      .backgroundColor(selected ? '#6D7366' : '#F1F1F4')
      .onClick(() => {
        action();
      })
  }

  @Builder
  private renderCandidateOrSymbolStrip() {
    Column({ space: 8 }) {
      if (this.showSymbolPalette) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(COMMON_SYMBOLS, (symbol: string) => {
              Text(symbol)
                .fontSize(14)
                .fontColor('#333333')
                .width(26)
                .height(26)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F3F3F6')
                .borderRadius(13)
                .onClick(() => {
                  this.commitText(symbol);
                  this.showSymbolPalette = false;
                })
            }, (symbol: string): string => symbol)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .height(28)
      } else {
        Row({ space: 8 }) {
          Text('‹')
            .fontSize(14)
            .fontColor(this.uiState.hasPreviousCandidatePage ? '#7A7C84' : '#CCCCCC')
            .width(22)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (this.uiState.hasPreviousCandidatePage) {
                void imeRuntime.getSessionManager()?.pageCandidateBackward();
              }
            })

          Scroll() {
            Row({ space: 18 }) {
              if (this.uiState.candidates.length === 0) {
                Text(this.uiState.preedit.length > 0 ? this.uiState.preedit :
                  (this.uiState.activeNineKeySpelling.length > 0 ? this.uiState.activeNineKeySpelling :
                    this.resolveCandidatePlaceholder()))
                  .fontSize(13)
                  .fontColor(this.uiState.preedit.length > 0 ? '#2B2B2D' : '#9A9CA3')
                  .maxLines(1)
              } else {
                ForEach(this.uiState.candidates, (candidate: CandidateItem) => {
                  Text(candidate.text)
                    .fontSize(14)
                    .fontColor(candidate.highlighted ? '#1677FF' : '#2B2B2D')
                    .fontWeight(candidate.highlighted ? FontWeight.Bold : FontWeight.Normal)
                    .maxLines(1)
                    .constraintSize({ maxWidth: 64 })
                    .onClick(() => {
                      void imeRuntime.getSessionManager()?.selectCandidate(candidate.index);
                    })
                  // Key MUST include candidate.text: rime's candidate index/label
                  // are always 0..N/"1".."N" per page, so two different pinyin
                  // buffers can yield the same key triple and ArkTS would
                  // reuse the Text node without refreshing, making the
                  // candidate strip look stale across keystrokes.
                }, (candidate: CandidateItem): string => `${candidate.index}-${candidate.label}-${candidate.text}`)
              }
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .layoutWeight(1)
          .height(24)

          Text('›')
            .fontSize(14)
            .fontColor(this.uiState.hasNextCandidatePage ? '#4B4D55' : '#CCCCCC')
            .width(22)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (this.uiState.hasNextCandidatePage) {
                void imeRuntime.getSessionManager()?.pageCandidateForward();
              }
            })
        }
        .width('100%')
        .height(24)

        if (this.uiState.nineKeySpellings.length > 0) {
          Row({ space: 6 }) {
            ForEach(this.uiState.nineKeySpellings, (spelling: string) => {
              Text(spelling)
                .fontSize(10)
                .fontColor(spelling === this.uiState.activeNineKeySpelling ? '#FFFFFF' : '#666A72')
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor(spelling === this.uiState.activeNineKeySpelling ? '#1677FF' : '#EEF0F4')
                .borderRadius(12)
                .onClick(() => {
                  if (spelling !== this.uiState.activeNineKeySpelling) {
                    void imeRuntime.getSessionManager()?.selectNineKeySpelling(spelling);
                  }
                })
            }, (spelling: string): string => spelling)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
  }

  @Builder
  private renderVoiceDraftCard() {
    if (this.uiState.voiceDraftText.length > 0) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('语音草稿')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#2E2E2E')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)

          Text('先确认，再插入')
            .fontSize(10)
            .fontColor('#75767C')
        }
        .width('100%')

        Text(this.uiState.voiceDraftText)
          .fontSize(14)
          .fontColor('#1C1C1E')
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(4)

        Row({ space: 8 }) {
          Button('插入')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor('#7A835E')
            .borderRadius(12)
            .onClick(() => {
              void imeRuntime.getSessionManager()?.insertVoiceDraft();
            })

          Button('清空')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#4C4D52')
            .backgroundColor('#ECECEF')
            .borderRadius(12)
            .onClick(() => {
              void imeRuntime.getSessionManager()?.clearVoiceDraft();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(8)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
    }
  }

  @Builder
  private renderPolishSuggestionStrip() {
    if (this.uiState.showPolishSuggestion || this.uiState.canRevertPolish) {
      Column({ space: 8 }) {
        if (this.uiState.showPolishSuggestion) {
          Text('润色建议')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#2E2E2E')
            .width('100%')
            .textAlign(TextAlign.Start)

          if (this.uiState.polishSourceText.length > 0) {
            Text(`原文：${this.uiState.polishSourceText}`)
              .fontSize(12)
              .fontColor('#73757B')
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
          }

          Text(`建议：${this.uiState.polishSuggestionText}`)
            .fontSize(12)
            .fontColor('#2E2E2E')
            .width('100%')
            .textAlign(TextAlign.Start)
            .maxLines(3)

          Row({ space: 8 }) {
            Button('应用')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor('#7A835E')
              .borderRadius(12)
              .onClick(() => {
                void imeRuntime.getSessionManager()?.acceptPolishSuggestion();
              })

            Button('保留原文')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor('#4C4D52')
              .backgroundColor('#ECECEF')
              .borderRadius(12)
              .onClick(() => {
                void imeRuntime.getSessionManager()?.dismissPolishSuggestion();
              })
          }
          .width('100%')
        } else {
          Row({ space: 8 }) {
            Text('已应用润色结果。')
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#4C4D52')
              .textAlign(TextAlign.Start)

            Button('撤销')
              .width(84)
              .height(36)
              .fontSize(13)
              .fontColor('#4C4D52')
              .backgroundColor('#ECECEF')
              .borderRadius(12)
              .onClick(() => {
                void imeRuntime.getSessionManager()?.revertLastPolish();
              })
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(8)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
    }
  }

  @Builder
  private renderReferenceNineKeyKeyboard() {
    Row({ space: 6 }) {
      Column({ space: 6 }) {
        this.renderPunctuationRail()

        // Weight has no effect on horizontal size inside a vertical Column;
        // the button fills the 70px column width via width('100%') in the
        // builder. Keep weight=1 to document "single child takes natural row".
        this.renderBottomActionKey('符号', this.showSymbolPalette, (): void => {
          this.showSymbolPalette = !this.showSymbolPalette;
        }, true, 1)
      }
      .width(70)
      .height(this.resolveReferenceNineKeyHeight())

      Column({ space: 6 }) {
        Column({ space: 6 }) {
          ForEach(NINE_GRID_ROWS, (row: NineGridKeyDescriptor[]) => {
            Row({ space: 6 }) {
              ForEach(row, (descriptor: NineGridKeyDescriptor) => {
                this.renderNineGridKey(descriptor)
              }, (descriptor: NineGridKeyDescriptor): string => `${descriptor.digit}-${descriptor.label}`)
            }
            .width('100%')
            .height(this.resolveReferenceNineKeyRowHeight())
          }, (row: NineGridKeyDescriptor[]): string => `row-${row[0].digit}`)
        }
        .width('100%')
        .height(this.resolveReferenceNineKeyGridHeight())

        Row({ space: 6 }) {
          // Use strict 1:1:1 layout weights so the three bottom keys line up
          // pixel-perfectly with the three grid columns above: 中/英 under
          // column 1 (分词), 0/mic under column 2 (ABC), and 123 under column 3
          // (DEF). Mixed non-integer weights previously drifted each key away
          // from its grid column by a few pixels.
          this.renderBottomActionKey(this.resolveQuickSwitchLabel(), false, (): void => {
            this.switchQuickSubtype();
          }, true, 1)

          this.renderVoicePadKey()

          this.renderBottomActionKey('123', false, (): void => {
            if (this.supportsTwentySixKey()) {
              void imeRuntime.getSessionManager()?.switchKeyboardLayout('qwerty_26');
            }
          }, this.supportsTwentySixKey(), 1)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .height(this.resolveReferenceNineKeyHeight())

      Column({ space: 6 }) {
        this.renderSideActionKey('⌫', (): void => {
          void imeRuntime.getSessionManager()?.pressBackspace();
        })

        this.renderSideActionKey('清空', (): void => {
          void imeRuntime.getSessionManager()?.clearActiveInput();
        })

        this.renderTallSideActionKey('换行', (): void => {
          void imeRuntime.getSessionManager()?.pressEnter();
        })
      }
      .width(70)
      .height(this.resolveReferenceNineKeyHeight())
    }
    .width('100%')
    .height(this.resolveReferenceNineKeyHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  private renderReferenceQwertyKeyboard() {
    // All four rows use layoutWeight sums that add up to 10 with `space: 6`
    // gaps, so every row renders with identical overall width and each
    // letter-weight-unit is (rowInnerWidth - gapsTotal) / 10 pixels wide.
    // That way letter keys across rows line up visually despite each row
    // having different numbers of children.
    Column({ space: 4 }) {
      // Row 1 — 10 letter keys (Q..P), weight 1 each; 9 gaps.
      Row({ space: 5 }) {
        ForEach(QWERTY_TOP_KEYS, (descriptor: QwertyKeyDescriptor) => {
          this.renderReferenceQwertyLetterKey(descriptor)
        }, (descriptor: QwertyKeyDescriptor): string => descriptor.value)
      }
      .width('100%')

      // Row 2 — 9 letter keys (A..L) with half-key transparent spacers on
      // each side, so letters sit offset from Row 1 the way iOS renders it.
      // Blank() (empty Column) + layoutWeight(0.5) gives a pixel-scaled
      // indent that tracks the panel width instead of a fixed pad.
      Row({ space: 5 }) {
        Column().layoutWeight(0.5)
        ForEach(QWERTY_MIDDLE_KEYS, (descriptor: QwertyKeyDescriptor) => {
          this.renderReferenceQwertyLetterKey(descriptor)
        }, (descriptor: QwertyKeyDescriptor): string => descriptor.value)
        Column().layoutWeight(0.5)
      }
      .width('100%')

      // Row 3 — ⇧ (weight 1.5) + 7 letters (weight 1) + ⌫ (weight 1.5) = 10.
      Row({ space: 5 }) {
        this.renderReferenceQwertySideKey('⇧', (): void => {
          this.qwertyShiftEnabled = !this.qwertyShiftEnabled;
        }, this.qwertyShiftEnabled, 1.5)

        ForEach(QWERTY_BOTTOM_KEYS, (descriptor: QwertyKeyDescriptor) => {
          this.renderReferenceQwertyLetterKey(descriptor)
        }, (descriptor: QwertyKeyDescriptor): string => descriptor.value)

        this.renderReferenceQwertySideKey('⌫', (): void => {
          void imeRuntime.getSessionManager()?.pressBackspace();
        }, false, 1.5)
      }
      .width('100%')

      // Row 4 — 符号(1.8) 中/英(1.1) !,(0.8) mic(2.5) ?.(0.8) 123(1.1) 完成(1.8)
      // = 9.9 total, visually matching the reference proportion where 符号 /
      // 完成 are the wide left/right anchors and mic is the space-bar-style
      // central key.
      Row({ space: 5 }) {
        this.renderReferenceQwertyBottomActionKey('符号', (): void => {
          this.showSymbolPalette = !this.showSymbolPalette;
        }, this.showSymbolPalette, 1.8)

        this.renderReferenceQwertyBottomActionKey(this.resolveQuickSwitchLabel(), (): void => {
          this.switchQuickSubtype();
        }, false, 1.1)

        this.renderReferenceQwertyPunctuationKey(this.resolveQwertyCommaLabel(), (): void => {
          void imeRuntime.getSessionManager()?.insertPunctuation(this.resolveQwertyCommaOutput());
        }, 0.8)

        this.renderReferenceQwertyVoiceKey(2.5)

        this.renderReferenceQwertyPunctuationKey(this.resolveQwertyPeriodLabel(), (): void => {
          void imeRuntime.getSessionManager()?.insertPunctuation(this.resolveQwertyPeriodOutput());
        }, 0.8)

        this.renderReferenceQwertyBottomActionKey('123', (): void => {
          if (this.supportsNineKey()) {
            void imeRuntime.getSessionManager()?.switchKeyboardLayout('t9_9');
          }
        }, false, 1.1, this.supportsNineKey())

        this.renderReferenceQwertyBottomActionKey('完成', (): void => {
          void imeRuntime.getSessionManager()?.pressEnter();
        }, false, 1.8)
      }
      .width('100%')
    }
    .width('100%')
    .height(this.resolveReferenceQwertyHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  private renderVoicePanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 16 }) {
        Stack() {
          // Outer pulse ring: continuously expands and fades to visually tell
          // the user the mic is actively listening / awaiting input. Driven by
          // voicePulseExpanded which toggles on a timer while the voice panel
          // is active. The inner ring is offset in phase so the two rings
          // form a breathing ripple.
          Column()
            .width(120)
            .height(120)
            .borderRadius(60)
            .backgroundColor(this.resolveVoicePulseColor())
            .opacity(this.voicePulseExpanded ? 0 : 0.28)
            .scale({ x: this.voicePulseExpanded ? 1.7 : 1, y: this.voicePulseExpanded ? 1.7 : 1 })
            .animation({ duration: 1400, curve: Curve.EaseOut, iterations: 1 })

          Column()
            .width(120)
            .height(120)
            .borderRadius(60)
            .backgroundColor(this.resolveVoicePulseColor())
            .opacity(this.voicePulseExpanded ? 0.22 : 0)
            .scale({ x: this.voicePulseExpanded ? 1 : 1.4, y: this.voicePulseExpanded ? 1 : 1.4 })
            .animation({ duration: 1400, curve: Curve.EaseOut, iterations: 1 })

          Button() {
            if (this.uiState.voiceState === 'recording') {
              Text('●')
                .fontSize(48)
                .fontColor('#FFFFFF')
            } else {
              this.renderIconAsset('mic', 48, 48)
            }
          }
          .width(120)
          .height(120)
          .type(ButtonType.Circle)
          .backgroundColor(
            this.uiState.voiceState === 'recording' ? '#B36D47' :
            this.uiState.voiceState === 'error' ? '#D9534F' : '#7A835E'
          )
          .opacity(this.uiState.voiceEnabled ? 1 : 0.65)
          .onClick(() => {
            this.startOrStopVoice();
          })
        }
        .width(220)
        .height(220)
        .alignContent(Alignment.Center)

        if (this.uiState.voiceState !== 'recording' && this.uiState.voiceStatusText.length > 0) {
          Text(this.uiState.voiceStatusText)
            .fontSize(12)
            .fontColor(this.uiState.voiceState === 'error' ? '#D9534F' : '#606168')
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // Realtime transcript overlay: anchored to the top-left of the voice
      // panel so text streams in from left to right and wraps downward,
      // visually overlapping the pulse rings and mic circle below. The
      // transparent hit-test keeps taps falling through to the record
      // button underneath.
      if (this.uiState.voiceTranscriptPreview.length > 0) {
        Text(this.uiState.voiceTranscriptPreview)
          .fontSize(16)
          .fontColor('#1C1C1F')
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Start)
          .maxLines(8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 0 })
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  private renderHeaderOutlineButton(label: string, action: () => void, enabled: boolean = true) {
    Button(label)
      .width(36)
      .height(36)
      .fontSize(label === '+' ? 18 : 15)
      .fontWeight(FontWeight.Medium)
      .fontColor(enabled ? '#1C1C1F' : '#C3C4CA')
      .backgroundColor('#FFFFFF')
      .border({
        width: enabled ? 1.5 : 1,
        color: enabled ? '#1C1C1F' : '#D7D8DD'
      })
      .borderRadius(16)
      .opacity(enabled ? 1 : 0.5)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  @Builder
  private renderReferenceQwertyHeaderButton(label: string, action: () => void, enabled: boolean = true) {
    Button(label)
      .width(38)
      .height(38)
      .fontSize(label === '+' ? 18 : 16)
      .fontWeight(FontWeight.Medium)
      .fontColor(enabled ? '#1C1D21' : '#C9CBD3')
      .backgroundColor('#FFFFFF')
      .border({
        width: 1.5,
        color: enabled ? '#1C1D21' : '#D4D6DC'
      })
      .borderRadius(19)
      .opacity(enabled ? 1 : 0.52)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  @Builder
  private renderHeaderSendButton() {
    Button('↑')
      .width(32)
      .height(32)
      .fontSize(17)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.canUseSendAction() ? '#FFFFFF' : '#F7FBF2')
      .backgroundColor(this.canUseSendAction() ? '#DAEBC4' : '#EEF5E5')
      .borderRadius(16)
      .opacity(this.canUseSendAction() ? 1 : 0.72)
      .onClick(() => {
        if (this.canUseSendAction()) {
          this.handleSendAction();
        }
      })
  }

  @Builder
  private renderFeatureIconButton(
    label: string,
    action: () => void,
    active: boolean = false,
    enabled: boolean = true,
    fontSize: number = 18
  ) {
    Text(label)
      .fontSize(fontSize)
      .fontColor(enabled ? (active ? '#1B1D22' : '#5D6069') : '#BABCC3')
      .width(40)
      .height(28)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  @Builder
  private renderFeatureIconAssetButton(
    kind: string,
    action: () => void,
    active: boolean = false,
    enabled: boolean = true
  ) {
    Column() {
      this.renderIconAsset(kind, this.resolveFeatureIconWidth(kind), 28, enabled ? 1 : 0.32)
    }
    .width(this.resolveFeatureButtonWidth(kind))
    .height(34)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(active ? '#EBF1E2' : 'rgba(0,0,0,0)')
    .borderRadius(17)
    .opacity(enabled ? 1 : 0.55)
    .onClick(() => {
      if (enabled) {
        action();
      }
    })
  }

  @Builder
  private renderIconAsset(kind: string, width: number, height: number, opacity: number = 1) {
    if (kind === 'tool') {
      Image($r('app.media.ime_icon_feature_tool'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'mic') {
      Image($r('app.media.ime_icon_feature_mic'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'style') {
      Image($r('app.media.ime_icon_feature_style'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'smile') {
      Image($r('app.media.ime_icon_feature_smile'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'chevron') {
      Image($r('app.media.ime_icon_feature_chevron_down'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'shift') {
      Image($r('app.media.ime_icon_key_shift'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'backspace') {
      Image($r('app.media.ime_icon_key_backspace'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'voicepad') {
      Image($r('app.media.ime_icon_key_voicepad'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'globe') {
      Image($r('app.media.ime_icon_bottom_globe'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'magic') {
      Image($r('app.media.ime_icon_bottom_magic'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    }
  }

  @Builder
  private renderSettingsIconAsset(kind: string, width: number, height: number, opacity: number = 1) {
    if (kind === 'collapse') {
      Image($r('app.media.ime_icon_settings_chevron_up'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'help') {
      Image($r('app.media.ime_icon_settings_help'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'gear') {
      Image($r('app.media.ime_icon_settings_gear'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'clipboard') {
      Image($r('app.media.ime_icon_settings_clipboard'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'edit') {
      Image($r('app.media.ime_icon_settings_edit'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'lexicon') {
      Image($r('app.media.ime_icon_settings_lexicon'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'font') {
      Image($r('app.media.ime_icon_settings_font'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'sound') {
      Image($r('app.media.ime_icon_settings_sound'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'skin') {
      Image($r('app.media.ime_icon_settings_skin'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'voice') {
      Image($r('app.media.ime_icon_feature_mic'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else {
      Text(kind)
        .fontSize(kind.length > 1 ? 18 : 24)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1D1E22')
        .opacity(opacity)
    }
  }

  @Builder
  private renderPunctuationRail() {
    Column({ space: 9 }) {
      ForEach(SIDE_PUNCTUATIONS, (symbol: string) => {
        Text(symbol)
          .fontSize(15)
          .fontColor('#171717')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
          .borderRadius(10)
          .stateStyles({ pressed: this.pressedWhiteKeyStyle })
          .onClick(() => {
            this.commitText(symbol);
          })
      }, (symbol: string): string => symbol)
    }
    .justifyContent(FlexAlign.SpaceAround)
    .width('100%')
    .height(this.resolveReferenceNineKeyGridHeight())
    .padding({ top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F6F7F9' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveWhiteKeyShadow())
  }

  @Builder
  private renderNineGridKey(descriptor: NineGridKeyDescriptor) {
    Column({ space: 4 }) {
      Text(descriptor.digit)
        .fontSize(10)
        .fontColor('#9B9CA3')

      Text(descriptor.label)
        .fontSize(descriptor.label.length > 2 ? 19 : 22)
        .minFontSize(13)
        .maxFontSize(descriptor.label.length > 2 ? 19 : 22)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .maxLines(1)
        .fontWeight(FontWeight.Medium)
        .fontColor('#161616')
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(this.resolveReferenceNineKeyRowHeight())
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F6F7F9' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      let sessionManager = imeRuntime.getSessionManager();
      hilog.info(PANEL_DOMAIN, PANEL_TAG,
        'nineGridKey click digit=%{public}s action=%{public}s sessionManagerPresent=%{public}s',
        descriptor.digit, descriptor.action, sessionManager ? 'true' : 'false');
      if (descriptor.action === 'digit') {
        void sessionManager?.typeNineKeyDigit(descriptor.value);
      } else {
        this.commitText(descriptor.value);
      }
    })
  }

  @Builder
  private renderSideActionKey(label: string, action: () => void) {
    Button() {
      if (label === '⌫') {
        this.renderIconAsset('backspace', 36, 28)
      } else {
        Text(label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#262626')
      }
    }
    .width('100%')
    .height(this.resolveReferenceNineKeyRowHeight())
    .backgroundColor('#C9CAD3')
    .border({ width: 1, color: '#CDD1D8' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      hilog.info(PANEL_DOMAIN, PANEL_TAG, 'sideActionKey click label=%{public}s', label);
      action();
    })
  }

  @Builder
  private renderTallSideActionKey(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .height(this.resolveReferenceNineKeyTallActionHeight())
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor('#262626')
      .backgroundColor('#C9CAD3')
      .border({ width: 1, color: '#CDD1D8' })
      .borderRadius(T9_KEY_RADIUS)
      .shadow(this.resolveGrayKeyShadow())
      .stateStyles({ pressed: this.pressedGrayKeyStyle })
      .onClick(() => {
        action();
      })
  }

  @Builder
  private renderBottomActionKey(
    label: string,
    active: boolean,
    action: () => void,
    enabled: boolean = true,
    weight: number = 1
  ) {
    // width('100%') makes the button fill its parent when used standalone
    // inside a Column (e.g. the 符号 key in the left column). Inside a Row
    // with multiple siblings, layoutWeight takes precedence over width on the
    // main axis, so middle-row keys still distribute by weight.
    Button() {
      if (label === this.resolveQuickSwitchLabel()) {
        this.renderNineQuickSwitchLabel(enabled)
      } else {
        Text(label)
          .fontSize(this.resolveBottomActionFontSize(label))
          .minFontSize(9)
          .maxFontSize(this.resolveBottomActionFontSize(label))
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .maxLines(1)
          .fontWeight(FontWeight.Medium)
          .fontColor(enabled ? '#202020' : '#B0B2B8')
      }
    }
    .width('100%')
    .layoutWeight(weight)
    .height(this.resolveReferenceNineKeyBottomHeight())
    .backgroundColor(active ? '#D8E1D1' : '#C9CAD3')
    .border({ width: 1, color: active ? '#DCE4D5' : '#CDD1D8' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveGrayKeyShadow())
    .opacity(enabled ? 1 : 0.55)
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      if (enabled) {
        action();
      }
    })
  }

  @Builder
  private renderVoicePadKey() {
    Column({ space: 4 }) {
      Text('0')
        .fontSize(10)
        .fontColor('#9B9CA3')

      this.renderIconAsset('voicepad', 62, 34)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(this.resolveReferenceNineKeyBottomHeight())
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F6F7F9' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveWhiteKeyShadow())
    .opacity(this.uiState.voiceEnabled ? 1 : 0.65)
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      if (this.uiState.voiceEnabled) {
        this.startOrStopVoice();
      } else {
        this.commitText(' ');
      }
    })
  }

  @Builder
  private renderReferenceQwertyLetterKey(descriptor: QwertyKeyDescriptor) {
    Column({ space: 1 }) {
      Text(descriptor.hint)
        .fontSize(8)
        .fontColor('#A4A6AD')

      Text(descriptor.label)
        .fontSize(15)
        .minFontSize(10)
        .maxFontSize(15)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .maxLines(1)
        .fontWeight(FontWeight.Normal)
        .fontColor('#17181C')
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(this.resolveReferenceQwertyRowHeight())
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F6F7F9' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      this.handleReferenceQwertyLetterInput(descriptor.value);
    })
  }

  @Builder
  private renderReferenceQwertySideKey(label: string, action: () => void, active: boolean = false,
    weight: number = 1.5) {
    // Row 3 side keys (⇧ / ⌫) must use layoutWeight so that their width scales
    // with the keyboard container. The reference iOS style keeps them ~1.5×
    // the letter key width; a fixed pixel width would drift away from the
    // letter grid whenever the panel is wider/narrower than the design spec.
    Button() {
      if (label === '⌫') {
        this.renderIconAsset('backspace', 34, 28)
      } else {
        this.renderIconAsset('shift', 34, 28)
      }
    }
    .layoutWeight(weight)
    .height(this.resolveReferenceQwertyRowHeight())
    .backgroundColor(active ? '#D9E3D0' : '#C9CAD3')
    .border({ width: 1, color: active ? '#DCE4D5' : '#CDD1D8' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderReferenceQwertyBottomActionKey(
    label: string,
    action: () => void,
    active: boolean = false,
    weight: number = 1,
    enabled: boolean = true
  ) {
    Button() {
      this.renderActionKeyLabel(label, this.resolveReferenceQwertyBottomFontSize(label), enabled)
    }
    .layoutWeight(weight)
    .height(this.resolveReferenceQwertyBottomHeight())
    .backgroundColor(active ? '#D9E3D0' : '#C9CAD3')
    .border({ width: 1, color: active ? '#DCE4D5' : '#CDD1D8' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveGrayKeyShadow())
    .opacity(enabled ? 1 : 0.52)
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      if (enabled) {
        action();
      }
    })
  }

  @Builder
  private renderActionKeyLabel(label: string, fontSize: number, enabled: boolean) {
    if (label === this.resolveQuickSwitchLabel()) {
      Row({ space: 0 }) {
        Text('中')
          .fontSize(fontSize + 5)
          .fontWeight(FontWeight.Medium)
          .fontColor(enabled ? '#1E2024' : '#B5B7BE')

        Text('/英')
          .fontSize(fontSize - 1)
          .fontWeight(FontWeight.Regular)
          .fontColor(enabled ? '#8D919A' : '#C3C5CB')
          .margin({ top: 5 })
      }
      .alignItems(VerticalAlign.Center)
    } else {
      Text(label)
        .fontSize(fontSize)
        .minFontSize(9)
        .maxFontSize(fontSize)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor(enabled ? '#232429' : '#B5B7BE')
        .maxLines(1)
    }
  }

  @Builder
  private renderNineQuickSwitchLabel(enabled: boolean) {
    Row({ space: 0 }) {
      Text('中')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(enabled ? '#1F2024' : '#B5B7BE')

      Text('/英')
        .fontSize(9)
        .fontWeight(FontWeight.Regular)
        .fontColor(enabled ? '#8E9199' : '#C3C5CB')
        .margin({ top: 5 })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderReferenceQwertyPunctuationKey(
    label: string,
    action: () => void,
    weight: number = 0.76
  ) {
    Column() {
      Text(label)
        .fontSize(18)
        .minFontSize(12)
        .maxFontSize(18)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .maxLines(1)
        .fontWeight(FontWeight.Medium)
        .fontColor('#16171B')
        .textAlign(TextAlign.Center)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(weight)
    .height(this.resolveReferenceQwertyBottomHeight())
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F6F7F9' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderReferenceQwertyVoiceKey(weight: number = 2.5) {
    // The mic key doubles as the space-bar in the 26-key layout so it should
    // span roughly 2.5× a letter key width, matching the wide central key in
    // the reference mockup. Weight is parameterised so callers can adjust per
    // layout variant.
    Column() {
      this.renderIconAsset('voicepad', 84, 36)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(weight)
    .height(this.resolveReferenceQwertyBottomHeight())
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F6F7F9' })
    .borderRadius(T9_KEY_RADIUS)
    .shadow(this.resolveWhiteKeyShadow())
    .opacity(this.uiState.voiceEnabled ? 1 : 0.65)
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      if (this.uiState.voiceEnabled) {
        this.startOrStopVoice();
      } else {
        this.commitText(' ');
      }
    })
  }

  private resolveReferenceNineKeyHeight(): number {
    return 226;
  }

  private resolveReferenceNineKeyGridHeight(): number {
    return 168;
  }

  private resolveReferenceNineKeyRowHeight(): number {
    return 52;
  }

  private resolveReferenceNineKeyBottomHeight(): number {
    return 50;
  }

  private resolveReferenceNineKeyTallActionHeight(): number {
    return 108;
  }

  private resolveWhiteKeyShadow(): ShadowOptions {
    return {
      radius: 1.2,
      color: '#30000000',
      offsetX: 0,
      offsetY: 2
    };
  }

  private resolveGrayKeyShadow(): ShadowOptions {
    return {
      radius: 1.2,
      color: '#24000000',
      offsetX: 0,
      offsetY: 2
    };
  }

  private resolveSettingsTabShadow(selected: boolean): ShadowOptions {
    if (selected) {
      return this.resolveWhiteKeyShadow();
    }
    return {
      radius: 0,
      color: '#00000000',
      offsetX: 0,
      offsetY: 0
    };
  }

  private resolveFeatureButtonWidth(kind: string): number {
    if (kind === 'tool' || kind === 'magic') {
      return 40;
    }
    if (kind === 'chevron') {
      return 36;
    }
    return 38;
  }

  private resolveFeatureIconWidth(kind: string): number {
    if (kind === 'tool' || kind === 'magic') {
      return 30;
    }
    if (kind === 'chevron') {
      return 26;
    }
    return 28;
  }

  private resolveBottomActionFontSize(label: string): number {
    if (label === '中/英') {
      return 10;
    }
    if (label === '符号') {
      return 14;
    }
    if (label === '123') {
      return 14;
    }
    return label.length > 2 ? 12 : 14;
  }

  private resolveReferenceQwertyHeight(): number {
    return 204;
  }

  private resolveReferenceQwertyRowHeight(): number {
    return 44;
  }

  private resolveReferenceQwertyBottomHeight(): number {
    return 42;
  }

  private resolveReferenceQwertyBottomFontSize(label: string): number {
    if (label === '中/英') {
      return 9;
    }
    if (label === '完成' || label === '符号') {
      return 12;
    }
    if (label === '123') {
      return 11;
    }
    return label.length > 2 ? 10 : 12;
  }

  private handleReferenceQwertyLetterInput(value: string): void {
    let committed = value;
    if (this.qwertyShiftEnabled && this.isEnglishSubtype()) {
      committed = value.toUpperCase();
      this.qwertyShiftEnabled = false;
    }
    this.commitText(committed);
  }

  private resolveQwertyCommaLabel(): string {
    return this.isEnglishSubtype() ? ',' : '，';
  }

  private resolveQwertyPeriodLabel(): string {
    return this.isEnglishSubtype() ? '.' : '。';
  }

  private resolveQwertyCommaOutput(): string {
    return this.isEnglishSubtype() ? ',' : '，';
  }

  private resolveQwertyPeriodOutput(): string {
    return this.isEnglishSubtype() ? '.' : '。';
  }

  private handlePrimaryToolbarAction(): void {
    if (this.uiState.voiceDraftText.length > 0) {
      void imeRuntime.getSessionManager()?.insertVoiceDraft();
      return;
    }
    if (this.uiState.showPolishSuggestion) {
      void imeRuntime.getSessionManager()?.acceptPolishSuggestion();
      return;
    }
    if (this.uiState.polishEnabled && this.uiState.canPolish && !this.uiState.isPolishRunning) {
      void imeRuntime.getSessionManager()?.polishPendingText();
      return;
    }
    if (this.uiState.candidates.length > 0) {
      void imeRuntime.getSessionManager()?.selectCandidate(0);
    }
  }

  private canUsePrimaryAction(): boolean {
    return this.uiState.voiceDraftText.length > 0 ||
      this.uiState.showPolishSuggestion ||
      (this.uiState.polishEnabled && this.uiState.canPolish && !this.uiState.isPolishRunning) ||
      this.uiState.candidates.length > 0;
  }

  private handleSendAction(): void {
    if (this.uiState.voiceDraftText.length > 0) {
      void imeRuntime.getSessionManager()?.insertVoiceDraft();
      return;
    }
    void imeRuntime.getSessionManager()?.pressEnter();
  }

  private canUseSendAction(): boolean {
    return this.uiState.sessionActive || this.uiState.voiceDraftText.length > 0;
  }

  private resolveVoicePulseColor(): string {
    if (this.uiState.voiceState === 'error') {
      return '#D9534F';
    }
    if (this.uiState.voiceState === 'recording') {
      return '#B36D47';
    }
    return '#7A835E';
  }

  private startOrStopVoice(): void {
    if (this.uiState.voiceState === 'recording') {
      void imeRuntime.getSessionManager()?.stopVoiceInput();
      return;
    }
    if (this.uiState.voiceState === 'processing') {
      // 处理中状态下点击，取消当前语音处理
      void imeRuntime.getSessionManager()?.clearActiveInput();
      return;
    }
    if (this.uiState.voiceState === 'idle' || this.uiState.voiceState === 'error') {
      void imeRuntime.getSessionManager()?.startVoiceInput();
    }
  }

  private commitText(text: string): void {
    void imeRuntime.getSessionManager()?.typeText(text);
  }

  private cycleKeyboardLayout(): void {
    if (this.uiState.availableKeyboardLayouts.length <= 1) {
      return;
    }
    let currentIndex = -1;
    for (let index = 0; index < this.uiState.availableKeyboardLayouts.length; index++) {
      if (this.uiState.availableKeyboardLayouts[index].id === this.uiState.keyboardLayout) {
        currentIndex = index;
        break;
      }
    }
    let nextIndex = currentIndex >= 0 ? (currentIndex + 1) % this.uiState.availableKeyboardLayouts.length : 0;
    let target = this.uiState.availableKeyboardLayouts[nextIndex];
    void imeRuntime.getSessionManager()?.switchKeyboardLayout(target.id);
  }

  private toggleReferenceLayoutStyle(): void {
    if (this.uiState.keyboardLayout === 't9_9' && this.supportsTwentySixKey()) {
      void imeRuntime.getSessionManager()?.switchKeyboardLayout('qwerty_26');
      return;
    }
    if (this.uiState.keyboardLayout === 'qwerty_26' && this.supportsNineKey()) {
      void imeRuntime.getSessionManager()?.switchKeyboardLayout('t9_9');
      return;
    }
    this.cycleKeyboardLayout();
  }

  private toggleSettingsOverlay(): void {
    if (this.showSettingsTray) {
      this.closeSettingsOverlay();
      return;
    }
    this.showSettingsTray = true;
    this.activeSettingsTab = 'common';
    this.showSymbolPalette = false;
  }

  private closeSettingsOverlay(): void {
    this.showSettingsTray = false;
    this.activeSettingsTab = 'common';
  }

  private supportsNineKey(): boolean {
    return this.hasLayoutOption('t9_9');
  }

  private supportsTwentySixKey(): boolean {
    return this.hasLayoutOption('qwerty_26');
  }

  private hasLayoutOption(layout: KeyboardLayoutId): boolean {
    for (let index = 0; index < this.uiState.availableKeyboardLayouts.length; index++) {
      if (this.uiState.availableKeyboardLayouts[index].id === layout) {
        return true;
      }
    }
    return false;
  }

  private resolveQuickSwitchLabel(): string {
    return '中/英';
  }

  private isEnglishSubtype(): boolean {
    return this.uiState.currentSubtypeId.startsWith('en-');
  }

  private switchQuickSubtype(): void {
    let targetSubtype = this.resolveQuickSwitchSubtypeId();
    if (targetSubtype.length === 0) {
      return;
    }
    void imeRuntime.getSessionManager()?.switchSubtype(targetSubtype);
  }

  private switchSettingsSubtype(preferredSubtypeId: string): void {
    let targetSubtype = this.findSubtypeById(preferredSubtypeId);
    if (targetSubtype.length === 0) {
      targetSubtype = preferredSubtypeId.startsWith('zh') ? this.findFirstSubtypeByLocale('zh') :
        this.findFirstSubtypeByLocale('en');
    }
    if (targetSubtype.length === 0) {
      return;
    }
    void imeRuntime.getSessionManager()?.switchSubtype(targetSubtype);
    this.closeSettingsOverlay();
  }

  private resolveQuickSwitchSubtypeId(): string {
    if (this.uiState.currentSubtypeId.startsWith('en-')) {
      let zhSubtype = this.findSubtypeById('zh-Hans-pinyin');
      return zhSubtype.length > 0 ? zhSubtype : this.findFirstSubtypeByLocale('zh');
    }
    let englishSubtype = this.findSubtypeById('en-US-qwerty');
    if (englishSubtype.length > 0) {
      return englishSubtype;
    }
    return this.findFirstSubtypeByLocale('en');
  }

  private findSubtypeById(subtypeId: string): string {
    for (let index = 0; index < this.uiState.availableSubtypes.length; index++) {
      if (this.uiState.availableSubtypes[index].id === subtypeId) {
        return subtypeId;
      }
    }
    return '';
  }

  private findFirstSubtypeByLocale(prefix: string): string {
    for (let index = 0; index < this.uiState.availableSubtypes.length; index++) {
      if (this.uiState.availableSubtypes[index].id.startsWith(prefix)) {
        return this.uiState.availableSubtypes[index].id;
      }
    }
    return '';
  }

  private resolveComposeHeadline(): string {
    if (this.uiState.voiceDraftText.length > 0) {
      return this.uiState.voiceDraftText;
    }
    if (this.uiState.preedit.length > 0) {
      return this.uiState.preedit;
    }
    if (this.uiState.activeNineKeySpelling.length > 0) {
      return this.uiState.activeNineKeySpelling;
    }
    if (this.uiState.candidates.length > 0) {
      return this.uiState.candidates[0].text;
    }
    return '';
  }

  private resolveComposeSubline(): string {
    if (this.uiState.voiceDraftText.length > 0) {
      return '点 + 或 ↑ 直接插入草稿';
    }
    if (this.uiState.showPolishSuggestion) {
      return '有润色建议待处理';
    }
    if (this.uiState.preedit.length > 0 || this.uiState.candidates.length > 0) {
      return `候选第 ${this.uiState.candidatePageNo + 1} 页`;
    }
    if (this.uiState.activeNineKeySpelling.length > 0 || this.uiState.nineKeySequence.length > 0) {
      return this.uiState.nineKeySequence.length > 0 ? `9 键编码 ${this.uiState.nineKeySequence}` : '9 键拼音';
    }
    return '';
  }

  private resolveCandidatePlaceholder(): string {
    if (this.uiState.activeNineKeySpelling.length > 0 || this.uiState.nineKeySequence.length > 0) {
      return '继续输入 9 键拼音';
    }
    if (this.uiState.sessionActive) {
      return '输入后显示候选';
    }
    return '等待输入';
  }

  private resolveLayoutIconLabel(): string {
    switch (this.uiState.keyboardLayout) {
      case 't9_9':
        return '9';
      case 'voice_panel':
        return '语';
      default:
        return '123';
    }
  }

  private resolveLayoutDisplayLabel(layout: KeyboardLayoutId): string {
    switch (layout) {
      case 't9_9':
        return '9 键';
      case 'voice_panel':
        return '语音';
      default:
        return '26 键';
    }
  }

  private shouldShowCandidateStrip(): boolean {
    return this.showSymbolPalette ||
      this.uiState.preedit.length > 0 ||
      this.uiState.candidates.length > 0 ||
      this.uiState.activeNineKeySpelling.length > 0 ||
      this.uiState.nineKeySpellings.length > 0;
  }

  private resolveSettingsPagerIndex(): number {
    if (this.activeSettingsTab === 'input') {
      return 1;
    }
    return 0;
  }
}
