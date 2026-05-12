import { hilog } from '@kit.PerformanceAnalysisKit';
import display from '@ohos.display';
import pasteboard from '@ohos.pasteboard';
import {
  BuiltinModelPreset,
  BuiltinModelProvider,
  CandidateItem,
  KeyboardLayoutId,
  KeyboardLayoutOption,
  OffhandRuntimeSettings,
  SubtypeSummary,
  VoicePolishPromptMode
} from '../common/ImeTypes';
import { imeRuntime } from '../runtime/ImeRuntime';
import { KeyboardUiState, keyboardStateStore } from '../session/KeyboardStateStore';
import { listBuiltinModelProviders, resolveBuiltinModelSelection } from '../config/BuiltinModels';
import { LlmSelectionSnapshot } from '../session/SessionManager';
import { formatDirectPinyinRawInput } from '../session/DirectPinyinInput';
import {
  DEFAULT_VOICE_POLISH_PROMPT,
  normalizeVoicePolishPromptMode,
  normalizeVoicePolishPromptTemplate
} from '../llm/DefaultPolishPrompt';
import {
  listVoiceTranslationTargets,
  resolveVoiceTranslationTarget,
  VoiceTranslationTarget
} from '../llm/VoiceTranslationTarget';

const PANEL_DOMAIN: number = 0xFF10;
const PANEL_TAG: string = 'KeyboardPanel';
const BACKSPACE_LONG_PRESS_DURATION_MS: number = 450;
const BACKSPACE_REPEAT_INTERVAL_MS: number = 70;
const BACKSPACE_CLICK_SUPPRESSION_MS: number = 250;
const VOICE_ANIMATION_INTERVAL_MS: number = 760;

const LETTER_ROW_TOP: string[] = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
const LETTER_ROW_MIDDLE: string[] = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
const LETTER_ROW_BOTTOM: string[] = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
const SIDE_PUNCTUATIONS: string[] = ['，', '。', '？', '！'];
const COMMON_SYMBOLS: string[] = ['，', '。', '？', '！', '@', '#', '/', '-', '_', ':', ';', '(', ')'];
const SYMBOL_CATEGORY_KEYS: string[] = ['?', '-', '%', '{', '}', '《', '》'];
// Keep the tool bar at the original fixed height; preedit/candidates are
// rendered as a temporary floating layer above it so keyboard height stays
// stable while typing.
const FEATURE_ROW_HEIGHT: number = 40;
const TOP_ACCESSORY_HEIGHT: number = FEATURE_ROW_HEIGHT;
const PANEL_TOP_PADDING: number = 4;
const PANEL_BOTTOM_SAFE_GAP: number = 5;
const CANDIDATE_TOOLBAR_OVERLAY_HEIGHT: number = FEATURE_ROW_HEIGHT;
const CANDIDATE_SEPARATOR_SEGMENTS: number[] = [0, 1, 2, 3, 4, 5];
// Expanded candidate board proportions are based on the 1080px reference
// image, but applied as layout weights so the board scales with the actual
// keyboard width instead of using screenshot pixels as vp values.
const EXPANDED_CANDIDATE_SIDE_WEIGHT: number = 178;
const EXPANDED_CANDIDATE_GRID_WEIGHT: number = 638;
const EXPANDED_CANDIDATE_ACTION_WEIGHT: number = 178;
const EXPANDED_CANDIDATE_GAP: number = 6;
const EXPANDED_CANDIDATE_ACTION_ARROW_WEIGHT: number = 2.12;
const EXPANDED_CANDIDATE_TOP_PADDING: number = 3;
const EXPANDED_CANDIDATE_BOTTOM_PADDING: number = PANEL_BOTTOM_SAFE_GAP;
const EXPANDED_CANDIDATE_TEXT_PADDING: number = 4;
const EXPANDED_CANDIDATE_FONT_SIZE: number = 24;
const EXPANDED_PINYIN_FONT_SIZE: number = 20;
const EXPANDED_ACTION_FONT_SIZE: number = 20;
const EXPANDED_ACTION_SECONDARY_FONT_SIZE: number = 14;
const EXPANDED_ARROW_FONT_SIZE: number = 38;
const EXPANDED_ARROW_TEXT_HEIGHT: number = 42;
const EXPANDED_CANDIDATE_ROWS: number[] = [0, 1, 2, 3, 4, 5];
const EXPANDED_CANDIDATE_COLUMNS: number[] = [0, 1, 2, 3];
const EXPANDED_PINYIN_ROWS: number[] = [0, 1, 2, 3, 4, 5];
// iOS-style T9 keys: tighter corner radius gives a flatter, more grid-aligned
// look than the previous 18 which made keys feel floaty and slightly
// misaligned with neighbors.
const T9_KEY_RADIUS: number = 8;
const QWERTY_KEY_RADIUS: number = 8;
const QWERTY_KEY_GAP: number = 5;
const QWERTY_REFERENCE_CONTENT_WIDTH: number = 344;
const QWERTY_REFERENCE_HEIGHT: number = 226;
const QWERTY_REFERENCE_ROW_HEIGHT: number = 46;
const QWERTY_REFERENCE_ROW_GAP: number = 14;
const QWERTY_REFERENCE_HORIZONTAL_PADDING: number = 16;
const QWERTY_MIN_CONTENT_WIDTH: number = 280;
const QWERTY_BOTTOM_SIDE_WEIGHT: number = 1.64;
const QWERTY_BOTTOM_QUICK_WEIGHT: number = 1.2;
const QWERTY_BOTTOM_PUNCTUATION_WEIGHT: number = 1;
const QWERTY_BOTTOM_SPACE_WEIGHT: number = 2.95;
const QWERTY_WHITE_KEY_COLOR: string = '#FFFFFF';
const QWERTY_GRAY_KEY_COLOR: string = '#C2C6CE';
const QWERTY_GRAY_KEY_BORDER_COLOR: string = '#B8BDC7';
const QWERTY_ACTIVE_KEY_COLOR: string = '#D9E3D0';
const QWERTY_ACTIVE_KEY_BORDER_COLOR: string = '#D0D9C8';
const NUMBER_KEYBOARD_REFERENCE_CONTENT_WIDTH: number = 344;
const NUMBER_KEYBOARD_REFERENCE_ROW_HEIGHT: number = 52;
const NUMBER_KEYBOARD_REFERENCE_GAP: number = 6;
const NUMBER_KEYBOARD_SIDE_WEIGHT: number = 58;
const NUMBER_KEYBOARD_DIGIT_GROUP_WEIGHT: number = 216;
const NUMBER_KEYBOARD_DIGIT_FONT_SIZE: number = 22;
const NUMBER_KEYBOARD_ACTION_FONT_SIZE: number = 18;
const NUMBER_KEYBOARD_OPERATOR_FONT_SIZE: number = 20;
const NUMBER_OPERATOR_KEYS: string[] = ['+', '-', '=', '/'];
const NUMBER_DIGIT_ROWS: string[][] = [
  ['1', '2', '3'],
  ['4', '5', '6'],
  ['7', '8', '9']
];

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

type SymbolKeyRole = 'text' | 'more' | 'backspace' | 'return' | 'space' | 'enter';
type SymbolKeyboardVariant = 'symbol' | 'number';
type VoiceToolAction = 'polish' | 'translate' | 'clear' | 'back';

interface SymbolKeyDescriptor {
  label: string;
  output: string;
  role: SymbolKeyRole;
  weight: number;
  gray: boolean;
}

interface VoiceToolDescriptor {
  label: string;
  action: VoiceToolAction;
  centerXRatio: number;
  top: number;
}

const VOICE_TOOL_ACTIONS: VoiceToolDescriptor[] = [
  { label: '润色', action: 'polish', centerXRatio: 0.235, top: 128 },
  { label: '翻译', action: 'translate', centerXRatio: 0.405, top: 158 },
  { label: '清空', action: 'clear', centerXRatio: 0.595, top: 158 },
  { label: '回退', action: 'back', centerXRatio: 0.765, top: 128 }
];

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

const SYMBOL_DIGIT_ROW: SymbolKeyDescriptor[] = [
  { label: '1', output: '1', role: 'text', weight: 1, gray: false },
  { label: '2', output: '2', role: 'text', weight: 1, gray: false },
  { label: '3', output: '3', role: 'text', weight: 1, gray: false },
  { label: '4', output: '4', role: 'text', weight: 1, gray: false },
  { label: '5', output: '5', role: 'text', weight: 1, gray: false },
  { label: '6', output: '6', role: 'text', weight: 1, gray: false },
  { label: '7', output: '7', role: 'text', weight: 1, gray: false },
  { label: '8', output: '8', role: 'text', weight: 1, gray: false },
  { label: '9', output: '9', role: 'text', weight: 1, gray: false },
  { label: '0', output: '0', role: 'text', weight: 1, gray: false }
];

const SYMBOL_PRIMARY_ROW_2: SymbolKeyDescriptor[] = [
  { label: '-', output: '-', role: 'text', weight: 1, gray: false },
  { label: '/', output: '/', role: 'text', weight: 1, gray: false },
  { label: ':', output: ':', role: 'text', weight: 1, gray: false },
  { label: ';', output: ';', role: 'text', weight: 1, gray: false },
  { label: '(', output: '(', role: 'text', weight: 1, gray: false },
  { label: ')', output: ')', role: 'text', weight: 1, gray: false },
  { label: '_', output: '_', role: 'text', weight: 1, gray: false },
  { label: '$', output: '$', role: 'text', weight: 1, gray: false },
  { label: '&', output: '&', role: 'text', weight: 1, gray: false }
];

const SYMBOL_PRIMARY_ROW_3: SymbolKeyDescriptor[] = [
  { label: '更多', output: '', role: 'more', weight: 1.35, gray: true },
  { label: '"', output: '"', role: 'text', weight: 1, gray: false },
  { label: '~', output: '~', role: 'text', weight: 1, gray: false },
  { label: '...', output: '…', role: 'text', weight: 1, gray: false },
  { label: '@', output: '@', role: 'text', weight: 1, gray: false },
  { label: '?', output: '?', role: 'text', weight: 1, gray: false },
  { label: '!', output: '!', role: 'text', weight: 1, gray: false },
  { label: '\'', output: '\'', role: 'text', weight: 1, gray: false },
  { label: '⌫', output: '', role: 'backspace', weight: 1.35, gray: true }
];

const SYMBOL_MORE_ROW_2: SymbolKeyDescriptor[] = [
  { label: '[', output: '[', role: 'text', weight: 1, gray: false },
  { label: ']', output: ']', role: 'text', weight: 1, gray: false },
  { label: '<', output: '<', role: 'text', weight: 1, gray: false },
  { label: '>', output: '>', role: 'text', weight: 1, gray: false },
  { label: '#', output: '#', role: 'text', weight: 1, gray: false },
  { label: '%', output: '%', role: 'text', weight: 1, gray: false },
  { label: '+', output: '+', role: 'text', weight: 1, gray: false },
  { label: '=', output: '=', role: 'text', weight: 1, gray: false },
  { label: '*', output: '*', role: 'text', weight: 1, gray: false }
];

const SYMBOL_MORE_ROW_3: SymbolKeyDescriptor[] = [
  { label: '常用', output: '', role: 'more', weight: 1.35, gray: true },
  { label: '&', output: '&', role: 'text', weight: 1, gray: false },
  { label: '_', output: '_', role: 'text', weight: 1, gray: false },
  { label: '\\', output: '\\', role: 'text', weight: 1, gray: false },
  { label: '|', output: '|', role: 'text', weight: 1, gray: false },
  { label: '¥', output: '¥', role: 'text', weight: 1, gray: false },
  { label: '$', output: '$', role: 'text', weight: 1, gray: false },
  { label: '€', output: '€', role: 'text', weight: 1, gray: false },
  { label: '⌫', output: '', role: 'backspace', weight: 1.35, gray: true }
];

@Entry
@Component
struct KeyboardPanel {
  @State private uiState: KeyboardUiState = keyboardStateStore.getSnapshot();
  @State private showSettingsTray: boolean = false;
  @State private activeSettingsTab: string = 'input';
  @State private showSymbolPalette: boolean = false;
  @State private showSymbolKeyboard: boolean = false;
  @State private symbolKeyboardVariant: SymbolKeyboardVariant = 'symbol';
  @State private symbolKeyboardMorePage: boolean = false;
  @State private showExpandedCandidateBoard: boolean = false;
  @State private expandedCandidateSingleMode: boolean = false;
  @State private expandedCandidatePageNo: number = 0;
  @State private expandedCandidateCanPageBackward: boolean = false;
  // Pulse ring state for the voice waiting circle. `voicePulseExpanded`
  // toggles every PULSE_INTERVAL_MS so the outer rings animate out/in
  // continuously while we are waiting for the user to keep speaking.
  @State private voicePulseExpanded: boolean = false;
  // LLM settings tab state: selection + API key editor buffers. These are
  // seeded from SessionManager.getLlmSelectionSnapshot when the tab opens.
  @State private llmDialogProviderId: string = '';
  @State private llmDialogPresetId: string = '';
  @State private llmDialogApiKey: string = '';
  @State private llmPromptTemplateMode: VoicePolishPromptMode = 'default';
  @State private llmPromptTemplate: string = DEFAULT_VOICE_POLISH_PROMPT;
  // Toggles masking on the API Key input; matches the eye icon in the mockup.
  @State private llmApiKeyRevealed: boolean = false;
  @State private llmSaveStatus: string = '';
  @State private runtimeEnableBuiltinAsr: boolean = true;
  @State private runtimeEnableCloudPolish: boolean = true;
  @State private runtimeAutoPolishVoiceResult: boolean = true;
  @State private llmTranslateTargetLanguage: string = 'en';
  @State private runtimeSaveStatus: string = '';
  @State private pendingQuickSubtypeId: string = '';
  private voicePulseTimer?: number;
  private qwertyLongPressSuppressTimer?: number;
  private backspaceRepeatTimer?: number;
  private backspaceLongPressSuppressTimer?: number;
  private pendingQuickSubtypeClearTimer?: number;
  private suppressNextQwertyLetterClick: boolean = false;
  private suppressNextBackspaceClick: boolean = false;
  private unsubscribe?: () => void;
  private lastNonVoiceSubtypeId: string = 'zh-Hans-pinyin';
  private lastNonVoiceKeyboardLayout: KeyboardLayoutId = 'qwerty_26';
  private lastChineseSubtypeId: string = 'zh-Hans-pinyin';
  private lastChineseKeyboardLayout: KeyboardLayoutId = 'qwerty_26';
  private lastEnglishSubtypeId: string = 'en-US-qwerty';
  private lastEnglishKeyboardLayout: KeyboardLayoutId = 'qwerty_26';

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
      let previousExpandedCandidateInput = this.resolveExpandedCandidateInputSignature(this.uiState);
      this.uiState = state;
      if (this.pendingQuickSubtypeId.length > 0 && state.currentSubtypeId === this.pendingQuickSubtypeId) {
        this.clearPendingQuickSubtype();
      }
      this.syncExpandedCandidatePageState(state, previousExpandedCandidateInput);
      if (state.keyboardLayout !== 'voice_panel') {
        this.lastNonVoiceSubtypeId = state.currentSubtypeId;
        this.lastNonVoiceKeyboardLayout = state.keyboardLayout;
        if (state.currentSubtypeId.startsWith('zh-') && state.currentSubtypeId !== 'zh-CN-voice') {
          this.lastChineseSubtypeId = state.currentSubtypeId;
          this.lastChineseKeyboardLayout = state.keyboardLayout;
        }
        if (state.currentSubtypeId.startsWith('en-')) {
          this.lastEnglishSubtypeId = state.currentSubtypeId;
          this.lastEnglishKeyboardLayout = state.keyboardLayout;
        }
      }
      if (!state.sessionActive) {
        if (!this.showSettingsTray) {
          this.showSymbolPalette = false;
          this.showSymbolKeyboard = false;
          this.symbolKeyboardMorePage = false;
          this.showExpandedCandidateBoard = false;
          this.activeSettingsTab = 'input';
        }
      }
      if (state.keyboardLayout === 'voice_panel') {
        this.showSymbolKeyboard = false;
        this.symbolKeyboardMorePage = false;
        this.showExpandedCandidateBoard = false;
      }
      if (!this.canShowExpandedCandidateBoard(state)) {
        this.showExpandedCandidateBoard = false;
        this.expandedCandidatePageNo = 0;
        this.expandedCandidateCanPageBackward = false;
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
    this.clearQwertyLongPressSuppressTimer();
    this.stopBackspaceRepeat();
    this.clearBackspaceLongPressSuppressTimer();
    this.clearPendingQuickSubtype();
  }

  private syncVoicePulseAnimation(state: KeyboardUiState): void {
    // Pulse only while capture is starting or actively recording.
    let shouldPulse = state.keyboardLayout === 'voice_panel'
      && (state.voiceState === 'recording' || state.voiceState === 'starting')
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
    // the initial timer dead zone.
    this.voicePulseExpanded = true;
    this.voicePulseTimer = setInterval((): void => {
      this.voicePulseExpanded = !this.voicePulseExpanded;
    }, VOICE_ANIMATION_INTERVAL_MS);
  }

  private stopVoicePulseAnimation(): void {
    if (this.voicePulseTimer !== undefined) {
      clearInterval(this.voicePulseTimer);
      this.voicePulseTimer = undefined;
    }
    this.voicePulseExpanded = false;
  }

  private clearQwertyLongPressSuppressTimer(): void {
    if (this.qwertyLongPressSuppressTimer !== undefined) {
      clearTimeout(this.qwertyLongPressSuppressTimer);
      this.qwertyLongPressSuppressTimer = undefined;
    }
  }

  private clearBackspaceLongPressSuppressTimer(): void {
    if (this.backspaceLongPressSuppressTimer !== undefined) {
      clearTimeout(this.backspaceLongPressSuppressTimer);
      this.backspaceLongPressSuppressTimer = undefined;
    }
  }

  private handleBackspaceClick(): void {
    if (this.suppressNextBackspaceClick) {
      this.suppressNextBackspaceClick = false;
      this.clearBackspaceLongPressSuppressTimer();
      return;
    }
    this.pressBackspaceOnce();
  }

  private pressBackspaceOnce(): void {
    void imeRuntime.getSessionManager()?.pressBackspace();
  }

  private startBackspaceRepeat(): void {
    if (this.backspaceRepeatTimer !== undefined) {
      return;
    }
    this.pressBackspaceOnce();
    this.backspaceRepeatTimer = setInterval((): void => {
      this.pressBackspaceOnce();
    }, BACKSPACE_REPEAT_INTERVAL_MS);
  }

  private stopBackspaceRepeat(): void {
    if (this.backspaceRepeatTimer !== undefined) {
      clearInterval(this.backspaceRepeatTimer);
      this.backspaceRepeatTimer = undefined;
    }
  }

  private finishBackspaceRepeat(): void {
    this.stopBackspaceRepeat();
    this.armBackspaceLongPressClickSuppression();
  }

  private armBackspaceLongPressClickSuppression(): void {
    this.suppressNextBackspaceClick = true;
    this.clearBackspaceLongPressSuppressTimer();
    this.backspaceLongPressSuppressTimer = setTimeout((): void => {
      this.suppressNextBackspaceClick = false;
      this.backspaceLongPressSuppressTimer = undefined;
    }, BACKSPACE_CLICK_SUPPRESSION_MS);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.showSettingsTray) {
        if (this.showExpandedCandidateBoard && this.canShowExpandedCandidateBoard(this.uiState)) {
          this.renderExpandedCandidateKeyboard()
        } else {
          Column({ space: 0 }) {
            this.renderTopAccessoryArea()

            if (this.showSymbolKeyboard) {
              this.renderReferenceSymbolKeyboard();
            } else {
              if (this.uiState.keyboardLayout !== 'voice_panel') {
                this.renderPolishSuggestionStrip()
              }

              if (this.uiState.keyboardLayout === 'voice_panel') {
                this.renderVoicePanel();
              } else if (this.uiState.keyboardLayout === 't9_9') {
                this.renderReferenceNineKeyKeyboard();
              } else {
                this.renderReferenceQwertyKeyboard();
              }
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 8, right: 8, top: PANEL_TOP_PADDING, bottom: PANEL_BOTTOM_SAFE_GAP })
          .backgroundColor(this.resolveKeyboardPanelBackgroundColor())

          if (!this.showSymbolKeyboard && this.shouldShowCandidateStrip()) {
            this.renderCandidateToolbarOverlay()
          }
        }

        if (this.uiState.isInputLoading) {
          this.renderInputLoadingOverlay()
        }
      } else {
        Column({ space: 0 }) {
          this.renderSettingsOverlay()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 8, top: PANEL_TOP_PADDING, bottom: PANEL_BOTTOM_SAFE_GAP })
        .backgroundColor('#D9DCE2')
        .zIndex(10)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.resolveKeyboardPanelBackgroundColor())
  }

  private resolveKeyboardPanelBackgroundColor(): string {
    if (!this.showSettingsTray && !this.showSymbolKeyboard && this.uiState.keyboardLayout === 'voice_panel') {
      return this.resolveVoicePanelBackgroundColor();
    }
    return '#D9DCE2';
  }

  private resolveVoicePanelBackgroundColor(): string {
    return '#EEF3FF';
  }

  @Builder
  private renderInputLoadingOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(217,220,226,0.82)')

      Column({ space: 10 }) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color('#3478F6')

        Text($r('app.string.ime_loading_input_engine'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#20242B')
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .width(168)
      .height(92)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('rgba(255,255,255,0.88)')
      .border({ width: 1, color: '#EFF1F5' })
      .borderRadius(14)
      .shadow({
        radius: 14,
        color: '#18000000',
        offsetX: 0,
        offsetY: 6
      })
    }
    .width('100%')
    .height('100%')
    .zIndex(30)
    .hitTestBehavior(HitTestMode.Block)
  }

  @Builder
  private renderTopAccessoryArea() {
    Column() {
      if (this.showSymbolKeyboard && this.symbolKeyboardVariant === 'symbol') {
        this.renderSymbolKeyboardHeader()
      } else {
        this.renderFeatureRow()
      }
    }
    .width('100%')
    .height(TOP_ACCESSORY_HEIGHT)
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
        this.showExpandedCandidateBoard = false;
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
        this.showExpandedCandidateBoard = false;
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
    // Top feature bar exposes a direct voice/keyboard mode toggle on the
    // right. The icon follows the active mode: keyboard icon inside the
    // voice panel, mic icon inside regular keyboard mode.
    Row() {
      this.renderFeatureIconAssetButton('gear', (): void => {
        this.toggleSettingsOverlay();
      }, this.showSettingsTray)

      Row({ space: 10 }) {
        this.renderInputModeFeatureButton()

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
    .height(FEATURE_ROW_HEIGHT)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
  }

  @Builder
  private renderSettingsOverlay() {
    Column({ space: 0 }) {
      this.renderSettingsHeader()

      Blank()
        .height(8)

      if (this.activeSettingsTab === 'voicePolish') {
        this.renderLlmSettingsGrid()
      } else if (this.activeSettingsTab === 'voicePolishModel') {
        this.renderLlmModelSettingsGrid()
      } else if (this.activeSettingsTab === 'voicePolishPrompt') {
        this.renderLlmPromptSettingsGrid()
      } else if (this.activeSettingsTab === 'voiceTranslateTarget') {
        this.renderVoiceTranslateTargetSettingsGrid()
      } else {
        List({ space: 12 }) {
          ListItem() {
            if (this.activeSettingsTab === 'input') {
              this.renderInputSettingsGrid()
            } else {
              this.renderCommonSettingsGrid()
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 0, right: 0, top: 0, bottom: 8 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  private renderSettingsHeader() {
    if (this.activeSettingsTab === 'voicePolish' ||
      this.activeSettingsTab === 'voicePolishModel' ||
      this.activeSettingsTab === 'voicePolishPrompt' ||
      this.activeSettingsTab === 'voiceTranslateTarget') {
      this.renderVoicePolishSettingsHeader()
    } else {
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
          this.renderSettingsTabButton('input', $r('app.string.ime_settings_tab_input'))
          this.renderSettingsTabButton('common', $r('app.string.ime_settings_tab_common'))
        }
        .layoutWeight(1)
        .height(48)
        .padding({ left: 3, right: 3, top: 3, bottom: 3 })
        .backgroundColor('#D4D7DC')
        .borderRadius(24)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  private renderVoicePolishSettingsHeader() {
    Row({ space: 10 }) {
      Button() {
        Text('‹')
          .fontSize(28)
          .fontColor('#30333A')
          .fontWeight(FontWeight.Medium)
          .height('100%')
          .textAlign(TextAlign.Center)
      }
      .width(42)
      .height(42)
      .backgroundColor('#D4D7DC')
      .borderRadius(21)
      .padding({ left: 0, right: 0, top: 0, bottom: 0 })
      .shadow(this.resolveGrayKeyShadow())
      .onClick(() => {
        this.returnFromVoiceAutoPolishSettings();
      })

      Text(this.resolveVoicePolishHeaderTitle())
        .layoutWeight(1)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17181B')
        .maxLines(1)
        .textAlign(TextAlign.Start)

      Button() {
        this.renderSettingsIconAsset('collapse', 22, 22)
      }
      .width(42)
      .height(42)
      .backgroundColor('#D4D7DC')
      .borderRadius(21)
      .padding({ left: 0, right: 0, top: 0, bottom: 0 })
      .shadow(this.resolveGrayKeyShadow())
      .onClick(() => {
        this.closeVoiceAutoPolishSettings();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private resolveVoicePolishHeaderTitle(): ResourceStr {
    if (this.activeSettingsTab === 'voicePolishModel') {
      return $r('app.string.ime_model_settings_title');
    }
    if (this.activeSettingsTab === 'voicePolishPrompt') {
      return $r('app.string.ime_polish_prompt_title');
    }
    if (this.activeSettingsTab === 'voiceTranslateTarget') {
      return '翻译目标语言';
    }
    return $r('app.string.ime_voice_auto_polish');
  }

  @Builder
  private renderSettingsTabButton(tabId: string, label: ResourceStr) {
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
        if (tabId === 'common') {
          this.seedRuntimeSettingsState();
        }
      })
  }

  @Builder
  private renderCommonSettingsGrid() {
    Column({ space: 8 }) {
      // All runtime toggles live in a single card so the tab reads as one
      // coherent settings block rather than three stacked chips.
      Column() {
        this.renderRuntimeToggleRow(
          $r('app.string.ime_builtin_asr'),
          this.runtimeEnableBuiltinAsr,
          (next: boolean): void => {
            this.runtimeEnableBuiltinAsr = next;
            this.persistRuntimeSettings(next ? '已启用系统内置语音识别' : '已关闭系统内置语音识别，使用端侧 SenseVoice');
          },
          true,
          false
        )
        this.renderVoiceAutoPolishSettingsRow()
      }
      .width('100%')
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#F0F2F6' })
      .borderRadius(18)
      .shadow(this.resolveWhiteKeyShadow())

      if (this.runtimeSaveStatus.length > 0) {
        Text(this.runtimeSaveStatus)
          .fontSize(12)
          .fontColor('#3478F6')
          .width('100%')
          .padding({ left: 4 })
      }
    }
    .width('100%')
    .padding({ left: 0, right: 0, bottom: 4 })
  }

  @Builder
  private renderVoiceAutoPolishSettingsRow() {
    Column() {
      Divider()
        .strokeWidth(1)
        .color('#F0F2F6')
        .width('100%')

      Row({ space: 12 }) {
        Text($r('app.string.ime_voice_auto_polish'))
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)

        Button() {
          Text('›')
            .fontSize(23)
            .fontColor('#7A7D82')
            .height('100%')
            .textAlign(TextAlign.Center)
        }
        .width(30)
        .height(34)
        .backgroundColor('rgba(0,0,0,0)')
        .padding({ left: 0, right: 0, top: 0, bottom: 0 })
        .onClick(() => {
          this.openVoiceAutoPolishSettings();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 10, top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openVoiceAutoPolishSettings();
      })
    }
    .width('100%')
  }

  @Builder
  private renderRuntimeToggleRow(title: ResourceStr, enabled: boolean, action: (next: boolean) => void, active: boolean, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .strokeWidth(1)
          .color('#F0F2F6')
          .width('100%')
      }
      Row({ space: 12 }) {
        Text(title)
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(active ? '#17181B' : '#8A8E97')
          .textAlign(TextAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: enabled })
          .selectedColor('#3478F6')
          .switchPointColor('#FFFFFF')
          .enabled(active)
          .onChange((isOn: boolean) => {
            if (isOn === enabled) {
              return;
            }
            action(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
  }

  @Builder
  private renderInputSettingsGrid() {
    Row({ space: 4 }) {
      this.renderInputModeSegment('拼', $r('app.string.ime_input_mode_pinyin'), (): void => {
        this.switchSettingsSubtype('zh-Hans-pinyin');
      }, !this.isEnglishSubtype() && this.uiState.keyboardLayout !== 'voice_panel')
      this.renderInputModeSegment('EN', $r('app.string.ime_input_mode_english'), (): void => {
        this.switchSettingsSubtype('en-US-qwerty');
      }, this.isEnglishSubtype())
      this.renderInputModeSegment('voice', $r('app.string.ime_input_mode_voice'), (): void => {
        void this.switchSettingsVoiceMode();
      }, this.uiState.keyboardLayout === 'voice_panel')
    }
    .width('100%')
    .height(52)
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .backgroundColor('#F1F3F6')
    .border({ width: 1, color: '#EAECF1' })
    .borderRadius(18)
  }

  @Builder
  private renderLlmSettingsGrid() {
    List({ space: 12 }) {
      ListItem() {
        this.renderVoiceAutoPolishSection()
      }

    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private renderLlmPromptSettingsGrid() {
    List({ space: 12 }) {
      ListItem() {
        this.renderVoicePolishPromptCard()
      }

      if (this.llmSaveStatus.length > 0) {
        ListItem() {
          Text(this.llmSaveStatus)
            .fontSize(11)
            .fontColor('#3478F6')
            .width('100%')
            .padding({ left: 4 })
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private renderLlmModelSettingsGrid() {
    List({ space: 12 }) {
      ListItem() {
        this.renderLlmCombinedCard()
      }

      if (this.llmSaveStatus.length > 0) {
        ListItem() {
          Text(this.llmSaveStatus)
            .fontSize(11)
            .fontColor('#3478F6')
            .width('100%')
            .padding({ left: 4 })
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private renderVoiceTranslateTargetSettingsGrid() {
    List({ space: 12 }) {
      ListItem() {
        this.renderVoiceTranslateTargetCard()
      }

      if (this.llmSaveStatus.length > 0) {
        ListItem() {
          Text(this.llmSaveStatus)
            .fontSize(11)
            .fontColor('#3478F6')
            .width('100%')
            .padding({ left: 4 })
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private renderVoiceTranslateTargetCard() {
    Column() {
      ForEach(listVoiceTranslationTargets(), (target: VoiceTranslationTarget) => {
        this.renderVoiceTranslateTargetOption(target)
      }, (target: VoiceTranslationTarget): string => target.id)
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E4E6EA' })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderVoiceTranslateTargetOption(target: VoiceTranslationTarget) {
    Column() {
      Row({ space: 12 }) {
        Text(target.label)
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(target.id === this.llmTranslateTargetLanguage ? FontWeight.Bold : FontWeight.Medium)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)
          .maxLines(1)

        if (target.id === this.llmTranslateTargetLanguage) {
          Text('✓')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#3478F6')
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .height(52)
      .padding({ left: 12, right: 12, top: 0, bottom: 0 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.llmTranslateTargetLanguage = target.id;
        this.llmSaveStatus = '';
      })

      if (target.id !== 'de') {
        Divider()
          .strokeWidth(1)
          .color('#F0F2F6')
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  private renderVoiceAutoPolishSection() {
    Column() {
      this.renderVoiceAutoPolishSwitchCard()
      Divider()
        .strokeWidth(1)
        .color('#F0F2F6')
        .width('100%')
      this.renderVoicePolishSettingsEntryRow(
        $r('app.string.ime_model_settings_title'),
        (): void => {
          this.openVoicePolishModelSettings();
        })
      Divider()
        .strokeWidth(1)
        .color('#F0F2F6')
        .width('100%')
      this.renderVoicePolishSettingsEntryRow(
        $r('app.string.ime_polish_prompt_title'),
        (): void => {
          this.openVoicePolishPromptSettings();
        })
      Divider()
        .strokeWidth(1)
        .color('#F0F2F6')
        .width('100%')
      this.renderVoiceTranslateTargetEntryRow()
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E4E6EA' })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderVoiceAutoPolishSwitchCard() {
    Column() {
      Row({ space: 12 }) {
        Text($r('app.string.ime_voice_auto_polish_enable'))
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.runtimeAutoPolishVoiceResult })
          .selectedColor('#3478F6')
          .switchPointColor('#FFFFFF')
          .onChange((isOn: boolean) => {
            if (isOn === this.runtimeAutoPolishVoiceResult) {
              return;
            }
            this.runtimeEnableCloudPolish = isOn;
            this.runtimeAutoPolishVoiceResult = isOn;
            this.llmSaveStatus = '';
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  private renderVoicePolishSettingsEntryRow(title: ResourceStr, action: () => void) {
    Row({ space: 12 }) {
      Text(title)
        .layoutWeight(1)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17181B')
        .textAlign(TextAlign.Start)

      Text('›')
        .fontSize(23)
        .fontColor('#7A7D82')
        .height('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(62)
    .padding({ left: 12, right: 12, top: 0, bottom: 0 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderVoiceTranslateTargetEntryRow() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('翻译目标语言')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)
          .maxLines(1)

        Text(this.resolveCurrentTranslateTargetLabel())
          .fontSize(12)
          .fontColor('#71757F')
          .textAlign(TextAlign.Start)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(23)
        .fontColor('#7A7D82')
        .height('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(62)
    .padding({ left: 12, right: 12, top: 0, bottom: 0 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openVoiceTranslateTargetSettings();
    })
  }

  @Builder
  private renderLlmModelEntryCard() {
    Button() {
      Row({ space: 12 }) {
        Text($r('app.string.ime_model_settings_title'))
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)

        Text('›')
          .fontSize(23)
          .fontColor('#7A7D82')
          .height('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 0, bottom: 0 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(62)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E4E6EA' })
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .onClick(() => {
      this.openVoicePolishModelSettings();
    })
  }

  @Builder
  private renderVoicePolishPromptEntryCard() {
    Button() {
      Row({ space: 12 }) {
        Text($r('app.string.ime_polish_prompt_title'))
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)

        Text('›')
          .fontSize(23)
          .fontColor('#7A7D82')
          .height('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 0, bottom: 0 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(62)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E4E6EA' })
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .onClick(() => {
      this.openVoicePolishPromptSettings();
    })
  }

  @Builder
  private renderVoicePolishPromptCard() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text($r('app.string.ime_polish_prompt_title'))
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181B')
          .textAlign(TextAlign.Start)

        Button($r('app.string.ime_action_reset_default'))
          .width(72)
          .height(32)
          .fontSize(12)
          .fontColor('#3478F6')
          .backgroundColor('#F4F8FF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 })
          .opacity(this.llmPromptTemplateMode === 'custom' ? 1 : 0)
          .enabled(this.llmPromptTemplateMode === 'custom')
          .onClick(() => {
            if (this.llmPromptTemplateMode === 'custom') {
              this.llmPromptTemplate = DEFAULT_VOICE_POLISH_PROMPT;
              this.llmSaveStatus = '';
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 4 }) {
        this.renderVoicePolishPromptModeButton('default', $r('app.string.ime_polish_prompt_default_mode'))
        this.renderVoicePolishPromptModeButton('custom', $r('app.string.ime_polish_prompt_custom_mode'))
      }
      .width('100%')
      .height(38)
      .padding({ left: 3, right: 3, top: 3, bottom: 3 })
      .backgroundColor('#F1F3F6')
      .border({ width: 1, color: '#EAECF1' })
      .borderRadius(19)

      TextArea({
        placeholder: $r('app.string.ime_polish_prompt_placeholder'),
        text: this.resolveVoicePolishPromptEditorText()
      })
        .width('100%')
        .height(188)
        .fontSize(11)
        .fontColor(this.llmPromptTemplateMode === 'custom' ? '#1F2329' : '#6B7280')
        .backgroundColor('#F7F8FA')
        .borderRadius(10)
        .border({ width: 1, color: '#EAECF1' })
        .padding({ left: 10, right: 10, top: 9, bottom: 9 })
        .enabled(this.llmPromptTemplateMode === 'custom')
        .onChange((value: string) => {
          if (this.llmPromptTemplateMode !== 'custom') {
            return;
          }
          this.llmPromptTemplate = value;
          this.llmSaveStatus = '';
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 14, bottom: 14 })
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E4E6EA' })
  }

  @Builder
  private renderVoicePolishPromptModeButton(mode: VoicePolishPromptMode, label: ResourceStr) {
    Button() {
      Text(label)
        .width('100%')
        .fontSize(12)
        .fontWeight(this.llmPromptTemplateMode === mode ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.llmPromptTemplateMode === mode ? '#17181B' : '#60636A')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(32)
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(this.llmPromptTemplateMode === mode ? '#FFFFFF' : 'rgba(0,0,0,0)')
    .borderRadius(16)
    .shadow(this.resolveSettingsTabShadow(this.llmPromptTemplateMode === mode))
    .onClick(() => {
      this.llmPromptTemplateMode = mode;
      this.llmSaveStatus = '';
    })
  }

  private resolveVoicePolishPromptEditorText(): string {
    return this.llmPromptTemplateMode === 'custom' ?
      this.llmPromptTemplate :
      DEFAULT_VOICE_POLISH_PROMPT;
  }

  // All three LLM selectors (provider / model / API key) live in a single
  // card. Each row is a labelled control stacked vertically and separated by
  // a thin divider, so the tab reads as one settings block rather than three
  // stacked chips.
  @Builder
  private renderLlmCombinedCard() {
    Column() {
      this.renderLlmProviderRow()
      Divider()
        .strokeWidth(1)
        .color('#F0F2F6')
        .width('100%')
      this.renderLlmModelRow()
      Divider()
        .strokeWidth(1)
        .color('#F0F2F6')
        .width('100%')
      this.renderLlmApiKeyRow()
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E4E6EA' })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderLlmProviderRow() {
    Column({ space: 10 }) {
      Text($r('app.string.ime_model_provider'))
        .fontSize(13)
        .fontColor('#17181B')
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Row({ space: 8 }) {
        Column() {
          Text(this.resolveProviderInitial(this.resolveCurrentProviderName()))
            .fontSize(14)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor(this.resolveProviderAvatarColor(this.llmDialogProviderId))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        Text(this.resolveCurrentProviderName())
          .fontSize(14)
          .fontColor('#17181B')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('∨')
          .fontSize(14)
          .fontColor('#7A7D82')
      }
      .width('100%')
      .height(44)
      .padding({ left: 10, right: 12 })
      .backgroundColor('#FFFFFF')
      .borderRadius(10)
      .border({ width: 1, color: '#E4E6EA' })
      .bindMenu(this.buildLlmProviderMenu())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderLlmModelRow() {
    Column({ space: 10 }) {
      Text($r('app.string.ime_current_model'))
        .fontSize(13)
        .fontColor('#17181B')
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Row({ space: 8 }) {
        Text(this.resolveCurrentModelLabel())
          .fontSize(14)
          .fontColor('#17181B')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('∨')
          .fontSize(14)
          .fontColor('#7A7D82')
      }
      .width('100%')
      .height(40)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#FFFFFF')
      .borderRadius(10)
      .border({ width: 1, color: '#E4E6EA' })
      .bindMenu(this.buildLlmModelMenu())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  private buildLlmProviderMenu(): MenuElement[] {
    let providers: BuiltinModelProvider[] = listBuiltinModelProviders();
    let items: MenuElement[] = [];
    for (let i = 0; i < providers.length; i++) {
      let provider = providers[i];
      let isActive = provider.providerId === this.llmDialogProviderId;
      items.push({
        value: isActive ? `${provider.providerName}  ✓` : provider.providerName,
        action: (): void => {
          if (this.llmDialogProviderId === provider.providerId) {
            return;
          }
          this.llmDialogProviderId = provider.providerId;
          // Reset to the provider's first model so the `当前模型` row never
          // shows a stale preset from the previous provider.
          this.llmDialogPresetId = provider.models.length > 0 ? provider.models[0].presetId : '';
        }
      });
    }
    return items;
  }

  private buildLlmModelMenu(): MenuElement[] {
    let presets: BuiltinModelPreset[] = this.resolveLlmModelsForSelectedProvider();
    let items: MenuElement[] = [];
    for (let i = 0; i < presets.length; i++) {
      let preset = presets[i];
      let isActive = preset.presetId === this.llmDialogPresetId;
      items.push({
        value: isActive ? `${preset.displayName}  ✓` : preset.displayName,
        action: (): void => {
          this.llmDialogPresetId = preset.presetId;
        }
      });
    }
    if (items.length === 0) {
      items.push({
        value: $r('app.string.ime_no_model_available'),
        action: (): void => {
        }
      });
    }
    return items;
  }

  private resolveCurrentTranslateTargetLabel(): string {
    return resolveVoiceTranslationTarget(this.llmTranslateTargetLanguage).label;
  }

  private resolveCurrentProviderName(): string {
    let providers: BuiltinModelProvider[] = listBuiltinModelProviders();
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].providerId === this.llmDialogProviderId) {
        return providers[i].providerName;
      }
    }
    return '未选择';
  }

  @Builder
  private renderLlmApiKeyRow() {
    Column({ space: 10 }) {
      Text('API Key')
        .fontSize(13)
        .fontColor('#17181B')
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Row({ space: 8 }) {
        Row({ space: 6 }) {
          TextInput({ placeholder: $r('app.string.ime_api_key_placeholder'), text: this.llmDialogApiKey })
            .type(this.llmApiKeyRevealed ? InputType.Normal : InputType.Password)
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('rgba(0,0,0,0)')
            .borderRadius(0)
            .padding({ left: 10, right: 4 })
            .onChange((value: string) => {
              this.llmDialogApiKey = value;
            })
          Button() {
            Text(this.llmApiKeyRevealed ? '⊘' : '⊙')
              .fontSize(16)
              .fontColor('#7A7D82')
          }
          .height(32)
          .width(32)
          .backgroundColor('rgba(0,0,0,0)')
          .borderRadius(16)
          .onClick(() => {
            this.llmApiKeyRevealed = !this.llmApiKeyRevealed;
          })
        }
        .layoutWeight(1)
        .height(40)
        .padding({ right: 4 })
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .border({ width: 1, color: '#E4E6EA' })

        Button($r('app.string.ime_action_paste'))
          .height(40)
          .fontSize(13)
          .fontColor('#17181B')
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E4E6EA' })
          .borderRadius(10)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.pasteLlmApiKeyFromClipboard();
          })
        Button($r('app.string.ime_action_clear'))
          .height(40)
          .fontSize(13)
          .fontColor('#3478F6')
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#C7DBFF' })
          .borderRadius(10)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.llmDialogApiKey = '';
            this.llmSaveStatus = '已清空';
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  private resolveCurrentModelLabel(): string {
    let providers: BuiltinModelProvider[] = listBuiltinModelProviders();
    for (let i: number = 0; i < providers.length; i++) {
      let provider = providers[i];
      if (provider.providerId !== this.llmDialogProviderId) {
        continue;
      }
      for (let j: number = 0; j < provider.models.length; j++) {
        if (provider.models[j].presetId === this.llmDialogPresetId) {
          return `${provider.providerName} ${provider.models[j].displayName}`;
        }
      }
      if (provider.models.length > 0) {
        return `${provider.providerName} ${provider.models[0].displayName}`;
      }
      return provider.providerName;
    }
    return '未选择';
  }

  private resolveSavedVoicePolishModelLabel(): string {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      return this.resolveCurrentModelLabel();
    }
    let snap: LlmSelectionSnapshot = session.getLlmSelectionSnapshot();
    let resolved = resolveBuiltinModelSelection(snap.providerId, snap.presetId);
    return `${resolved.provider.providerName} ${resolved.preset.displayName}`;
  }

  private resolveProviderInitial(providerName: string): string {
    let trimmed = providerName.trim();
    if (trimmed.length === 0) {
      return '?';
    }
    return trimmed.substring(0, 1);
  }

  private resolveProviderAvatarColor(providerId: string): string {
    // Stable pseudo-random color per providerId: simple hash → palette index.
    let palette: string[] = ['#3478F6', '#34C759', '#FF9500', '#AF52DE', '#FF3B30', '#5AC8FA', '#8E8E93'];
    let hash = 0;
    for (let i = 0; i < providerId.length; i++) {
      hash = (hash * 31 + providerId.charCodeAt(i)) | 0;
    }
    let index = Math.abs(hash) % palette.length;
    return palette[index];
  }

  private pasteLlmApiKeyFromClipboard(): void {
    try {
      let systemBoard = pasteboard.getSystemPasteboard();
      systemBoard.getData().then((data): void => {
        try {
          let text = data.getPrimaryText();
          if (text && text.length > 0) {
            this.llmDialogApiKey = text.trim();
            this.llmSaveStatus = '已粘贴';
          } else {
            this.llmSaveStatus = '剪贴板为空';
          }
        } catch (error) {
          this.llmSaveStatus = '粘贴失败：' + ((error as Error).message ?? String(error));
        }
      }).catch((error: Error): void => {
        this.llmSaveStatus = '粘贴失败：' + (error.message ?? String(error));
      });
    } catch (error) {
      this.llmSaveStatus = '粘贴失败：' + ((error as Error).message ?? String(error));
    }
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

  private seedRuntimeSettingsState(): void {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      return;
    }
    let runtime: OffhandRuntimeSettings = session.getRuntimeSettingsSnapshot();
    this.runtimeEnableBuiltinAsr = runtime.enableBuiltinAsr;
    let autoVoicePolishEnabled = runtime.enableCloudPolish && runtime.autoPolishVoiceResult;
    this.runtimeEnableCloudPolish = autoVoicePolishEnabled;
    this.runtimeAutoPolishVoiceResult = autoVoicePolishEnabled;
    this.llmTranslateTargetLanguage = resolveVoiceTranslationTarget(runtime.llmTranslateTargetLanguage).id;
    this.llmPromptTemplateMode = normalizeVoicePolishPromptMode(runtime.llmPromptTemplateMode, runtime.llmPromptTemplate);
    this.llmPromptTemplate = normalizeVoicePolishPromptTemplate(runtime.llmPromptTemplate);
    this.runtimeSaveStatus = '';
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
    this.llmApiKeyRevealed = false;
  }

  private openVoiceAutoPolishSettings(): void {
    this.seedRuntimeSettingsState();
    this.seedLlmDialogState();
    this.llmSaveStatus = '';
    this.activeSettingsTab = 'voicePolish';
  }

  private returnFromVoiceAutoPolishSettings(): void {
    if (this.activeSettingsTab === 'voicePolishModel') {
      void this.saveLlmDialogSettings('')
        .then((): void => {
          this.activeSettingsTab = 'voicePolish';
        });
      return;
    }
    if (this.activeSettingsTab === 'voicePolishPrompt') {
      void this.saveVoiceAutoPolishSettings('')
        .then((): void => {
          this.activeSettingsTab = 'voicePolish';
        });
      return;
    }
    if (this.activeSettingsTab === 'voiceTranslateTarget') {
      void this.saveVoiceAutoPolishSettings('')
        .then((): void => {
          this.activeSettingsTab = 'voicePolish';
        });
      return;
    }
    this.activeSettingsTab = 'common';
    void this.saveVoiceAutoPolishSettings('')
      .then((): void => {
        this.seedRuntimeSettingsState();
      });
  }

  private closeVoiceAutoPolishSettings(): void {
    void this.saveVoiceAutoPolishSettings('')
      .finally((): void => {
        this.closeSettingsOverlay();
      });
  }

  private openVoicePolishModelSettings(): void {
    this.seedLlmDialogState();
    this.llmSaveStatus = '';
    this.activeSettingsTab = 'voicePolishModel';
  }

  private openVoicePolishPromptSettings(): void {
    this.llmPromptTemplateMode = normalizeVoicePolishPromptMode(this.llmPromptTemplateMode, this.llmPromptTemplate);
    this.llmPromptTemplate = normalizeVoicePolishPromptTemplate(this.llmPromptTemplate);
    this.llmSaveStatus = '';
    this.activeSettingsTab = 'voicePolishPrompt';
  }

  private openVoiceTranslateTargetSettings(): void {
    this.llmTranslateTargetLanguage = resolveVoiceTranslationTarget(this.llmTranslateTargetLanguage).id;
    this.llmSaveStatus = '';
    this.activeSettingsTab = 'voiceTranslateTarget';
  }

  private resolvePolishPromptSummary(): ResourceStr {
    if (this.llmPromptTemplateMode === 'default') {
      return $r('app.string.ime_polish_prompt_default_summary');
    }
    return $r('app.string.ime_polish_prompt_custom_summary');
  }

  private async saveVoiceAutoPolishSettings(successText: string): Promise<boolean> {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      this.llmSaveStatus = '保存失败：会话未就绪';
      this.runtimeSaveStatus = this.llmSaveStatus;
      return false;
    }

    try {
      this.runtimeEnableCloudPolish = this.runtimeAutoPolishVoiceResult;
      let runtime: OffhandRuntimeSettings = session.getRuntimeSettingsSnapshot();
      runtime.enableVoice = true;
      runtime.enableBuiltinAsr = this.runtimeEnableBuiltinAsr;
      runtime.enableCloudPolish = this.runtimeAutoPolishVoiceResult;
      runtime.autoPolishVoiceResult = this.runtimeAutoPolishVoiceResult;
      runtime.llmTranslateTargetLanguage = resolveVoiceTranslationTarget(this.llmTranslateTargetLanguage).id;
      runtime.llmPromptTemplateMode = this.llmPromptTemplateMode;
      runtime.llmPromptTemplate = normalizeVoicePolishPromptTemplate(this.llmPromptTemplate);
      await session.updateRuntimeSettings(runtime, 'keyboardVoicePolishSettings');

      if (this.runtimeAutoPolishVoiceResult) {
        await session.updateLlmSelection(this.llmDialogProviderId, this.llmDialogPresetId, this.llmDialogApiKey);
      }

      if (successText.length > 0) {
        this.llmSaveStatus = successText;
      }
      return true;
    } catch (error) {
      this.llmSaveStatus = '保存失败：' + ((error as Error).message ?? String(error));
      this.runtimeSaveStatus = this.llmSaveStatus;
      return false;
    }
  }

  private persistRuntimeSettings(successText: string): void {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      this.runtimeSaveStatus = '保存失败：会话未就绪';
      return;
    }
    let runtime: OffhandRuntimeSettings = session.getRuntimeSettingsSnapshot();
    this.runtimeEnableCloudPolish = this.runtimeAutoPolishVoiceResult;
    runtime.enableVoice = true;
    runtime.enableBuiltinAsr = this.runtimeEnableBuiltinAsr;
    runtime.enableCloudPolish = this.runtimeAutoPolishVoiceResult;
    runtime.autoPolishVoiceResult = this.runtimeAutoPolishVoiceResult;
    runtime.llmTranslateTargetLanguage = resolveVoiceTranslationTarget(this.llmTranslateTargetLanguage).id;
    this.runtimeSaveStatus = '保存中…';
    session.updateRuntimeSettings(runtime, 'keyboardSettings')
      .then((): void => {
        this.seedRuntimeSettingsState();
        this.runtimeSaveStatus = successText;
      })
      .catch((error: Error): void => {
        this.runtimeSaveStatus = '保存失败：' + (error.message ?? String(error));
      });
  }

  private async saveLlmDialogSettings(successText: string): Promise<boolean> {
    let session = imeRuntime.getSessionManager();
    if (!session) {
      this.llmSaveStatus = '保存失败：会话未就绪';
      return false;
    }
    let providerId: string = this.llmDialogProviderId;
    let presetId: string = this.llmDialogPresetId;
    let apiKey: string = this.llmDialogApiKey;
    try {
      this.llmSaveStatus = successText.length > 0 ? '保存中…' : '';
      await session.updateLlmSelection(providerId, presetId, apiKey);
      if (successText.length > 0) {
        this.llmSaveStatus = successText;
      }
      return true;
    } catch (error) {
      this.llmSaveStatus = '保存失败：' + ((error as Error).message ?? String(error));
      return false;
    }
  }

  @Builder
  private renderInputModeSegment(icon: string, title: ResourceStr, action: () => void, selected: boolean = false) {
    Button() {
      Row({ space: 6 }) {
        this.renderInputModeSegmentIcon(icon, selected)

        Text(title)
          .fontSize(14)
          .minFontSize(11)
          .maxFontSize(14)
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(selected ? '#17181B' : '#60646C')
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .height('100%')
      .padding({ left: 4, right: 4, top: 0, bottom: 0 })
    }
    .layoutWeight(1)
    .height(44)
    .backgroundColor(selected ? '#FFFFFF' : 'rgba(0,0,0,0)')
    .border({ width: selected ? 1 : 0, color: selected ? '#FFFFFF' : 'rgba(0,0,0,0)' })
    .borderRadius(14)
    .shadow({
      radius: selected ? 1.2 : 0,
      color: selected ? '#30000000' : '#00000000',
      offsetX: 0,
      offsetY: selected ? 2 : 0
    })
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderInputModeSegmentIcon(icon: string, selected: boolean = false) {
    if (icon === 'voice') {
      this.renderSettingsIconAsset(icon, 18, 18, selected ? 0.92 : 0.62)
    } else {
      Text(icon)
        .fontSize(icon.length > 1 ? 12 : 16)
        .fontWeight(FontWeight.Bold)
        .fontColor(selected ? '#17181B' : '#676B73')
        .height(20)
        .textAlign(TextAlign.Center)
    }
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
  private renderCandidateToolbarSeparator() {
    Column({ space: 3 }) {
      ForEach(CANDIDATE_SEPARATOR_SEGMENTS, (segmentIndex: number) => {
        Column()
          .width(1)
          .height(3)
          .backgroundColor('rgba(95,99,108,0.28)')
      }, (segmentIndex: number): string => `candidate-separator-${segmentIndex}`)
    }
    .width(10)
    .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private renderCandidateToolbarOverlay() {
    Column({ space: 0 }) {
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
        .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
      } else {
        Row({ space: 0 }) {
          if (this.resolveInlinePinyinText().length > 0) {
            Text(this.resolveInlinePinyinText())
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#111214')
              .width(112)
              .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
              .padding({ left: 8, right: 8 })
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            this.renderCandidateToolbarSeparator()
          }

          Scroll() {
            Row({ space: 0 }) {
              if (this.uiState.candidates.length === 0) {
                Text(this.resolveCandidatePlaceholder())
                  .fontSize(15)
                  .fontWeight(FontWeight.Normal)
                  .fontColor('#8C9098')
                  .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
                  .padding({ left: 10, right: 10 })
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
              } else {
                ForEach(this.uiState.candidates, (candidate: CandidateItem) => {
                  if (candidate.index > 0) {
                    this.renderCandidateToolbarSeparator()
                  }

                  Text(candidate.text)
                    .fontSize(15)
                    .fontWeight(FontWeight.Normal)
                    .fontColor(candidate.index === 0 ? '#1677FF' : '#111214')
                    .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
                    .padding({ left: 10, right: 10 })
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .constraintSize({ maxWidth: 92 })
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .onClick(() => {
                      void imeRuntime.getSessionManager()?.selectCandidate(candidate.index);
                    })
                }, (candidate: CandidateItem): string => `${candidate.index}-${candidate.label}-${candidate.text}`)
              }
            }
            .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
            .alignItems(VerticalAlign.Center)
          }
          .scrollable(ScrollDirection.Horizontal)
          .layoutWeight(1)
          .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)

          Text('›')
            .fontSize(28)
            .fontWeight(FontWeight.Normal)
            .fontColor(this.canShowExpandedCandidateBoard(this.uiState) ? '#5F636C' : '#8C9098')
            .width(28)
            .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (this.canShowExpandedCandidateBoard(this.uiState)) {
                this.expandedCandidatePageNo = Math.max(0, this.uiState.candidatePageNo);
                this.expandedCandidateCanPageBackward = this.canPageExpandedCandidateBackward();
                this.showExpandedCandidateBoard = true;
                this.showSymbolPalette = false;
              }
            })
        }
        .width('100%')
        .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)

      }
    }
    .width('100%')
    .height(CANDIDATE_TOOLBAR_OVERLAY_HEIGHT)
    .padding({ left: 24, right: 18, top: 0, bottom: 0 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#D9DCE2')
    .position({ x: 0, y: PANEL_TOP_PADDING })
    .zIndex(8)
  }

  @Builder
  private renderPolishSuggestionStrip() {
    if (this.uiState.showPolishSuggestion || this.uiState.canRevertPolish) {
      Column({ space: 8 }) {
        if (this.uiState.showPolishSuggestion) {
          Text($r('app.string.ime_polish_suggestion_title'))
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
            Button($r('app.string.ime_action_apply'))
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor('#FFFFFF')
            .backgroundColor('#3366FF')
            .borderRadius(12)
            .onClick(() => {
              void imeRuntime.getSessionManager()?.acceptPolishSuggestion();
            })

            Button($r('app.string.ime_action_keep_original'))
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
            Text($r('app.string.ime_polish_applied'))
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#4C4D52')
              .textAlign(TextAlign.Start)

            Button($r('app.string.ime_action_undo'))
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
  private renderExpandedCandidateKeyboard() {
    Row({ space: EXPANDED_CANDIDATE_GAP }) {
      this.renderExpandedPinyinRail()
      this.renderExpandedCandidateGrid()
      this.renderExpandedCandidateActions()
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 8,
      right: 8,
      top: EXPANDED_CANDIDATE_TOP_PADDING,
      bottom: EXPANDED_CANDIDATE_BOTTOM_PADDING
    })
    .backgroundColor('#D9DCE2')
  }

  @Builder
  private renderExpandedPinyinRail() {
    Column({ space: 0 }) {
      ForEach(EXPANDED_PINYIN_ROWS, (row: number) => {
        Text(this.resolveExpandedPinyinText(row))
          .fontSize(EXPANDED_PINYIN_FONT_SIZE)
          .fontWeight(FontWeight.Normal)
          .fontColor('#050608')
          .width('100%')
          .layoutWeight(1)
          .padding({ left: EXPANDED_CANDIDATE_TEXT_PADDING, right: EXPANDED_CANDIDATE_TEXT_PADDING })
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }, (row: number): string => `pinyin-${row}`)
    }
    .layoutWeight(EXPANDED_CANDIDATE_SIDE_WEIGHT)
    .height('100%')
    .backgroundColor(QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
  }

  @Builder
  private renderExpandedCandidateGrid() {
    Column({ space: 0 }) {
      ForEach(EXPANDED_CANDIDATE_ROWS, (row: number) => {
        Row({ space: 0 }) {
          ForEach(EXPANDED_CANDIDATE_COLUMNS, (column: number) => {
            this.renderExpandedCandidateCell(row * EXPANDED_CANDIDATE_COLUMNS.length + column)
          }, (column: number): string => `candidate-cell-${row}-${column}`)
        }
        .width('100%')
        .layoutWeight(1)
      }, (row: number): string => `candidate-row-${row}`)
    }
    .layoutWeight(EXPANDED_CANDIDATE_GRID_WEIGHT)
    .height('100%')
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#ECEEF2' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
  }

  @Builder
  private renderExpandedCandidateCell(displayIndex: number) {
    Text(this.resolveExpandedCandidateText(displayIndex))
      .fontSize(EXPANDED_CANDIDATE_FONT_SIZE)
      .minFontSize(16)
      .maxFontSize(EXPANDED_CANDIDATE_FONT_SIZE)
      .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
      .fontWeight(FontWeight.Normal)
      .fontColor('#050608')
      .layoutWeight(1)
      .height('100%')
      .padding({ left: EXPANDED_CANDIDATE_TEXT_PADDING, right: EXPANDED_CANDIDATE_TEXT_PADDING })
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .border({ width: 0.5, color: '#E5E7EB' })
      .backgroundColor(this.hasExpandedCandidateAt(displayIndex) ? '#FFFFFF' : '#FAFAFB')
      .onClick(() => {
        this.selectExpandedCandidate(displayIndex);
      })
  }

  @Builder
  private renderExpandedCandidateActions() {
    Column({ space: EXPANDED_CANDIDATE_GAP }) {
      this.renderExpandedCandidateActionButton($r('app.string.ime_candidate_return'), (): void => {
        this.showExpandedCandidateBoard = false;
      })

      this.renderExpandedCandidateIconButton('backspace', (): void => {
        this.handleBackspaceClick();
      })

      this.renderExpandedCandidateModeButton()

      Column({ space: 0 }) {
        this.renderExpandedCandidateArrowButton(
          '↑',
          this.canPageExpandedCandidateBackward(),
          (): void => {
            this.pageExpandedCandidateBackward();
          },
          this.canTriggerExpandedCandidateBackward()
        )

        this.renderExpandedCandidateArrowButton(
          '↓',
          this.canPageExpandedCandidateForward(),
          (): void => {
            this.pageExpandedCandidateForward();
          }
        )
      }
      .width('100%')
      .layoutWeight(EXPANDED_CANDIDATE_ACTION_ARROW_WEIGHT)
      .clip(true)
      .backgroundColor(QWERTY_GRAY_KEY_COLOR)
      .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
      .borderRadius(QWERTY_KEY_RADIUS)
      .shadow(this.resolveQwertyGrayKeyShadow())
    }
    .layoutWeight(EXPANDED_CANDIDATE_ACTION_WEIGHT)
    .height('100%')
  }

  @Builder
  private renderExpandedCandidateActionButton(label: ResourceStr, action: () => void) {
    Button() {
      Text(label)
        .fontSize(EXPANDED_ACTION_FONT_SIZE)
        .minFontSize(14)
        .maxFontSize(EXPANDED_ACTION_FONT_SIZE)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor('#050608')
        .width('100%')
        .padding({ left: EXPANDED_CANDIDATE_TEXT_PADDING, right: EXPANDED_CANDIDATE_TEXT_PADDING })
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderExpandedCandidateArrowButton(label: string, enabled: boolean, action: () => void,
    clickable: boolean = enabled) {
    Column() {
      Text(label)
        .fontSize(EXPANDED_ARROW_FONT_SIZE)
        .fontWeight(FontWeight.Lighter)
        .fontColor(clickable ? '#050608' : '#8C9098')
        .width('100%')
        .height(EXPANDED_ARROW_TEXT_HEIGHT)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .clip(true)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .clip(true)
    .onClick(() => {
      if (clickable) {
        action();
      }
    })
  }

  private canPageExpandedCandidateBackward(): boolean {
    return this.expandedCandidatePageNo > 0 ||
      this.expandedCandidateCanPageBackward ||
      this.uiState.hasPreviousCandidatePage ||
      this.uiState.candidatePageNo > 0;
  }

  private canPageExpandedCandidateForward(): boolean {
    return this.uiState.hasNextCandidatePage;
  }

  private canTriggerExpandedCandidateBackward(): boolean {
    return this.uiState.candidates.length > 0 || this.canPageExpandedCandidateBackward();
  }

  private pageExpandedCandidateBackward(): void {
    if (this.expandedCandidatePageNo > 0) {
      this.expandedCandidatePageNo--;
    }
    // Keep the backward arrow visually enabled as long as we have not
    // confirmed reaching page 0. The real Rime state will be synced
    // asynchronously via syncExpandedCandidatePageState; until then we
    // optimistically show the arrow as usable so the user doesn't see
    // a brief grey flicker when paging backward quickly.
    this.expandedCandidateCanPageBackward =
      this.expandedCandidatePageNo > 0 ||
      this.uiState.hasPreviousCandidatePage ||
      this.uiState.candidatePageNo > 0;
    void imeRuntime.getSessionManager()?.pageCandidateBackward();
  }

  private pageExpandedCandidateForward(): void {
    if (this.canPageExpandedCandidateForward()) {
      this.expandedCandidatePageNo = Math.max(1, this.expandedCandidatePageNo + 1, this.uiState.candidatePageNo + 1);
      this.expandedCandidateCanPageBackward = true;
    }
    void imeRuntime.getSessionManager()?.pageCandidateForward();
  }

  @Builder
  private renderExpandedCandidateIconButton(kind: string, action: () => void) {
    Button() {
      this.renderIconAsset(kind, 40, 32)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      action();
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: BACKSPACE_LONG_PRESS_DURATION_MS })
        .onAction(() => {
          if (kind === 'backspace') {
            this.startBackspaceRepeat();
          }
        })
        .onActionEnd(() => {
          if (kind === 'backspace') {
            this.finishBackspaceRepeat();
          }
        })
    )
  }

  @Builder
  private renderExpandedCandidateModeButton() {
    Button() {
      Row({ space: 0 }) {
        Text($r('app.string.ime_candidate_mode_full'))
          .fontSize(EXPANDED_ACTION_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.expandedCandidateSingleMode ? '#8D919A' : '#050608')

        Text($r('app.string.ime_candidate_mode_single'))
          .fontSize(EXPANDED_ACTION_SECONDARY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.expandedCandidateSingleMode ? '#050608' : '#8D919A')
          .margin({ top: 6 })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      this.expandedCandidateSingleMode = !this.expandedCandidateSingleMode;
    })
  }

  @Builder
  private renderReferenceNineKeyKeyboard() {
    Column() {
      Row({ space: 4 }) {
        Column({ space: 4 }) {
          this.renderPunctuationRail()

          // Weight has no effect on horizontal size inside a vertical Column;
          // the button fills the 70px column width via width('100%') in the
          // builder. Keep weight=1 to document "single child takes natural row".
          this.renderBottomActionKey('符号', this.showSymbolKeyboard && this.symbolKeyboardVariant === 'symbol', (): void => {
            this.openSymbolKeyboard('symbol');
          }, true, 1)
        }
        .width(70)
        .height(this.resolveReferenceNineKeyHeight())

        Column({ space: 4 }) {
          Column({ space: 4 }) {
            ForEach(NINE_GRID_ROWS, (row: NineGridKeyDescriptor[]) => {
              Row({ space: 4 }) {
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

          Row({ space: 4 }) {
            // Use strict 1:1:1 layout weights so the three bottom keys line up
            // pixel-perfectly with the three grid columns above: 中/英 under
            // column 1 (分词), 0/mic under column 2 (ABC), and 123 under column 3
            // (DEF). Mixed non-integer weights previously drifted each key away
            // from its grid column by a few pixels.
            this.renderBottomActionKey(this.resolveQuickSwitchLabel(), false, (): void => {
              this.switchQuickSubtype();
            }, true, 1)

            this.renderVoicePadKey()

            this.renderBottomActionKey('123', this.showSymbolKeyboard && this.symbolKeyboardVariant === 'number', (): void => {
              this.openSymbolKeyboard('number');
            }, true, 1)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .height(this.resolveReferenceNineKeyHeight())

        Column({ space: 4 }) {
          this.renderSideActionKey('⌫', (): void => {
            this.handleBackspaceClick();
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
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  private renderReferenceQwertyKeyboard() {
    // The 26-key body keeps the screenshot's own aspect ratio. Do not let it
    // eat all remaining panel height: SpaceBetween would stretch row gaps on
    // taller phones and make the keyboard look unlike the reference.
    Column({ space: this.resolveReferenceQwertyRowGap() }) {
      // Row 1 — 10 letter keys (Q..P), weight 1 each; 9 gaps.
      Row({ space: this.resolveReferenceQwertyKeyGap() }) {
        ForEach(QWERTY_TOP_KEYS, (descriptor: QwertyKeyDescriptor) => {
          this.renderReferenceQwertyLetterKey(descriptor)
        }, (descriptor: QwertyKeyDescriptor): string => descriptor.value)
      }
      .width('100%')

      // Row 2 — 9 letter keys (A..L) with half-key transparent spacers on
      // each side, so letters sit offset from Row 1 the way iOS renders it.
      // Blank() (empty Column) + layoutWeight(0.5) gives a pixel-scaled
      // indent that tracks the panel width instead of a fixed pad.
      Row({ space: this.resolveReferenceQwertyKeyGap() }) {
        Column().layoutWeight(0.5)
        ForEach(QWERTY_MIDDLE_KEYS, (descriptor: QwertyKeyDescriptor) => {
          this.renderReferenceQwertyLetterKey(descriptor)
        }, (descriptor: QwertyKeyDescriptor): string => descriptor.value)
        Column().layoutWeight(0.5)
      }
      .width('100%')

      // Row 3 — ⇧ (weight 1.5) + 7 letters (weight 1) + ⌫ (weight 1.5) = 10.
      Row({ space: this.resolveReferenceQwertyKeyGap() }) {
        this.renderReferenceQwertySideKey('⇧', (): void => {
          this.toggleQwertyLetterCase();
        }, this.isQwertyUppercase(), 1.5)

        ForEach(QWERTY_BOTTOM_KEYS, (descriptor: QwertyKeyDescriptor) => {
          this.renderReferenceQwertyLetterKey(descriptor)
        }, (descriptor: QwertyKeyDescriptor): string => descriptor.value)

        this.renderReferenceQwertySideKey('⌫', (): void => {
          this.handleBackspaceClick();
        }, false, 1.5)
      }
      .width('100%')

      // Row 4 follows the screenshot proportions: side action keys are wide,
      // punctuation keys stay close to a letter key, and the space key spans
      // just under three letter-key units.
      Row({ space: this.resolveReferenceQwertyKeyGap() }) {
        this.renderReferenceQwertyBottomActionKey('符号', (): void => {
          this.openSymbolKeyboard('symbol');
        }, this.showSymbolKeyboard && this.symbolKeyboardVariant === 'symbol', QWERTY_BOTTOM_SIDE_WEIGHT)

        this.renderReferenceQwertyBottomActionKey(this.resolveQuickSwitchLabel(), (): void => {
          this.switchQuickSubtype();
        }, false, QWERTY_BOTTOM_QUICK_WEIGHT)

        this.renderReferenceQwertyPunctuationKey('comma', QWERTY_BOTTOM_PUNCTUATION_WEIGHT)

        this.renderReferenceQwertySpaceKey(QWERTY_BOTTOM_SPACE_WEIGHT)

        this.renderReferenceQwertyPunctuationKey('period', QWERTY_BOTTOM_PUNCTUATION_WEIGHT)

        this.renderReferenceQwertyBottomActionKey('123', (): void => {
          this.openSymbolKeyboard('number');
        }, this.showSymbolKeyboard && this.symbolKeyboardVariant === 'number', QWERTY_BOTTOM_QUICK_WEIGHT)

        this.renderReferenceQwertyBottomActionKey('换行', (): void => {
          void imeRuntime.getSessionManager()?.pressEnter();
        }, false, QWERTY_BOTTOM_SIDE_WEIGHT)
      }
      .width('100%')
    }
    .width('100%')
    .height(this.resolveReferenceQwertyHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  private renderReferenceSymbolKeyboard() {
    if (this.symbolKeyboardVariant === 'number') {
      this.renderReferenceNumberKeyboard()
    } else {
      this.renderReferencePunctuationSymbolKeyboard()
    }
  }

  @Builder
  private renderReferencePunctuationSymbolKeyboard() {
    Column({ space: this.resolveReferenceQwertyRowGap() }) {
      this.renderSymbolKeyRow(SYMBOL_DIGIT_ROW)

      if (this.symbolKeyboardMorePage) {
        this.renderSymbolIndentedKeyRow(SYMBOL_MORE_ROW_2)
        this.renderSymbolKeyRow(SYMBOL_MORE_ROW_3)
      } else {
        this.renderSymbolIndentedKeyRow(SYMBOL_PRIMARY_ROW_2)
        this.renderSymbolKeyRow(SYMBOL_PRIMARY_ROW_3)
      }

      this.renderSymbolKeyboardBottomRow()
    }
    .width('100%')
    .height(this.resolveReferenceQwertyHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  private renderReferenceNumberKeyboard() {
    Row({ space: this.resolveReferenceNumberKeyboardGap() }) {
      Column({ space: this.resolveReferenceNumberKeyboardGap() }) {
        this.renderNumberOperatorRail()
        this.renderNumberKeyboardActionTextKey('符号', (): void => {
          this.symbolKeyboardVariant = 'symbol';
          this.symbolKeyboardMorePage = false;
        })
      }
      .layoutWeight(NUMBER_KEYBOARD_SIDE_WEIGHT)
      .height(this.resolveReferenceNumberKeyboardHeight())

      Column({ space: this.resolveReferenceNumberKeyboardGap() }) {
        ForEach(NUMBER_DIGIT_ROWS, (row: string[]) => {
          Row({ space: this.resolveReferenceNumberKeyboardGap() }) {
            ForEach(row, (digit: string) => {
              this.renderNumberKeyboardTextKey(digit, digit)
            }, (digit: string): string => `number-${digit}`)
          }
          .width('100%')
          .height(this.resolveReferenceNumberKeyboardRowHeight())
        }, (row: string[]): string => `number-row-${row[0]}`)

        Row({ space: this.resolveReferenceNumberKeyboardGap() }) {
          this.renderNumberKeyboardSpaceKey()
          this.renderNumberKeyboardTextKey('0', '0')
          this.renderNumberKeyboardActionTextKey('返回', (): void => {
            this.closeSymbolKeyboard();
          })
        }
        .width('100%')
        .height(this.resolveReferenceNumberKeyboardRowHeight())
      }
      .layoutWeight(NUMBER_KEYBOARD_DIGIT_GROUP_WEIGHT)
      .height(this.resolveReferenceNumberKeyboardHeight())

      Column({ space: this.resolveReferenceNumberKeyboardGap() }) {
        this.renderNumberKeyboardBackspaceKey()
        this.renderNumberKeyboardActionTextKey('@', (): void => {
          this.insertSymbolText('@');
        })
        this.renderNumberKeyboardActionTextKey('.', (): void => {
          this.insertSymbolText('.');
        })
        this.renderNumberKeyboardActionTextKey('换行', (): void => {
          void imeRuntime.getSessionManager()?.pressEnter();
        })
      }
      .layoutWeight(NUMBER_KEYBOARD_SIDE_WEIGHT)
      .height(this.resolveReferenceNumberKeyboardHeight())
    }
    .width('100%')
    .height(this.resolveReferenceNumberKeyboardHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  private renderNumberOperatorRail() {
    Column({ space: 0 }) {
      ForEach(NUMBER_OPERATOR_KEYS, (symbol: string) => {
        Text(symbol)
          .width('100%')
          .layoutWeight(1)
          .fontSize(this.resolveReferenceNumberKeyboardFontSize(NUMBER_KEYBOARD_OPERATOR_FONT_SIZE))
          .minFontSize(12)
          .maxFontSize(this.resolveReferenceNumberKeyboardFontSize(NUMBER_KEYBOARD_OPERATOR_FONT_SIZE))
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(FontWeight.Normal)
          .fontColor('#050608')
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .onClick(() => {
            this.insertSymbolText(symbol);
          })
      }, (symbol: string): string => `operator-${symbol}`)
    }
    .width('100%')
    .height(this.resolveReferenceNumberKeyboardTallHeight())
    .justifyContent(FlexAlign.SpaceAround)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
    .clip(true)
  }

  @Builder
  private renderNumberKeyboardTextKey(label: string, output: string) {
    Button() {
      Text(label)
        .fontSize(this.resolveReferenceNumberKeyboardFontSize(NUMBER_KEYBOARD_DIGIT_FONT_SIZE))
        .minFontSize(13)
        .maxFontSize(this.resolveReferenceNumberKeyboardFontSize(NUMBER_KEYBOARD_DIGIT_FONT_SIZE))
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Normal)
        .fontColor('#050608')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(this.resolveReferenceNumberKeyboardRowHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .clip(true)
    .onClick(() => {
      this.insertSymbolText(output);
    })
  }

  @Builder
  private renderNumberKeyboardActionTextKey(label: string, action: () => void) {
    Button() {
      Text(label)
        .fontSize(this.resolveReferenceNumberKeyboardFontSize(NUMBER_KEYBOARD_ACTION_FONT_SIZE))
        .minFontSize(12)
        .maxFontSize(this.resolveReferenceNumberKeyboardFontSize(NUMBER_KEYBOARD_ACTION_FONT_SIZE))
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor('#050608')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .layoutWeight(1)
    .width('100%')
    .height(this.resolveReferenceNumberKeyboardRowHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .clip(true)
    .onClick(() => {
      action();
    })
  }

  @Builder
  private renderNumberKeyboardBackspaceKey() {
    Button() {
      this.renderIconAsset('backspace', this.resolveReferenceNumberKeyboardScaledSize(38),
        this.resolveReferenceNumberKeyboardScaledSize(29))
    }
    .layoutWeight(1)
    .width('100%')
    .height(this.resolveReferenceNumberKeyboardRowHeight())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .backgroundColor(QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .clip(true)
    .onClick(() => {
      this.handleBackspaceClick();
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: BACKSPACE_LONG_PRESS_DURATION_MS })
        .onAction(() => {
          this.startBackspaceRepeat();
        })
        .onActionEnd(() => {
          this.finishBackspaceRepeat();
        })
    )
  }

  @Builder
  private renderNumberKeyboardSpaceKey() {
    Column() {
      Row() {
        Column()
          .width(this.resolveReferenceNumberKeyboardScaledSize(3))
          .height(this.resolveReferenceNumberKeyboardScaledSize(10))
          .backgroundColor('#111214')

        Column()
          .width(this.resolveReferenceNumberKeyboardScaledSize(43))
          .height(this.resolveReferenceNumberKeyboardScaledSize(3))
          .backgroundColor('#111214')

        Column()
          .width(this.resolveReferenceNumberKeyboardScaledSize(3))
          .height(this.resolveReferenceNumberKeyboardScaledSize(10))
          .backgroundColor('#111214')
      }
      .height(this.resolveReferenceNumberKeyboardScaledSize(12))
      .alignItems(VerticalAlign.Bottom)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(this.resolveReferenceNumberKeyboardRowHeight())
    .backgroundColor(QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .clip(true)
    .onClick(() => {
      this.commitText(' ');
    })
  }

  @Builder
  private renderSymbolKeyboardHeader() {
    Row({ space: 0 }) {
      Row({ space: 0 }) {
        ForEach(SYMBOL_CATEGORY_KEYS, (symbol: string) => {
          Text(symbol)
            .layoutWeight(1)
            .fontSize(this.resolveReferenceQwertyScaledSize(23))
            .fontWeight(FontWeight.Normal)
            .fontColor('#16171B')
            .textAlign(TextAlign.Center)
            .height(34)
            .maxLines(1)
            .onClick(() => {
              this.insertSymbolText(symbol);
            })
        }, (symbol: string): string => symbol)
      }
      .layoutWeight(1)
      .height(36)
      .alignItems(VerticalAlign.Center)

      Column()
        .width(1)
        .height(28)
        .backgroundColor('#C5C8CF')
        .margin({ left: 4, right: 8 })

      Column() {
        Text('×')
          .fontSize(this.resolveReferenceQwertyScaledSize(20))
          .fontWeight(FontWeight.Normal)
          .fontColor('#64676F')
          .width('100%')
          .height('100%')
          .textAlign(TextAlign.Center)
      }
      .width(34)
      .height(34)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('rgba(0,0,0,0)')
      .border({ width: 2, color: '#787B82' })
      .borderRadius(17)
      .onClick(() => {
        this.closeSymbolKeyboard();
      })
    }
    .width('100%')
    .height(FEATURE_ROW_HEIGHT)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderSymbolKeyRow(row: SymbolKeyDescriptor[]) {
    Row({ space: this.resolveReferenceQwertyKeyGap() }) {
      ForEach(row, (descriptor: SymbolKeyDescriptor) => {
        this.renderSymbolKeyboardKey(descriptor)
      }, (descriptor: SymbolKeyDescriptor): string => `${descriptor.role}-${descriptor.label}-${descriptor.output}`)
    }
    .width('100%')
    .height(this.resolveReferenceQwertyRowHeight())
  }

  @Builder
  private renderSymbolIndentedKeyRow(row: SymbolKeyDescriptor[]) {
    Row({ space: this.resolveReferenceQwertyKeyGap() }) {
      Column()
        .layoutWeight(0.5)

      ForEach(row, (descriptor: SymbolKeyDescriptor) => {
        this.renderSymbolKeyboardKey(descriptor)
      }, (descriptor: SymbolKeyDescriptor): string => `${descriptor.role}-${descriptor.label}-${descriptor.output}`)

      Column()
        .layoutWeight(0.5)
    }
    .width('100%')
    .height(this.resolveReferenceQwertyRowHeight())
  }

  @Builder
  private renderSymbolKeyboardBottomRow() {
    Row({ space: this.resolveReferenceQwertyKeyGap() }) {
      this.renderSymbolKeyboardKey({ label: '返回', output: '', role: 'return', weight: 1.55, gray: true })
      this.renderSymbolKeyboardKey({
        label: this.resolveQwertyCommaOutput(),
        output: this.resolveQwertyCommaOutput(),
        role: 'text',
        weight: 1,
        gray: false
      })
      this.renderSymbolKeyboardKey({ label: 'space', output: ' ', role: 'space', weight: 5.35, gray: false })
      this.renderSymbolKeyboardKey({
        label: this.resolveQwertyPeriodOutput(),
        output: this.resolveQwertyPeriodOutput(),
        role: 'text',
        weight: 1,
        gray: false
      })
      this.renderSymbolKeyboardKey({ label: '换行', output: '', role: 'enter', weight: 1.55, gray: true })
    }
    .width('100%')
    .height(this.resolveReferenceQwertyRowHeight())
  }

  @Builder
  private renderSymbolKeyboardKey(descriptor: SymbolKeyDescriptor) {
    Button() {
      if (descriptor.role === 'backspace') {
        this.renderIconAsset('backspace', this.resolveReferenceQwertyScaledSize(34),
          this.resolveReferenceQwertyScaledSize(26))
      } else if (descriptor.role === 'space') {
        Column() {
          Row() {
            Column()
              .width(this.resolveReferenceQwertyScaledSize(3))
              .height(this.resolveReferenceQwertyScaledSize(10))
              .backgroundColor('#111214')

            Column()
              .width(this.resolveReferenceQwertyScaledSize(44))
              .height(this.resolveReferenceQwertyScaledSize(3))
              .backgroundColor('#111214')

            Column()
              .width(this.resolveReferenceQwertyScaledSize(3))
              .height(this.resolveReferenceQwertyScaledSize(10))
              .backgroundColor('#111214')
          }
          .height(this.resolveReferenceQwertyScaledSize(12))
          .alignItems(VerticalAlign.Bottom)
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Text(descriptor.label)
          .fontSize(this.resolveSymbolKeyboardFontSize(descriptor))
          .minFontSize(12)
          .maxFontSize(this.resolveSymbolKeyboardFontSize(descriptor))
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .maxLines(1)
          .fontWeight(FontWeight.Normal)
          .fontColor('#111214')
          .textAlign(TextAlign.Center)
      }
    }
    .layoutWeight(descriptor.weight)
    .height('100%')
    .backgroundColor(descriptor.gray ? QWERTY_GRAY_KEY_COLOR : QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: descriptor.gray ? QWERTY_GRAY_KEY_BORDER_COLOR : '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(descriptor.gray ? this.resolveQwertyGrayKeyShadow() : this.resolveQwertyWhiteKeyShadow())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .clip(true)
    .onClick(() => {
      this.handleSymbolKeyboardKey(descriptor);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: BACKSPACE_LONG_PRESS_DURATION_MS })
        .onAction(() => {
          if (descriptor.role === 'backspace') {
            this.startBackspaceRepeat();
          }
        })
        .onActionEnd(() => {
          if (descriptor.role === 'backspace') {
            this.finishBackspaceRepeat();
          }
        })
    )
  }

  @Builder
  private renderVoicePanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.resolveVoicePanelBackgroundColor())
        .borderRadius(this.resolveVoiceScaledSize(12))
        .shadow({
          radius: this.resolveVoiceScaledSize(8),
          color: '#18000000',
          offsetX: 0,
          offsetY: this.resolveVoiceScaledSize(3)
        })
        .hitTestBehavior(HitTestMode.Transparent)

      if (this.uiState.voiceTranscriptPreview.length > 0) {
        Column() {
          Text(this.uiState.voiceTranscriptPreview)
            .fontSize(this.resolveVoiceScaledSize(13))
            .minFontSize(10)
            .maxFontSize(this.resolveVoiceScaledSize(13))
            .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
            .fontColor('#1D2842')
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: this.resolveVoicePreviewMaxWidth() })
            .maxLines(3)
            .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .padding({
          left: this.resolveVoiceScaledSize(18),
          right: this.resolveVoiceScaledSize(18),
          top: this.resolveVoiceScaledSize(10)
        })
        .position({ x: 0, y: 0 })
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      Column({ space: 3 }) {
        this.renderVoiceHeroButton()

        Text(this.resolveVoicePrimaryTitle())
          .fontSize(this.resolveVoicePrimaryTitleSize())
          .minFontSize(8)
          .maxFontSize(this.resolveVoicePrimaryTitleSize())
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(FontWeight.Normal)
          .fontColor(this.resolveVoiceHeroTitleColor())
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: this.resolveVoiceTextMaxWidth() })
          .maxLines(1)

        Text(this.resolveVoiceSubtitle())
          .fontSize(this.resolveVoiceScaledSize(9))
          .minFontSize(8)
          .maxFontSize(this.resolveVoiceScaledSize(9))
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(FontWeight.Normal)
          .fontColor(this.resolveVoiceSubtitleColor())
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: this.resolveVoiceTextMaxWidth() })
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .padding({
        left: this.resolveVoiceScaledSize(18),
        right: this.resolveVoiceScaledSize(18),
        top: this.uiState.voiceTranscriptPreview.length > 0 ? this.resolveVoiceScaledSize(46) : this.resolveVoiceScaledSize(8),
        bottom: this.resolveVoiceScaledSize(72)
      })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      this.renderVoicePanelActionButtons()
    }
    .width('100%')
    .layoutWeight(1)
    .clip(true)
  }

  @Builder
  private renderVoicePanelRings() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(this.resolveVoiceScaledSize(132))
        .height(this.resolveVoiceScaledSize(132))
        .borderRadius(this.resolveVoiceScaledSize(66))
        .border({ width: 1, color: 'rgba(47,107,255,0.10)' })
        .opacity(this.uiState.voiceState === 'idle' ? 0.48 : 0.72)

      Column()
        .width(this.resolveVoiceScaledSize(94))
        .height(this.resolveVoiceScaledSize(94))
        .borderRadius(this.resolveVoiceScaledSize(47))
        .border({ width: 1, color: 'rgba(47,107,255,0.08)' })
        .opacity(this.uiState.voiceState === 'idle' ? 0.42 : 0.68)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.resolveVoiceScaledSize(96) })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private renderVoiceToolArc() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width(this.resolveVoiceScaledSize(252))
        .height(this.resolveVoiceScaledSize(252))
        .borderRadius(this.resolveVoiceScaledSize(126))
        .border({ width: 2, color: 'rgba(255,255,255,0.62)' })
        .position({
          x: this.resolveVoiceCenteredX(this.resolveVoiceScaledSize(252)),
          y: this.resolveVoiceScaledSize(-52)
        })

      this.renderVoiceToolArcDot(0.18, 127)
      this.renderVoiceToolArcDot(0.82, 127)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private renderVoiceToolArcDot(centerXRatio: number, top: number) {
    Column()
      .width(this.resolveVoiceScaledSize(8))
      .height(this.resolveVoiceScaledSize(8))
      .borderRadius(this.resolveVoiceScaledSize(4))
      .backgroundColor('rgba(255,255,255,0.96)')
      .shadow({
        radius: this.resolveVoiceScaledSize(5),
        color: '#18000000',
        offsetX: 0,
        offsetY: this.resolveVoiceScaledSize(2)
      })
      .position({
        x: this.resolveVoiceToolCenterX(centerXRatio, this.resolveVoiceScaledSize(8)),
        y: this.resolveVoiceScaledSize(top)
      })
      .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private renderVoiceHeroButton() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(this.resolveVoiceScaledSize(76))
        .height(this.resolveVoiceScaledSize(76))
        .borderRadius(this.resolveVoiceScaledSize(38))
        .backgroundColor(this.resolveVoicePulseColor())
        .opacity(this.resolveVoiceOuterPulseOpacity())
        .scale({
          x: this.resolveVoiceOuterPulseScale(),
          y: this.resolveVoiceOuterPulseScale()
        })
        .animation({ duration: VOICE_ANIMATION_INTERVAL_MS, curve: Curve.EaseOut, iterations: 1 })

      Column()
        .width(this.resolveVoiceScaledSize(64))
        .height(this.resolveVoiceScaledSize(64))
        .borderRadius(this.resolveVoiceScaledSize(32))
        .backgroundColor(this.resolveVoicePulseColor())
        .opacity(this.resolveVoiceInnerPulseOpacity())
        .scale({
          x: this.resolveVoiceInnerPulseScale(),
          y: this.resolveVoiceInnerPulseScale()
        })
        .animation({ duration: VOICE_ANIMATION_INTERVAL_MS, curve: Curve.EaseOut, iterations: 1 })

      Button() {
        if (this.uiState.isPolishRunning) {
          Text($r('app.string.ime_polishing'))
            .fontSize(15)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .opacity(this.voicePulseExpanded ? 1 : 0.78)
            .animation({ duration: VOICE_ANIMATION_INTERVAL_MS, curve: Curve.EaseInOut, iterations: 1 })
        } else {
          Image($r('app.media.ime_icon_voice_mic_white'))
            .width(this.resolveVoiceScaledSize(28))
            .height(this.resolveVoiceScaledSize(28))
            .objectFit(ImageFit.Contain)
            .opacity(this.uiState.voiceState === 'starting' ? 0.78 : 1)
            .scale({
              x: this.isVoiceMotionActive() && this.voicePulseExpanded ? 1.07 : 1,
              y: this.isVoiceMotionActive() && this.voicePulseExpanded ? 1.07 : 1
            })
            .animation({ duration: VOICE_ANIMATION_INTERVAL_MS, curve: Curve.EaseInOut, iterations: 1 })
        }
      }
      .width(this.resolveVoiceMicButtonSize())
      .height(this.resolveVoiceMicButtonSize())
      .type(ButtonType.Circle)
      .backgroundColor(this.resolveVoiceButtonColor())
      .shadow({
        radius: this.resolveVoiceScaledSize(10),
        color: '#403366FF',
        offsetX: 0,
        offsetY: this.resolveVoiceScaledSize(5)
      })
      .opacity(this.uiState.voiceEnabled ? 1 : 0.58)
      .onClick(() => {
        this.startOrStopVoice();
      })
    }
    .width(this.resolveVoiceScaledSize(92))
    .height(this.resolveVoiceScaledSize(66))
  }

  @Builder
  private renderVoicePanelActionButtons() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(VOICE_TOOL_ACTIONS, (tool: VoiceToolDescriptor) => {
        this.renderVoicePanelActionButton(tool)
      }, (tool: VoiceToolDescriptor): string => tool.action)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private renderVoicePanelActionButton(tool: VoiceToolDescriptor) {
    Button() {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(this.resolveVoiceToolButtonSize() - this.resolveVoiceScaledSize(8))
          .height(this.resolveVoiceToolButtonSize() - this.resolveVoiceScaledSize(8))
          .borderRadius((this.resolveVoiceToolButtonSize() - this.resolveVoiceScaledSize(8)) / 2)
          .backgroundColor('rgba(255,255,255,0.18)')
          .hitTestBehavior(HitTestMode.Transparent)

        Column({ space: 2 }) {
          Blank()
            .height(this.resolveVoiceScaledSize(2))

          Row() {
            Blank()
              .layoutWeight(1)
            this.renderVoiceToolIcon(tool.action, this.resolveVoiceToolEnabled(tool.action))
            Blank()
              .layoutWeight(1)
          }
          .width('100%')
          .height(this.resolveVoiceScaledSize(21))
          .alignItems(VerticalAlign.Center)

          Text(tool.label)
            .fontSize(this.resolveVoiceScaledSize(9))
            .minFontSize(8)
            .maxFontSize(this.resolveVoiceScaledSize(9))
            .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.resolveVoiceToolEnabled(tool.action) ? '#24304A' : '#8D96AA')
            .textAlign(TextAlign.Center)
            .width('100%')
            .maxLines(1)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width(this.resolveVoiceToolButtonSize())
    .height(this.resolveVoiceToolButtonSize())
    .type(ButtonType.Circle)
    .backgroundColor('rgba(255,255,255,0.54)')
    .shadow({
      radius: this.resolveVoiceScaledSize(10),
      color: '#22000000',
      offsetX: 0,
      offsetY: this.resolveVoiceScaledSize(5)
    })
    .opacity(this.resolveVoiceToolEnabled(tool.action) ? 1 : 0.42)
    .enabled(this.resolveVoiceToolEnabled(tool.action))
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .position({
      x: this.resolveVoiceToolCenterX(tool.centerXRatio, this.resolveVoiceToolButtonSize()),
      y: this.resolveVoiceScaledSize(tool.top)
    })
    .onClick(() => {
      this.handleVoiceToolAction(tool.action);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: BACKSPACE_LONG_PRESS_DURATION_MS })
        .onAction(() => {
          if (tool.action === 'back' && !this.uiState.canRevertPolish) {
            this.startBackspaceRepeat();
          }
        })
        .onActionEnd(() => {
          if (tool.action === 'back' && !this.uiState.canRevertPolish) {
            this.finishBackspaceRepeat();
          }
        })
    )
  }

  @Builder
  private renderVoiceToolIcon(action: VoiceToolAction, enabled: boolean) {
    if (action === 'polish') {
      this.renderIconAsset('style', this.resolveVoiceScaledSize(18), this.resolveVoiceScaledSize(18), enabled ? 1 : 0.46)
    } else if (action === 'translate') {
      Text('文A')
        .fontSize(this.resolveVoiceScaledSize(15))
        .minFontSize(12)
        .maxFontSize(this.resolveVoiceScaledSize(15))
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Bold)
        .fontColor(enabled ? '#256BFF' : '#8FA7DB')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    } else if (action === 'clear') {
      Text('⌧')
        .fontSize(this.resolveVoiceScaledSize(17))
        .minFontSize(13)
        .maxFontSize(this.resolveVoiceScaledSize(17))
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor(enabled ? '#256BFF' : '#8FA7DB')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    } else {
      Text('↶')
        .fontSize(this.resolveVoiceScaledSize(20))
        .minFontSize(15)
        .maxFontSize(this.resolveVoiceScaledSize(20))
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor(enabled ? '#256BFF' : '#8FA7DB')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
  }

  private isVoiceMotionActive(): boolean {
    return this.uiState.voiceState === 'recording' ||
      this.uiState.voiceState === 'starting';
  }

  private resolveVoiceScaledSize(referenceSize: number): number {
    return this.resolveReferenceQwertyScaledSize(referenceSize);
  }

  private resolveVoicePrimaryTitleSize(): number {
    return Math.max(10, this.resolveVoiceScaledSize(11));
  }

  private resolveVoiceMicButtonSize(): number {
    return Math.max(46, this.resolveVoiceScaledSize(52));
  }

  private resolveVoiceToolButtonSize(): number {
    return Math.max(34, this.resolveVoiceScaledSize(40));
  }

  private resolveVoiceToolSlotWidth(): number {
    return Math.max(42, this.resolveVoiceScaledSize(48));
  }

  private resolveVoiceToolSidePadding(): number {
    return Math.max(34, Math.round(this.resolveReferenceQwertyContentWidth() * 0.15));
  }

  private resolveVoiceCenteredX(width: number): number {
    return Math.round((this.resolveReferenceQwertyContentWidth() - width) / 2);
  }

  private resolveVoiceToolCenterX(centerXRatio: number, width: number): number {
    return Math.round(this.resolveReferenceQwertyContentWidth() * centerXRatio - width / 2);
  }

  private resolveVoiceTextMaxWidth(): number {
    let contentWidth = this.resolveReferenceQwertyContentWidth();
    return Math.max(200, Math.min(contentWidth - 28, Math.round(contentWidth * 0.84)));
  }

  private resolveVoicePreviewMaxWidth(): number {
    let contentWidth = this.resolveReferenceQwertyContentWidth();
    return Math.max(220, Math.min(contentWidth - 34, Math.round(contentWidth * 0.88)));
  }

  private resolveVoiceButtonColor(): string {
    if (this.uiState.voiceState === 'error') {
      return '#4B6DFF';
    }
    if (this.uiState.isPolishRunning) {
      return '#536DFF';
    }
    if (this.uiState.voiceState === 'recording') {
      return '#1E74FF';
    }
    if (this.uiState.voiceState === 'starting') {
      return '#4B78FF';
    }
    return '#2F6BFF';
  }

  private resolveVoicePrimaryTitle(): ResourceStr {
    if (this.isVoiceStatusPermissionDenied() || this.uiState.voiceState === 'error') {
      return '语音输入异常';
    }
    if (this.containsVoiceStatusText('voice.translating')) {
      return '正在翻译';
    }
    if (this.uiState.isPolishRunning ||
      this.containsVoiceStatusText('voice.polishing') ||
      this.containsVoiceStatusText('Polishing')) {
      return $r('app.string.ime_voice_status_polishing');
    }
    if (this.uiState.voiceState === 'processing' || this.containsVoiceStatusText('voice.processing')) {
      return $r('app.string.ime_voice_status_processing');
    }
    if (this.uiState.voiceState === 'recording') {
      return '正在聆听';
    }
    if (this.uiState.voiceState === 'starting') {
      return '语音启动中';
    }
    if (this.uiState.voiceState === 'stopped' && this.uiState.voiceTranscriptPreview.length > 0) {
      return '语音输入完成';
    }
    return '语音输入开始';
  }

  private resolveVoiceSubtitle(): ResourceStr {
    if (!this.uiState.voiceEnabled || this.isVoiceStatusUnavailable()) {
      return '当前输入框不可用';
    }
    if (this.isVoiceStatusPermissionDenied()) {
      return '请允许麦克风权限后重试';
    }
    if (this.isVoiceStatusNoSpeech()) {
      return '未识别到声音，可重新录入';
    }
    if (this.containsVoiceStatusText('voice.translating')) {
      return '请稍候，正在翻译文字';
    }
    if (this.uiState.isPolishRunning ||
      this.uiState.voiceState === 'processing' ||
      this.containsVoiceStatusText('voice.processing')) {
      return '请稍候，正在整理文字';
    }
    if (this.uiState.voiceState === 'recording') {
      return '再次点击按钮停止录音';
    }
    if (this.uiState.voiceState === 'starting') {
      return '正在准备麦克风';
    }
    if (this.uiState.voiceTranscriptPreview.length > 0) {
      return '可继续录音，或使用下方工具';
    }
    return '点击按钮开始说话';
  }

  private resolveVoiceSubtitleColor(): string {
    if (this.isVoiceStatusPermissionDenied() || this.uiState.voiceState === 'error') {
      return '#C94848';
    }
    return '#717A91';
  }

  private isVoiceToolBusy(): boolean {
    return this.uiState.voiceState === 'starting' ||
      this.uiState.voiceState === 'recording' ||
      this.uiState.voiceState === 'processing' ||
      this.uiState.isPolishRunning;
  }

  private resolveVoiceToolEnabled(action: VoiceToolAction): boolean {
    if (action === 'polish' || action === 'translate') {
      return this.uiState.polishEnabled && this.uiState.voiceDraftText.trim().length > 0 && !this.isVoiceToolBusy();
    }
    if (action === 'clear') {
      return this.uiState.sessionActive || this.uiState.voiceTranscriptPreview.length > 0 || this.uiState.voiceDraftText.length > 0;
    }
    return !this.isVoiceToolBusy() && (this.uiState.canRevertPolish || this.uiState.sessionActive);
  }

  private handleVoiceToolAction(action: VoiceToolAction): void {
    if (!this.resolveVoiceToolEnabled(action)) {
      return;
    }
    if (action === 'polish') {
      void imeRuntime.getSessionManager()?.polishPendingText();
      return;
    }
    if (action === 'translate') {
      void imeRuntime.getSessionManager()?.translatePendingText();
      return;
    }
    if (action === 'clear') {
      void imeRuntime.getSessionManager()?.clearEditorText();
      return;
    }
    if (this.uiState.canRevertPolish) {
      void imeRuntime.getSessionManager()?.revertLastPolish();
      return;
    }
    this.handleBackspaceClick();
  }

  private resolveVoiceOuterPulseOpacity(): number {
    if (!this.isVoiceMotionActive()) {
      return 0;
    }
    if (this.uiState.voiceState === 'starting') {
      return this.voicePulseExpanded ? 0.08 : 0.28;
    }
    return this.voicePulseExpanded ? 0.05 : 0.22;
  }

  private resolveVoiceInnerPulseOpacity(): number {
    if (!this.isVoiceMotionActive()) {
      return 0;
    }
    if (this.uiState.voiceState === 'starting') {
      return this.voicePulseExpanded ? 0.18 : 0.36;
    }
    return this.voicePulseExpanded ? 0.14 : 0.3;
  }

  private resolveVoiceOuterPulseScale(): number {
    if (!this.isVoiceMotionActive()) {
      return 0.96;
    }
    if (this.uiState.voiceState === 'starting') {
      return this.voicePulseExpanded ? 1.2 : 0.92;
    }
    return this.voicePulseExpanded ? 1.18 : 0.96;
  }

  private resolveVoiceInnerPulseScale(): number {
    if (!this.isVoiceMotionActive()) {
      return 0.96;
    }
    if (this.uiState.voiceState === 'starting') {
      return this.voicePulseExpanded ? 1.11 : 0.94;
    }
    return this.voicePulseExpanded ? 1.08 : 0.96;
  }

  private resolveVoiceHeroTitle(): ResourceStr {
    if (this.uiState.isPolishRunning ||
      this.containsVoiceStatusText('voice.polishing') ||
      this.containsVoiceStatusText('Polishing')) {
      return $r('app.string.ime_voice_status_polishing');
    }
    if (this.uiState.voiceState === 'processing' || this.containsVoiceStatusText('voice.processing')) {
      return $r('app.string.ime_voice_status_processing');
    }
    if (this.uiState.voiceState === 'recording') {
      return '正在聆听';
    }
    return '';
  }

  private shouldRenderVoiceHeroTitle(): boolean {
    return this.uiState.voiceState === 'recording' ||
      this.uiState.voiceState === 'processing' ||
      this.containsVoiceStatusText('voice.processing') ||
      this.uiState.isPolishRunning ||
      this.containsVoiceStatusText('voice.polishing') ||
      this.containsVoiceStatusText('Polishing');
  }

  private resolveVoiceHeroTitleColor(): string {
    if (this.isVoiceStatusPermissionDenied() || this.uiState.voiceState === 'error') {
      return '#D14343';
    }
    return '#18233C';
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
      this.renderIconAsset(kind, this.resolveFeatureIconWidth(kind), this.resolveFeatureIconHeight(kind), enabled ? 1 : 0.32)
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
  private renderInputModeFeatureButton() {
    if (this.isVoiceModeActive()) {
      this.renderFeatureIconAssetButton(
        'keyboard',
        (): void => {
          this.toggleVoiceKeyboardMode();
        },
        false,
        this.canToggleVoiceKeyboardMode()
      )
    } else {
      this.renderFeatureIconAssetButton(
        'mic',
        (): void => {
          this.toggleVoiceKeyboardMode();
        },
        false,
        this.canToggleVoiceKeyboardMode()
      )
    }
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
    } else if (kind === 'keyboard') {
      Image($r('app.media.ime_icon_feature_keyboard'))
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
  private renderVoiceStatusLabel() {
    if (this.uiState.isPolishRunning ||
      this.containsVoiceStatusText('voice.polishing') ||
      this.containsVoiceStatusText('Polishing')) {
      this.renderVoiceStatusText($r('app.string.ime_voice_status_polishing'), false)
    } else if (this.uiState.voiceState === 'processing' || this.containsVoiceStatusText('voice.processing')) {
      this.renderVoiceStatusText($r('app.string.ime_voice_status_processing'), false)
    } else if (this.uiState.voiceState === 'recording') {
      this.renderVoiceStatusText('正在聆听', false)
    }
  }

  @Builder
  private renderVoiceStatusText(label: ResourceStr, isError: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor(isError ? '#EF4444' : '#606168')
      .textAlign(TextAlign.Center)
  }

  private shouldRenderVoiceStatusLabel(): boolean {
    return this.shouldRenderVoiceHeroTitle();
  }

  private isVoiceStatusPermissionDenied(): boolean {
    return this.containsVoiceStatusText('permission denied') ||
      this.containsVoiceStatusText('Permission denied') ||
      this.containsVoiceStatusText('voice.permission_denied') ||
      this.containsVoiceStatusText('麦克风权限');
  }

  private isVoiceStatusUnavailable(): boolean {
    return this.containsVoiceStatusText('unavailable') ||
      this.containsVoiceStatusText('Unavailable') ||
      this.containsVoiceStatusText('voice.unavailable') ||
      this.containsVoiceStatusText('不可用');
  }

  private isVoiceStatusNoSpeech(): boolean {
    return this.containsVoiceStatusText('voice.no_speech') ||
      this.containsVoiceStatusText('未检测到语音') ||
      this.containsVoiceStatusText('No speech');
  }

  private containsVoiceStatusText(fragment: string): boolean {
    return this.uiState.voiceStatusText.indexOf(fragment) >= 0;
  }

  @Builder
  private renderPunctuationRail() {
    Column({ space: 9 }) {
      ForEach(this.resolveSidePunctuations(), (symbol: string) => {
        Text(symbol)
          .fontSize(15)
          .fontColor('#171717')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
          .borderRadius(10)
          .stateStyles({ pressed: this.pressedWhiteKeyStyle })
          .onClick(() => {
            this.insertSymbolText(symbol);
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
    .gesture(
      LongPressGesture({ repeat: false, duration: BACKSPACE_LONG_PRESS_DURATION_MS })
        .onAction(() => {
          if (label === '⌫') {
            this.startBackspaceRepeat();
          }
        })
        .onActionEnd(() => {
          if (label === '⌫') {
            this.finishBackspaceRepeat();
          }
        })
    )
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
    Column({ space: 0 }) {
      Text(descriptor.hint)
        .fontSize(9)
        .fontColor('#8F9299')

      Text(this.resolveQwertyLetterLabel(descriptor.value))
        .fontSize(20)
        .minFontSize(12)
        .maxFontSize(20)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .maxLines(1)
        .fontWeight(FontWeight.Normal)
        .fontColor('#050608')
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(this.resolveReferenceQwertyRowHeight())
    .backgroundColor(QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      this.handleReferenceQwertyLetterInput(descriptor.value);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 450 })
        .onAction(() => {
          this.handleReferenceQwertySecondaryInput(descriptor.hint);
        })
        .onActionEnd(() => {
          this.armQwertyLongPressClickSuppression();
        })
    )
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
    .backgroundColor(active ? QWERTY_ACTIVE_KEY_COLOR : QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: active ? QWERTY_ACTIVE_KEY_BORDER_COLOR : QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
    .stateStyles({ pressed: this.pressedGrayKeyStyle })
    .onClick(() => {
      action();
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: BACKSPACE_LONG_PRESS_DURATION_MS })
        .onAction(() => {
          if (label === '⌫') {
            this.startBackspaceRepeat();
          }
        })
        .onActionEnd(() => {
          if (label === '⌫') {
            this.finishBackspaceRepeat();
          }
        })
    )
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
    .backgroundColor(active ? QWERTY_ACTIVE_KEY_COLOR : QWERTY_GRAY_KEY_COLOR)
    .border({ width: 1, color: active ? QWERTY_ACTIVE_KEY_BORDER_COLOR : QWERTY_GRAY_KEY_BORDER_COLOR })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyGrayKeyShadow())
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
    if (this.isQuickSwitchLabel(label)) {
      Row({ space: 0 }) {
        Text(this.resolveQuickSwitchPrimaryLabel())
          .fontSize(fontSize + 2)
          .fontWeight(FontWeight.Medium)
          .fontColor(enabled ? '#1E2024' : '#B5B7BE')
          .maxLines(1)

        Text(`/${this.resolveQuickSwitchSecondaryLabel()}`)
          .fontSize(fontSize - 4)
          .fontWeight(FontWeight.Regular)
          .fontColor(enabled ? '#8D919A' : '#C3C5CB')
          .maxLines(1)
          .margin({ top: 4 })
      }
      .alignItems(VerticalAlign.Center)
    } else {
      Text(label)
        .fontSize(fontSize)
        .minFontSize(11)
        .maxFontSize(fontSize)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor(enabled ? '#08090C' : '#B5B7BE')
        .maxLines(1)
    }
  }

  @Builder
  private renderNineQuickSwitchLabel(enabled: boolean) {
    Row({ space: 0 }) {
      Text(this.resolveQuickSwitchPrimaryLabel())
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(enabled ? '#1F2024' : '#B5B7BE')
        .maxLines(1)

      Text(`/${this.resolveQuickSwitchSecondaryLabel()}`)
        .fontSize(8)
        .fontWeight(FontWeight.Regular)
        .fontColor(enabled ? '#8E9199' : '#C3C5CB')
        .maxLines(1)
        .margin({ top: 4 })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderReferenceQwertyPunctuationKey(
    kind: string,
    weight: number = 0.76
  ) {
    Column({ space: 0 }) {
      Text(this.resolveQwertyPunctuationSecondaryLabel(kind))
        .fontSize(9)
        .fontColor('#8F9299')
        .textAlign(TextAlign.Center)

      Text(this.resolveQwertyPunctuationLabel(kind))
        .fontSize(20)
        .minFontSize(12)
        .maxFontSize(20)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .maxLines(1)
        .fontWeight(FontWeight.Medium)
        .fontColor('#050608')
        .textAlign(TextAlign.Center)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(weight)
    .height(this.resolveReferenceQwertyBottomHeight())
    .backgroundColor(QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      void imeRuntime.getSessionManager()?.insertPunctuation(this.resolveQwertyPunctuationOutput(kind));
    })
  }

  @Builder
  private renderReferenceQwertySpaceKey(weight: number = 2.5) {
    Column() {
      Row() {
        Column()
          .width(3)
          .height(10)
          .backgroundColor('#111214')

        Column()
          .width(44)
          .height(3)
          .backgroundColor('#111214')

        Column()
          .width(3)
          .height(10)
          .backgroundColor('#111214')
      }
      .height(12)
      .alignItems(VerticalAlign.Bottom)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(weight)
    .height(this.resolveReferenceQwertyBottomHeight())
    .backgroundColor(QWERTY_WHITE_KEY_COLOR)
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(QWERTY_KEY_RADIUS)
    .shadow(this.resolveQwertyWhiteKeyShadow())
    .stateStyles({ pressed: this.pressedWhiteKeyStyle })
    .onClick(() => {
      this.commitText(' ');
    })
  }

  private resolveReferenceNineKeyHeight(): number {
    return 226;
  }

  private resolveReferenceNineKeyGridHeight(): number {
    return 170;
  }

  private resolveReferenceNineKeyRowHeight(): number {
    return 54;
  }

  private resolveReferenceNineKeyBottomHeight(): number {
    return 52;
  }

  private resolveReferenceNineKeyTallActionHeight(): number {
    return 110;
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

  private resolveQwertyWhiteKeyShadow(): ShadowOptions {
    return {
      radius: 1.4,
      color: '#36000000',
      offsetX: 0,
      offsetY: 2
    };
  }

  private resolveQwertyGrayKeyShadow(): ShadowOptions {
    return {
      radius: 1.4,
      color: '#2C000000',
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
    if (kind === 'tool' || kind === 'magic' || kind === 'gear') {
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
    if (kind === 'gear') {
      return 36;
    }
    if (kind === 'chevron') {
      return 26;
    }
    return 28;
  }

  private resolveFeatureIconHeight(kind: string): number {
    if (kind === 'gear') {
      return 36;
    }
    return 28;
  }

  private resolveBottomActionFontSize(label: string): number {
    if (this.isQuickSwitchLabel(label)) {
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
    return this.resolveReferenceQwertyScaledSize(QWERTY_REFERENCE_HEIGHT);
  }

  private resolveReferenceQwertyRowHeight(): number {
    return this.resolveReferenceQwertyScaledSize(QWERTY_REFERENCE_ROW_HEIGHT);
  }

  private resolveReferenceQwertyBottomHeight(): number {
    return this.resolveReferenceQwertyScaledSize(QWERTY_REFERENCE_ROW_HEIGHT);
  }

  private resolveReferenceQwertyRowGap(): number {
    return this.resolveReferenceQwertyScaledSize(QWERTY_REFERENCE_ROW_GAP);
  }

  private resolveReferenceQwertyKeyGap(): number {
    return this.resolveReferenceQwertyScaledSize(QWERTY_KEY_GAP);
  }

  private resolveReferenceQwertyScaledSize(referenceSize: number): number {
    return Math.max(1, Math.round(this.resolveReferenceQwertyContentWidth() *
      referenceSize / QWERTY_REFERENCE_CONTENT_WIDTH));
  }

  private resolveReferenceQwertyContentWidth(): number {
    try {
      let currentDisplay = display.getDefaultDisplaySync();
      return Math.max(QWERTY_MIN_CONTENT_WIDTH, px2vp(currentDisplay.width) - QWERTY_REFERENCE_HORIZONTAL_PADDING);
    } catch (_) {
      return QWERTY_REFERENCE_CONTENT_WIDTH;
    }
  }

  private resolveReferenceNumberKeyboardRowHeight(): number {
    return this.resolveReferenceNumberKeyboardScaledSize(NUMBER_KEYBOARD_REFERENCE_ROW_HEIGHT);
  }

  private resolveReferenceNumberKeyboardGap(): number {
    return this.resolveReferenceNumberKeyboardScaledSize(NUMBER_KEYBOARD_REFERENCE_GAP);
  }

  private resolveReferenceNumberKeyboardTallHeight(): number {
    return this.resolveReferenceNumberKeyboardRowHeight() * 3 + this.resolveReferenceNumberKeyboardGap() * 2;
  }

  private resolveReferenceNumberKeyboardHeight(): number {
    return this.resolveReferenceNumberKeyboardRowHeight() * 4 + this.resolveReferenceNumberKeyboardGap() * 3;
  }

  private resolveReferenceNumberKeyboardFontSize(referenceSize: number): number {
    return Math.max(10, this.resolveReferenceNumberKeyboardScaledSize(referenceSize));
  }

  private resolveReferenceNumberKeyboardScaledSize(referenceSize: number): number {
    return Math.max(1, Math.round(this.resolveReferenceQwertyContentWidth() *
      referenceSize / NUMBER_KEYBOARD_REFERENCE_CONTENT_WIDTH));
  }

  private resolveReferenceQwertyBottomFontSize(label: string): number {
    if (this.isQuickSwitchLabel(label)) {
      return 13;
    }
    if (label === '换行' || label === '符号') {
      return 17;
    }
    if (label === '123') {
      return 18;
    }
    return label.length > 2 ? 14 : 17;
  }

  private resolveSymbolKeyboardFontSize(descriptor: SymbolKeyDescriptor): number {
    if (descriptor.role === 'return' || descriptor.role === 'enter' || descriptor.role === 'more') {
      return this.resolveReferenceQwertyScaledSize(18);
    }
    if (descriptor.label === '...') {
      return this.resolveReferenceQwertyScaledSize(20);
    }
    return this.resolveReferenceQwertyScaledSize(21);
  }

  private resolveQwertyLetterLabel(value: string): string {
    return this.isQwertyUppercase() ? value.toUpperCase() : value.toLowerCase();
  }

  private handleReferenceQwertyLetterInput(value: string): void {
    if (this.suppressNextQwertyLetterClick) {
      this.suppressNextQwertyLetterClick = false;
      this.clearQwertyLongPressSuppressTimer();
      return;
    }
    let committed = this.isQwertyUppercase() ? value.toUpperCase() : value.toLowerCase();
    this.commitText(committed);
  }

  private handleReferenceQwertySecondaryInput(value: string): void {
    if (value.length === 0) {
      return;
    }
    void imeRuntime.getSessionManager()?.insertPunctuation(value);
  }

  private armQwertyLongPressClickSuppression(): void {
    this.suppressNextQwertyLetterClick = true;
    this.clearQwertyLongPressSuppressTimer();
    this.qwertyLongPressSuppressTimer = setTimeout((): void => {
      this.suppressNextQwertyLetterClick = false;
      this.qwertyLongPressSuppressTimer = undefined;
    }, 250);
  }

  private resolveQwertyCommaLabel(): string {
    return this.isEnglishPunctuationMode() ? ',' : '，';
  }

  private resolveQwertyPeriodLabel(): string {
    return this.isEnglishPunctuationMode() ? '.' : '。';
  }

  private resolveQwertyCommaOutput(): string {
    return this.isEnglishPunctuationMode() ? ',' : '，';
  }

  private resolveQwertyPeriodOutput(): string {
    return this.isEnglishPunctuationMode() ? '.' : '。';
  }

  private resolveQwertyPunctuationLabel(kind: string): string {
    return kind === 'comma' ? this.resolveQwertyCommaLabel() : this.resolveQwertyPeriodLabel();
  }

  private resolveQwertyPunctuationOutput(kind: string): string {
    return kind === 'comma' ? this.resolveQwertyCommaOutput() : this.resolveQwertyPeriodOutput();
  }

  private resolveQwertyPunctuationSecondaryLabel(kind: string): string {
    return kind === 'comma' ? this.resolveQwertyCommaSecondaryLabel() : this.resolveQwertyPeriodSecondaryLabel();
  }

  private resolveQwertyCommaSecondaryLabel(): string {
    return this.isEnglishPunctuationMode() ? '!' : '！';
  }

  private resolveQwertyPeriodSecondaryLabel(): string {
    return this.isEnglishPunctuationMode() ? '?' : '？';
  }

  private resolveSidePunctuations(): string[] {
    return this.isEnglishPunctuationMode() ? [',', '.', '?', '!'] : SIDE_PUNCTUATIONS;
  }

  private resolveReferenceQwertySpaceLabel(): string {
    if (!this.isEnglishPunctuationMode()) {
      return '空格';
    }
    return this.isQwertyUppercase() ? 'SPACE' : 'space';
  }

  private isQwertyUppercase(): boolean {
    return this.uiState.letterCaseMode === 'upper';
  }

  private toggleQwertyLetterCase(): void {
    void imeRuntime.getSessionManager()?.switchLetterCase(this.isQwertyUppercase() ? 'lower' : 'upper');
  }

  private openSymbolKeyboard(variant: SymbolKeyboardVariant = 'symbol'): void {
    this.showSymbolKeyboard = true;
    this.symbolKeyboardVariant = variant;
    this.showSymbolPalette = false;
    this.symbolKeyboardMorePage = false;
    this.showExpandedCandidateBoard = false;
  }

  private closeSymbolKeyboard(): void {
    this.showSymbolKeyboard = false;
    this.symbolKeyboardVariant = 'symbol';
    this.symbolKeyboardMorePage = false;
  }

  private insertSymbolText(text: string): void {
    if (text.length === 0) {
      return;
    }
    void imeRuntime.getSessionManager()?.insertPunctuation(text);
  }

  private handleSymbolKeyboardKey(descriptor: SymbolKeyDescriptor): void {
    switch (descriptor.role) {
      case 'text':
      case 'space':
        this.insertSymbolText(descriptor.output);
        break;
      case 'backspace':
        this.handleBackspaceClick();
        break;
      case 'more':
        this.symbolKeyboardMorePage = !this.symbolKeyboardMorePage;
        break;
      case 'return':
        this.closeSymbolKeyboard();
        break;
      case 'enter':
        void imeRuntime.getSessionManager()?.pressEnter();
        break;
    }
  }

  private handlePrimaryToolbarAction(): void {
    if (this.uiState.showPolishSuggestion) {
      void imeRuntime.getSessionManager()?.acceptPolishSuggestion();
      return;
    }
    if (this.uiState.candidates.length > 0) {
      void imeRuntime.getSessionManager()?.selectCandidate(0);
    }
  }

  private canUsePrimaryAction(): boolean {
    return this.uiState.showPolishSuggestion ||
      this.uiState.candidates.length > 0;
  }

  private handleSendAction(): void {
    void imeRuntime.getSessionManager()?.pressEnter();
  }

  private canUseSendAction(): boolean {
    return this.uiState.sessionActive;
  }

  private resolveVoicePulseColor(): string {
    if (this.uiState.voiceState === 'error') {
      return '#EF4444';
    }
    if (this.uiState.isPolishRunning) {
      return '#8B9DFF';
    }
    if (this.uiState.voiceState === 'recording') {
      return '#FF5252';
    }
    if (this.uiState.voiceState === 'starting') {
      return '#5C7CFF';
    }
    return '#3366FF';
  }

  private startOrStopVoice(): void {
    if (this.uiState.voiceState === 'starting') {
      // 正在启动录音，忽略重复点击
      return;
    }
    if (this.uiState.voiceState === 'recording') {
      void imeRuntime.getSessionManager()?.stopVoiceInput();
      return;
    }
    if (this.uiState.voiceState === 'processing') {
      // 处理中状态下点击，取消当前语音处理
      void imeRuntime.getSessionManager()?.clearActiveInput();
      return;
    }
    if (this.uiState.isPolishRunning || this.containsVoiceStatusText('voice.processing')) {
      return;
    }
    if (this.uiState.voiceState === 'idle' || this.uiState.voiceState === 'stopped' || this.uiState.voiceState === 'error') {
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
    this.activeSettingsTab = 'input';
    this.seedRuntimeSettingsState();
    this.showSymbolPalette = false;
    this.showSymbolKeyboard = false;
    this.symbolKeyboardMorePage = false;
    this.showExpandedCandidateBoard = false;
  }

  private canToggleVoiceKeyboardMode(): boolean {
    if (this.isVoiceModeActive()) {
      return true;
    }
    return this.isRuntimeVoiceEnabled();
  }

  private isVoiceModeActive(): boolean {
    return this.uiState.keyboardLayout === 'voice_panel' || this.uiState.currentSubtypeId === 'zh-CN-voice';
  }

  private isRuntimeVoiceEnabled(): boolean {
    return true;
  }

  private toggleVoiceKeyboardMode(): void {
    void this.toggleVoiceKeyboardModeAsync();
  }

  private async toggleVoiceKeyboardModeAsync(): Promise<void> {
    let sessionManager = imeRuntime.getSessionManager();
    if (!sessionManager) {
      return;
    }

    this.showSymbolPalette = false;
    this.showSymbolKeyboard = false;
    this.symbolKeyboardMorePage = false;

    if (this.uiState.keyboardLayout === 'voice_panel') {
      if (this.uiState.voiceState === 'recording' || this.uiState.voiceState === 'processing' || this.uiState.voiceState === 'starting') {
        await sessionManager.stopVoiceInput(true);
      }

      if (this.hasLayoutOption('qwerty_26') || this.hasLayoutOption('t9_9')) {
        await sessionManager.switchKeyboardLayout(this.resolveKeyboardModeLayout());
        return;
      }

      let keyboardSubtypeId = this.resolveKeyboardModeSubtypeId();
      if (keyboardSubtypeId.length === 0) {
        return;
      }
      await sessionManager.switchSubtype(keyboardSubtypeId);
      await sessionManager.switchKeyboardLayout(this.resolveKeyboardModeLayout());
      return;
    }

    if (this.hasLayoutOption('voice_panel')) {
      await sessionManager.switchKeyboardLayout('voice_panel');
      return;
    }

    let voiceSubtypeId = this.resolveVoiceSubtypeId();
    if (voiceSubtypeId.length === 0) {
      return;
    }
    await sessionManager.switchSubtype(voiceSubtypeId);
    await sessionManager.switchKeyboardLayout('voice_panel');
  }

  private closeSettingsOverlay(): void {
    this.showSettingsTray = false;
    this.activeSettingsTab = 'input';
    this.runtimeSaveStatus = '';
    this.llmSaveStatus = '';
    this.showSymbolKeyboard = false;
    this.symbolKeyboardMorePage = false;
    this.showExpandedCandidateBoard = false;
  }

  private supportsNineKey(): boolean {
    return this.hasLayoutOption('t9_9');
  }

  private supportsTwentySixKey(): boolean {
    return this.hasLayoutOption('qwerty_26');
  }

  private resolveKeyboardModeLayout(): KeyboardLayoutId {
    if (this.lastNonVoiceKeyboardLayout === 't9_9') {
      return 't9_9';
    }
    return 'qwerty_26';
  }

  private resolveKeyboardModeSubtypeId(): string {
    if (this.lastNonVoiceSubtypeId.length > 0 &&
      this.lastNonVoiceSubtypeId !== 'zh-CN-voice' &&
      this.findSubtypeById(this.lastNonVoiceSubtypeId).length > 0) {
      return this.lastNonVoiceSubtypeId;
    }

    let pinyinSubtype = this.findSubtypeById('zh-Hans-pinyin');
    if (pinyinSubtype.length > 0) {
      return pinyinSubtype;
    }
    return this.findFirstSubtypeByLocale('zh');
  }

  private resolveVoiceSubtypeId(): string {
    let voiceSubtypeId = this.findSubtypeById('zh-CN-voice');
    if (voiceSubtypeId.length > 0) {
      return voiceSubtypeId;
    }
    return this.isRuntimeVoiceEnabled() ? 'zh-CN-voice' : '';
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
    return `${this.resolveQuickSwitchPrimaryLabel()}/${this.resolveQuickSwitchSecondaryLabel()}`;
  }

  private resolveQuickSwitchPrimaryLabel(): string {
    return this.isEnglishSubtype() ? '英' : '中';
  }

  private resolveQuickSwitchSecondaryLabel(): string {
    return this.isEnglishSubtype() ? '中' : '英';
  }

  private isQuickSwitchLabel(label: string): boolean {
    return label === '中/英' || label === '英/中';
  }

  private isEnglishSubtype(): boolean {
    if (this.pendingQuickSubtypeId.length > 0) {
      return this.pendingQuickSubtypeId.startsWith('en-');
    }
    return this.uiState.currentSubtypeId.startsWith('en-');
  }

  private isEnglishPunctuationMode(): boolean {
    if (this.pendingQuickSubtypeId.length > 0) {
      return this.pendingQuickSubtypeId.startsWith('en-');
    }
    return this.uiState.punctuationMode === 'en' || this.isEnglishSubtype();
  }

  private switchQuickSubtype(): void {
    let targetSubtype = this.resolveQuickSwitchSubtypeId();
    if (targetSubtype.length === 0) {
      return;
    }
    this.setPendingQuickSubtype(targetSubtype);
    void this.switchSubtypeWithKeyboardLayoutAsync(
      targetSubtype,
      this.resolvePreferredKeyboardLayoutForSubtype(targetSubtype)
    );
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
    this.clearPendingQuickSubtype();
    void this.switchSubtypeWithKeyboardLayoutAsync(
      targetSubtype,
      this.resolvePreferredKeyboardLayoutForSubtype(targetSubtype)
    );
    this.closeSettingsOverlay();
  }

  private async switchSettingsVoiceMode(): Promise<void> {
    let targetSubtype = this.resolveVoiceSubtypeId();
    if (targetSubtype.length === 0) {
      targetSubtype = 'zh-CN-voice';
    }
    this.clearPendingQuickSubtype();
    await this.switchSubtypeWithKeyboardLayoutAsync(targetSubtype, 'voice_panel');
    this.closeSettingsOverlay();
  }

  private setPendingQuickSubtype(subtypeId: string): void {
    this.clearPendingQuickSubtype();
    this.pendingQuickSubtypeId = subtypeId;
    this.pendingQuickSubtypeClearTimer = setTimeout((): void => {
      this.pendingQuickSubtypeId = '';
      this.pendingQuickSubtypeClearTimer = undefined;
    }, 1200);
  }

  private clearPendingQuickSubtype(): void {
    this.pendingQuickSubtypeId = '';
    if (this.pendingQuickSubtypeClearTimer !== undefined) {
      clearTimeout(this.pendingQuickSubtypeClearTimer);
      this.pendingQuickSubtypeClearTimer = undefined;
    }
  }

  private async switchSubtypeWithKeyboardLayoutAsync(
    targetSubtype: string,
    targetLayout: KeyboardLayoutId
  ): Promise<void> {
    let sessionManager = imeRuntime.getSessionManager();
    if (!sessionManager) {
      return;
    }
    await sessionManager.switchSubtype(targetSubtype);
    await sessionManager.switchKeyboardLayout(targetLayout);
  }

  private resolveQuickSwitchSubtypeId(): string {
    if (this.uiState.currentSubtypeId.startsWith('en-')) {
      let rememberedChineseSubtype = this.findSubtypeById(this.lastChineseSubtypeId);
      if (rememberedChineseSubtype.length > 0 && rememberedChineseSubtype !== 'zh-CN-voice') {
        return rememberedChineseSubtype;
      }
      let zhSubtype = this.findSubtypeById('zh-Hans-pinyin');
      return zhSubtype.length > 0 ? zhSubtype : this.findFirstSubtypeByLocale('zh');
    }
    let rememberedEnglishSubtype = this.findSubtypeById(this.lastEnglishSubtypeId);
    if (rememberedEnglishSubtype.length > 0) {
      return rememberedEnglishSubtype;
    }
    let englishSubtype = this.findSubtypeById('en-US-qwerty');
    if (englishSubtype.length > 0) {
      return englishSubtype;
    }
    return this.findFirstSubtypeByLocale('en');
  }

  private resolvePreferredKeyboardLayoutForSubtype(targetSubtypeId: string): KeyboardLayoutId {
    if (targetSubtypeId.startsWith('en-')) {
      if (this.lastEnglishKeyboardLayout === 't9_9') {
        return 't9_9';
      }
      return 'qwerty_26';
    }
    if (targetSubtypeId.startsWith('zh-')) {
      if (this.lastChineseKeyboardLayout === 't9_9') {
        return 't9_9';
      }
      return 'qwerty_26';
    }
    return 'qwerty_26';
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

  private resolveInlinePinyinText(): string {
    if (this.isEnglishSubtype() || this.uiState.keyboardLayout === 'voice_panel') {
      return '';
    }
    if (this.uiState.pinyinInput.length > 0) {
      return formatDirectPinyinRawInput(this.uiState.pinyinInput);
    }
    if (this.uiState.activeNineKeySpelling.length > 0) {
      return formatDirectPinyinRawInput(this.uiState.activeNineKeySpelling);
    }
    return '';
  }

  private canShowExpandedCandidateBoard(state: KeyboardUiState): boolean {
    return !state.currentSubtypeId.startsWith('en-') &&
      state.keyboardLayout !== 'voice_panel' &&
      (state.pinyinInput.length > 0 || state.activeNineKeySpelling.length > 0 || state.candidates.length > 0);
  }

  private syncExpandedCandidatePageState(state: KeyboardUiState, previousInputSignature: string): void {
    if (!this.canShowExpandedCandidateBoard(state)) {
      this.expandedCandidatePageNo = 0;
      this.expandedCandidateCanPageBackward = false;
      return;
    }

    let nextInputSignature = this.resolveExpandedCandidateInputSignature(state);
    if (previousInputSignature !== nextInputSignature || !this.showExpandedCandidateBoard) {
      this.expandedCandidatePageNo = Math.max(0, state.candidatePageNo);
      this.expandedCandidateCanPageBackward = state.hasPreviousCandidatePage || state.candidatePageNo > 0;
      return;
    }

    if (state.candidatePageNo > this.expandedCandidatePageNo) {
      this.expandedCandidatePageNo = state.candidatePageNo;
    }
    if (state.hasPreviousCandidatePage || state.candidatePageNo > 0 || this.expandedCandidatePageNo > 0) {
      this.expandedCandidateCanPageBackward = true;
      return;
    }
    this.expandedCandidateCanPageBackward = false;
  }

  private resolveExpandedCandidateInputSignature(state: KeyboardUiState): string {
    return `${state.currentSubtypeId}|${state.keyboardLayout}|${state.pinyinInput}|${state.activeNineKeySpelling}|` +
      `${state.nineKeySequence}`;
  }

  private resolveExpandedPinyinText(row: number): string {
    if (this.uiState.nineKeySpellings.length > 0) {
      if (row < this.uiState.nineKeySpellings.length) {
        return formatDirectPinyinRawInput(this.uiState.nineKeySpellings[row]);
      }
      return '';
    }
    let text = this.resolveInlinePinyinText();
    if (text.length === 0) {
      return '';
    }
    let segments = text.split('\'');
    if (row < segments.length) {
      return segments[row];
    }
    return '';
  }

  private resolveExpandedCandidateText(displayIndex: number): string {
    let candidate = this.resolveExpandedCandidateAt(displayIndex);
    return candidate ? candidate.text : '';
  }

  private hasExpandedCandidateAt(displayIndex: number): boolean {
    return this.resolveExpandedCandidateAt(displayIndex) !== undefined;
  }

  private resolveExpandedCandidateAt(displayIndex: number): CandidateItem | undefined {
    let visibleIndex = 0;
    for (let index = 0; index < this.uiState.candidates.length; index++) {
      let candidate = this.uiState.candidates[index];
      if (this.expandedCandidateSingleMode && !this.isSingleCandidateText(candidate.text)) {
        continue;
      }
      if (visibleIndex === displayIndex) {
        return candidate;
      }
      visibleIndex++;
    }
    return undefined;
  }

  private isSingleCandidateText(text: string): boolean {
    return text.length <= 1;
  }

  private selectExpandedCandidate(displayIndex: number): void {
    let candidate = this.resolveExpandedCandidateAt(displayIndex);
    if (!candidate) {
      return;
    }
    this.showExpandedCandidateBoard = false;
    void imeRuntime.getSessionManager()?.selectCandidate(candidate.index);
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

  private shouldShowCandidateStrip(): boolean {
    return this.showSymbolPalette ||
      this.uiState.pinyinInput.length > 0 ||
      this.uiState.preedit.length > 0 ||
      this.uiState.candidates.length > 0 ||
      this.uiState.activeNineKeySpelling.length > 0 ||
      this.uiState.nineKeySpellings.length > 0;
  }
}
