import { InputMethodExtensionContext, InputMethodSubtype, inputMethodEngine } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  InputSessionContext,
  KeyboardLayoutId,
  KeyboardLayoutOption,
  OffhandSubtypeConfig,
  PolishSuggestion,
  RimeState,
  SessionCapabilitySnapshot
} from '../common/ImeTypes';
import { ConfigRepository } from '../config/ConfigRepository';
import { EnglishEngine, EnglishEngineState } from '../engine/english/EnglishEngine';
import { NineKeyStateSnapshot, PinyinNineKeyEngine } from '../engine/pinyin/PinyinNineKeyEngine';
import { RimeService } from '../engine/rime/RimeService';
import { HistoryBigram } from '../engine/langmodel/HistoryBigram';
import { LanguageModelStore } from '../engine/langmodel/LanguageModelStore';
import { PredictionService } from '../engine/langmodel/PredictionService';
import { LlmPolishService } from '../llm/LlmPolishService';
import { ImeTelemetry } from '../observability/ImeTelemetry';
import { PermissionManager } from '../security/PermissionManager';
import { VoiceCaptureService } from '../voice/VoiceCaptureService';
import { keyboardStateStore } from './KeyboardStateStore';
import { EditorContextAdapter } from './EditorContextAdapter';
import { appendDirectPinyinRawInput, backspaceDirectPinyinRawInput } from './DirectPinyinInput';
import { SecurityPolicy } from './SecurityPolicy';
import fileIo from '@ohos.file.fs';

const DOMAIN = 0xFF10;
const TAG = 'SessionManager';
const MAX_POLISH_BUFFER_LENGTH = 160;
const ASSOCIATION_CONTEXT_LIMIT = 8;
const ASSOCIATION_MAX_CANDIDATES = 6;
const HISTORY_MAX_SENTENCES = 512;

interface CommitRollbackSnapshot {
  rawInput: string;
  committedText: string;
  schemaId: string;
}

interface VoiceAutoStopHandle {
  timerId: number;
}

export class SessionManager {
  private readonly configRepository: ConfigRepository;
  private readonly rimeService: RimeService;
  private readonly englishEngine: EnglishEngine = new EnglishEngine();
  private readonly nineKeyEngine: PinyinNineKeyEngine = new PinyinNineKeyEngine();
  private readonly historyBigram: HistoryBigram = new HistoryBigram(HISTORY_MAX_SENTENCES);
  private readonly prediction: PredictionService = new PredictionService(this.historyBigram);
  private languageModelStore?: LanguageModelStore;
  private associationContext: string[] = [];
  private readonly permissionManager: PermissionManager = new PermissionManager();
  private readonly voiceCaptureService: VoiceCaptureService = new VoiceCaptureService();
  private readonly llmPolishService: LlmPolishService = new LlmPolishService();
  private context?: InputMethodExtensionContext;
  private keyboardController?: inputMethodEngine.KeyboardController;
  private inputClient?: inputMethodEngine.InputClient;
  private editorAdapter?: EditorContextAdapter;
  private keyboardPanel?: inputMethodEngine.Panel;
  private currentSubtype?: OffhandSubtypeConfig;
  private currentKeyboardLayout: KeyboardLayoutId = 'qwerty_26';
  private securityMode: number = inputMethodEngine.SecurityMode.BASIC;
  private activeSessionContext?: InputSessionContext;
  private activeCapabilities?: SessionCapabilitySnapshot;
  private rimeSessionId: string = '';
  private pendingRollback?: CommitRollbackSnapshot;
  private pendingPolishText: string = '';
  private pendingVoiceDraftText: string = '';
  private pendingPolishSuggestion?: PolishSuggestion;
  private lastAppliedPolish?: PolishSuggestion;
  private voiceAutoStopHandle?: VoiceAutoStopHandle;

  constructor(
    configRepository: ConfigRepository,
    rimeService: RimeService
  ) {
    this.configRepository = configRepository;
    this.rimeService = rimeService;
  }

  async initialize(context: InputMethodExtensionContext): Promise<void> {
    this.context = context;
    await this.configRepository.initialize(context);
    this.initializeLanguageModelStore(context);
    this.currentSubtype = this.configRepository.getDefaultSubtype();
    this.currentKeyboardLayout = this.currentSubtype.keyboardLayout;
    keyboardStateStore.setSubtypes(
      this.configRepository.listSubtypeSummaries(),
      this.currentSubtype.id,
      this.currentSubtype.name
    );
    keyboardStateStore.patch({
      isReady: true,
      statusText: 'IME bootstrap ready',
      keyboardLayout: this.getResolvedKeyboardLayout(),
      availableKeyboardLayouts: this.resolveKeyboardLayoutOptions()
    });
    this.syncNineKeyState(this.nineKeyEngine.reset());
    this.resetSmartFeatureState();
  }

  bindPanel(panel: inputMethodEngine.Panel): void {
    this.keyboardPanel = panel;
  }

  async handleInputStart(keyboardController: inputMethodEngine.KeyboardController,
    inputClient: inputMethodEngine.InputClient): Promise<void> {
    this.keyboardController = keyboardController;
    this.inputClient = inputClient;
    this.editorAdapter = new EditorContextAdapter(inputClient);
    if (this.context) {
      await this.configRepository.refreshRuntimeSettings(this.context);
    }
    if (!this.currentSubtype) {
      this.currentSubtype = this.configRepository.getDefaultSubtype();
    }
    await this.refreshSessionContext('inputStart');
  }

  async handleInputStop(): Promise<void> {
    this.clearVoiceAutoStopTimer();
    if (this.voiceCaptureService.isRecording()) {
      await this.stopVoiceInput(true);
    }
    if (this.rimeSessionId.length > 0) {
      // Mirror fcitx5-chinese-addons `SwitchInputMethodBehavior::CommitPreedit`:
      // commit any pending preedit so Rime's user_dict records the selection,
      // then persist learning to disk via sync_user_data.
      await this.finalizePendingRimeComposition();
      this.rimeService.destroySession(this.rimeSessionId);
      this.rimeSessionId = '';
    }
    this.persistRimeUserDataSafely('inputStop');
    this.persistLanguageModelSafely('inputStop');
    if (this.editorAdapter) {
      await this.editorAdapter.clearPreviewText();
    }
    this.keyboardController = undefined;
    this.inputClient = undefined;
    this.editorAdapter = undefined;
    this.activeSessionContext = undefined;
    this.activeCapabilities = undefined;
    this.englishEngine.reset();
    this.syncNineKeyState(this.nineKeyEngine.reset());
    this.clearRollbackState();
    this.resetSmartFeatureState();
    keyboardStateStore.resetTransientState();
  }

  async handleKeyboardShow(): Promise<void> {
    if (this.keyboardPanel) {
      await this.keyboardPanel.show();
    }
    keyboardStateStore.patch({
      statusText: this.activeSessionContext ? 'Keyboard panel shown' : 'Keyboard shown without active session'
    });
  }

  async handleKeyboardHide(): Promise<void> {
    if (this.keyboardPanel) {
      await this.keyboardPanel.hide();
    }
    keyboardStateStore.patch({
      statusText: 'Keyboard panel hidden'
    });
  }

  async handleSubtypeChange(subtype: InputMethodSubtype): Promise<void> {
    await this.switchSubtype(subtype.id);
  }

  async handleSecurityModeChange(mode: number): Promise<void> {
    this.securityMode = mode;
    if (this.editorAdapter) {
      await this.refreshSessionContext('securityModeChange');
    }
  }

  async switchSubtype(subtypeId: string): Promise<void> {
    // Commit and persist any in-flight Rime composition before swapping subtype,
    // matching fcitx5-chinese-addons' CommitPreedit + saveDict behavior on IM switch.
    if (this.rimeSessionId.length > 0) {
      await this.finalizePendingRimeComposition();
    }
    this.persistRimeUserDataSafely('switchSubtype');
    this.persistLanguageModelSafely('switchSubtype');
    this.currentSubtype = this.configRepository.resolveSubtypeById(subtypeId);
    this.currentKeyboardLayout = this.currentSubtype.keyboardLayout;
    this.englishEngine.reset();
    this.syncNineKeyState(this.nineKeyEngine.reset());
    keyboardStateStore.setSubtypes(
      this.configRepository.listSubtypeSummaries(),
      this.currentSubtype.id,
      this.currentSubtype.name
    );
    keyboardStateStore.patch({
      keyboardLayout: this.getResolvedKeyboardLayout(),
      availableKeyboardLayouts: this.resolveKeyboardLayoutOptions(),
      statusText: `Switched to ${this.currentSubtype.name}`
    });
    this.clearRollbackState();
    this.invalidatePolishActions();
    void ImeTelemetry.trackBehavior('subtype_switch', `subtypeId=${this.currentSubtype.id}`);
    this.resetSmartFeatureState();
    if (this.editorAdapter) {
      await this.editorAdapter.clearPreviewText();
      await this.refreshSessionContext('subtypeSwitch');
    }
  }

  async switchKeyboardLayout(layout: KeyboardLayoutId): Promise<void> {
    if (!this.currentSubtype) {
      return;
    }
    let availableLayouts = this.resolveAvailableKeyboardLayouts();
    if (availableLayouts.indexOf(layout) < 0) {
      return;
    }
    this.currentKeyboardLayout = layout;
    let resolvedLayout = this.getResolvedKeyboardLayout();
    if (this.activeSessionContext) {
      this.activeSessionContext.keyboardLayout = resolvedLayout;
    }
    keyboardStateStore.patch({
      keyboardLayout: resolvedLayout,
      availableKeyboardLayouts: this.resolveKeyboardLayoutOptions(),
      statusText: `Switched to ${this.describeKeyboardLayout(resolvedLayout)}`
    });
    if (!this.isNineKeyLayoutActive()) {
      this.syncNineKeyState(this.nineKeyEngine.reset());
      return;
    }
    if (this.rimeSessionId.length === 0) {
      await this.ensureRimeSessionReady();
    }
    if (this.rimeSessionId.length === 0) {
      return;
    }
    let state = this.rimeService.getState(this.rimeSessionId);
    this.syncNineKeyState(this.nineKeyEngine.syncWithRawInput(state.rawInput));
    this.updateCandidateState(state);
    await this.syncPreviewText(state.composingText);
  }

  async typeNineKeyDigit(digit: string): Promise<void> {
    hilog.info(DOMAIN, TAG,
      'typeNineKeyDigit enter digit=%{public}s subtype=%{public}s editorAdapter=%{public}s nineKeyActive=%{public}s rimeSessionId=%{public}s',
      digit,
      this.currentSubtype ? this.currentSubtype.id : 'undefined',
      this.editorAdapter ? 'present' : 'absent',
      this.isNineKeyLayoutActive() ? 'true' : 'false',
      this.rimeSessionId.length > 0 ? this.rimeSessionId : 'empty');
    if (!this.currentSubtype) {
      hilog.warn(DOMAIN, TAG, 'typeNineKeyDigit early-return: currentSubtype is undefined');
      return;
    }
    if (!this.editorAdapter) {
      hilog.warn(DOMAIN, TAG, 'typeNineKeyDigit early-return: editorAdapter is undefined (inputStart not fired)');
      return;
    }
    if (!this.isNineKeyLayoutActive()) {
      hilog.warn(DOMAIN, TAG,
        'typeNineKeyDigit early-return: not nine-key layout; resolvedLayout=%{public}s engine=%{public}s',
        this.getResolvedKeyboardLayout(), this.currentSubtype.engine);
      return;
    }
    this.clearRollbackState();
    this.invalidatePolishActions();
    await this.ensureRimeSessionReady();
    if (this.rimeSessionId.length === 0) {
      hilog.error(DOMAIN, TAG, 'typeNineKeyDigit early-return: rimeSessionId empty after ensureRimeSessionReady');
      return;
    }
    await this.applyNineKeyState(this.nineKeyEngine.appendDigit(digit));
    hilog.info(DOMAIN, TAG, 'typeNineKeyDigit done digit=%{public}s rimeSessionId=%{public}s', digit, this.rimeSessionId);
  }

  async selectNineKeySpelling(spelling: string): Promise<void> {
    if (!this.currentSubtype || !this.isNineKeyLayoutActive() || this.rimeSessionId.length === 0) {
      return;
    }
    this.clearRollbackState();
    this.invalidatePolishActions();
    await this.applyNineKeyState(this.nineKeyEngine.selectSpelling(spelling));
  }

  async typeText(text: string): Promise<void> {
    if (!this.editorAdapter || !this.currentSubtype) {
      return;
    }
    if (this.isNineKeyLayoutActive() && /^[2-9]$/.test(text)) {
      await this.typeNineKeyDigit(text);
      return;
    }
    if (this.shouldUseDirectPinyinInput(text)) {
      await this.typePinyinLetter(text);
      return;
    }
    this.clearRollbackState();
    this.invalidatePolishActions();
    if (this.shouldUseEnglishEngine()) {
      let state = text === ' ' ?
        this.englishEngine.processSpace(this.shouldAutoCapitalizeEnglish()) :
        this.englishEngine.typeText(text, this.shouldAutoCapitalizeEnglish());
      await this.applyEnglishState(state);
      return;
    }
    if (this.currentSubtype.engine === 'librime') {
      await this.ensureRimeSessionReady();
      if (this.rimeSessionId.length === 0) {
        return;
      }
      let previousState = this.rimeService.getState(this.rimeSessionId);
      if (text === ' ' && previousState.composingText.length === 0 && previousState.rawInput.length === 0) {
        await this.commitDirectText(' ', 'Inserted space');
        this.updateCandidateState(this.rimeService.getState(this.rimeSessionId));
        return;
      }
      let state = text === ' ' ?
        this.rimeService.processSpace(this.rimeSessionId) :
        this.rimeService.processText(this.rimeSessionId, text);
      await this.applyRimeState(state, previousState);
      return;
    }
    await this.commitDirectText(text, `Inserted "${text}"`);
  }

  async pressBackspace(): Promise<void> {
    hilog.info(DOMAIN, TAG,
      'pressBackspace enter editorAdapter=%{public}s subtype=%{public}s',
      this.editorAdapter ? 'present' : 'absent',
      this.currentSubtype ? this.currentSubtype.id : 'undefined');
    if (!this.editorAdapter || !this.currentSubtype) {
      hilog.warn(DOMAIN, TAG, 'pressBackspace early-return: editorAdapter/currentSubtype missing');
      return;
    }
    this.invalidatePolishActions();
    if (this.isNineKeyLayoutActive() && this.nineKeyEngine.hasComposition()) {
      this.clearRollbackState();
      await this.applyNineKeyState(this.nineKeyEngine.backspace());
      return;
    }
    if (this.shouldUseDirectPinyinBackspace()) {
      await this.deletePinyinLetter();
      return;
    }
    if (this.shouldUseEnglishEngine() && this.englishEngine.hasComposition()) {
      await this.applyEnglishState(this.englishEngine.processBackspace(this.shouldAutoCapitalizeEnglish()));
      return;
    }
    if (!this.shouldUseEnglishEngine() && this.currentSubtype.engine === 'librime' && this.rimeSessionId.length > 0) {
      let currentState = this.rimeService.getState(this.rimeSessionId);
      if (currentState.composingText.length > 0 || currentState.rawInput.length > 0) {
        this.clearRollbackState();
        await this.applyRimeState(this.rimeService.processBackspace(this.rimeSessionId));
        return;
      }
      if (this.pendingRollback && this.pendingRollback.committedText.length > 0) {
        await this.restoreCommittedComposition(this.pendingRollback);
        return;
      }
    }
    let deleted = await this.editorAdapter.deleteBackward(1);
    if (!deleted) {
      return;
    }
    this.truncatePendingPolishText(1);
    keyboardStateStore.patch({
      statusText: 'Deleted backward',
      preedit: '',
      voiceTranscriptPreview: ''
    });
  }

  async pressEnter(): Promise<void> {
    hilog.info(DOMAIN, TAG,
      'pressEnter enter editorAdapter=%{public}s',
      this.editorAdapter ? 'present' : 'absent');
    if (!this.editorAdapter) {
      hilog.warn(DOMAIN, TAG, 'pressEnter early-return: editorAdapter missing');
      return;
    }
    this.invalidatePolishActions();
    if (this.shouldUseEnglishEngine()) {
      await this.applyEnglishState(this.englishEngine.processEnter(this.shouldAutoCapitalizeEnglish()));
      return;
    }
    if (this.currentSubtype?.engine === 'librime' && this.rimeSessionId.length > 0) {
      let previousState = this.rimeService.getState(this.rimeSessionId);
      if (previousState.composingText.length > 0 || previousState.rawInput.length > 0) {
        this.clearRollbackState();
        await this.applyRimeState(this.rimeService.commitComposition(this.rimeSessionId), previousState);
        return;
      }
    }
    this.clearRollbackState();
    await this.clearCurrentPreview();
    await this.editorAdapter.insertText('\n');
    this.pendingPolishText = '';
    this.updatePolishAvailability();
    keyboardStateStore.patch({
      statusText: 'Inserted newline'
    });
  }

  async selectCandidate(index: number): Promise<void> {
    if (this.shouldUseEnglishEngine()) {
      if (!this.englishEngine.hasComposition()) {
        return;
      }
      this.invalidatePolishActions();
      await this.applyEnglishState(this.englishEngine.selectCandidate(index, this.shouldAutoCapitalizeEnglish()));
      void ImeTelemetry.trackBehavior('english_candidate_select', `index=${index}`);
      return;
    }
    if (this.rimeSessionId.length === 0) {
      return;
    }
    this.clearRollbackState();
    this.invalidatePolishActions();
    let previousState = this.rimeService.getState(this.rimeSessionId);
    let state = this.rimeService.selectCandidate(this.rimeSessionId, index);
    await this.applyRimeState(state, previousState);
    void ImeTelemetry.trackBehavior('rime_candidate_select', `index=${index};pageNo=${previousState.pageNo}`);
  }

  async pageCandidateBackward(): Promise<void> {
    this.invalidatePolishActions();
    if (this.shouldUseEnglishEngine()) {
      return;
    }
    if (this.rimeSessionId.length === 0) {
      return;
    }
    let state = this.rimeService.pageUp(this.rimeSessionId);
    await this.applyRimeState(state);
  }

  async pageCandidateForward(): Promise<void> {
    this.invalidatePolishActions();
    if (this.shouldUseEnglishEngine()) {
      return;
    }
    if (this.rimeSessionId.length === 0) {
      return;
    }
    let state = this.rimeService.pageDown(this.rimeSessionId);
    await this.applyRimeState(state);
  }

  async startVoiceInput(): Promise<void> {
    if (!this.currentSubtype || !this.activeCapabilities?.voiceEnabled) {
      keyboardStateStore.patch({
        voiceState: 'error',
        voiceStatusText: 'Voice input unavailable in sensitive field',
        statusText: 'Voice disabled by field policy'
      });
      return;
    }
    if (!this.context) {
      keyboardStateStore.patch({
        voiceState: 'error',
        voiceStatusText: 'Voice permission context unavailable'
      });
      return;
    }
    if (this.voiceCaptureService.isRecording()) {
      return;
    }
    this.invalidatePolishActions();
    let voiceConfig = this.configRepository.getConfig().voice;
    let permissionGranted = await this.permissionManager.ensureMicrophonePermission(this.context);
    if (!permissionGranted) {
      keyboardStateStore.patch({
        voiceState: 'error',
        voiceStatusText: 'Microphone permission denied',
        statusText: 'Voice permission denied'
      });
      void ImeTelemetry.trackBehavior('voice_permission_denied');
      return;
    }
    try {
      await this.voiceCaptureService.start(voiceConfig);
      this.startVoiceAutoStopTimer(voiceConfig.maxRecordSeconds);
      keyboardStateStore.patch({
        voiceState: 'recording',
        voiceStatusText: `Listening... auto stop in ${voiceConfig.maxRecordSeconds}s`,
        statusText: 'Voice capture started'
      });
      void ImeTelemetry.trackBehavior('voice_start', `subtypeId=${this.currentSubtype.id}`);
    } catch (error) {
      let errorMsg = (error as Error).message ?? JSON.stringify(error);
      hilog.error(DOMAIN, TAG, 'Failed to start voice capture: %{public}s', errorMsg);
      keyboardStateStore.patch({
        voiceState: 'error',
        voiceStatusText: `Voice capture failed: ${errorMsg}`,
        statusText: 'Voice capture unavailable'
      });
    }
  }

  async stopVoiceInput(discardResult: boolean = false): Promise<void> {
    if (!this.currentSubtype) {
      return;
    }
    this.clearVoiceAutoStopTimer();
    let voiceConfig = this.configRepository.getConfig().voice;
    let durationMs = this.voiceCaptureService.getRecordingDurationMs();
    keyboardStateStore.patch({
      voiceState: 'processing',
      voiceStatusText: discardResult ? 'Stopping voice capture...' : 'Transcribing voice input...',
      statusText: 'Voice processing'
    });
    try {
      let result = await this.voiceCaptureService.stop(voiceConfig, this.currentSubtype.locale);
      if (discardResult) {
        this.resetVoiceState();
        void ImeTelemetry.trackBehavior('voice_cancel', `durationMs=${durationMs}`);
        return;
      }
      let transcript = result.text.trim();
      if (transcript.length === 0) {
        keyboardStateStore.patch({
          voiceState: 'error',
          voiceStatusText: 'No speech recognized',
          statusText: 'Voice input returned empty transcript'
        });
        return;
      }

      this.setVoiceDraftText(transcript);

      // 自动插入识别结果，不再停留在草稿区等待确认
      await this.insertVoiceDraft();

      let statusSource: string = result.source;
      let llmConfig = this.configRepository.getConfig().llmPolish;
      if (voiceConfig.autoPolishResult && this.activeCapabilities?.polishEnabled && llmConfig.autoPolishVoiceResult) {
        keyboardStateStore.patch({
          isPolishRunning: true,
          voiceStatusText: 'Polishing transcript...',
          statusText: 'LLM polishing voice transcript'
        });
        let polishResult = await this.llmPolishService.polishText(llmConfig, {
          text: transcript,
          locale: this.currentSubtype.locale,
          subtypeId: this.currentSubtype.id,
          style: llmConfig.style
        });
        if (polishResult.text.length > 0 && polishResult.text !== transcript) {
          this.presentPolishSuggestion({
            sourceText: transcript,
            suggestedText: polishResult.text,
            source: 'voice_auto',
            provider: polishResult.source
          });
          statusSource = polishResult.source;
        }
      }

      keyboardStateStore.patch({
        isPolishRunning: false
      });
      keyboardStateStore.patch({
        voiceState: 'idle',
        voiceStatusText: `Voice ready (${statusSource})`,
        statusText: this.pendingPolishSuggestion ?
          `Voice draft ready with suggestion (${statusSource})` :
          `Voice draft ready (${statusSource})`
      });
      void ImeTelemetry.trackStatistic(
        'voice_complete',
        `durationMs=${durationMs};asrSource=${result.source};suggestionReady=${this.pendingPolishSuggestion !== undefined}`
      );
    } catch (error) {
      let errorMsg = (error as Error).message ?? JSON.stringify(error);
      hilog.error(DOMAIN, TAG, 'Failed to stop voice capture: %{public}s', errorMsg);
      keyboardStateStore.patch({
        voiceState: 'error',
        voiceStatusText: `Voice recognition failed: ${errorMsg}`,
        statusText: 'Voice recognition failed',
        isPolishRunning: false
      });
    }
  }

  async polishPendingText(): Promise<void> {
    if (!this.editorAdapter || !this.currentSubtype || !this.activeCapabilities?.polishEnabled) {
      return;
    }
    let sourceText = this.pendingPolishText.trim();
    if (sourceText.length === 0) {
      keyboardStateStore.patch({
        statusText: 'No recent text available for polishing'
      });
      return;
    }
    let llmConfig = this.configRepository.getConfig().llmPolish;
    keyboardStateStore.patch({
      isPolishRunning: true,
      statusText: 'Polishing recent text...'
    });
    try {
      let result = await this.llmPolishService.polishText(llmConfig, {
        text: sourceText,
        locale: this.currentSubtype.locale,
        subtypeId: this.currentSubtype.id,
        style: llmConfig.style
      });
      if (result.text.length === 0 || result.text === sourceText) {
        keyboardStateStore.patch({
          statusText: `Polish finished without changes (${result.source})`,
          isPolishRunning: false
        });
        return;
      }
      this.presentPolishSuggestion({
        sourceText: sourceText,
        suggestedText: result.text,
        source: 'manual',
        provider: result.source
      });
      keyboardStateStore.patch({
        statusText: `Polish suggestion ready (${result.source})`,
        voiceTranscriptPreview: result.text,
        isPolishRunning: false
      });
      void ImeTelemetry.trackBehavior('polish_suggested', `provider=${result.source};source=manual`);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Polish failed: %{public}s', JSON.stringify(error));
      keyboardStateStore.patch({
        statusText: 'LLM polish failed',
        isPolishRunning: false
      });
    }
  }

  async acceptPolishSuggestion(): Promise<void> {
    if (!this.pendingPolishSuggestion) {
      return;
    }
    let suggestion = this.pendingPolishSuggestion;
    if (suggestion.source === 'voice_auto') {
      this.pendingPolishSuggestion = undefined;
      this.lastAppliedPolish = suggestion;
      // 替换编辑器中已插入的原文
      if (this.editorAdapter && suggestion.sourceText.length > 0) {
        await this.editorAdapter.replaceRecentText(suggestion.sourceText, suggestion.suggestedText);
      }
      keyboardStateStore.patch({
        statusText: `Applied voice polish via ${suggestion.provider}`,
        showPolishSuggestion: false,
        polishSourceText: '',
        polishSuggestionText: '',
        canRevertPolish: true
      });
      void ImeTelemetry.trackBehavior('polish_apply', `provider=${suggestion.provider};source=${suggestion.source}`);
      return;
    }
    if (!this.editorAdapter) {
      return;
    }
    let applied = suggestion.sourceText.length > 0 ?
      await this.editorAdapter.replaceRecentText(suggestion.sourceText, suggestion.suggestedText) :
      await this.editorAdapter.insertText(suggestion.suggestedText);
    if (!applied) {
      keyboardStateStore.patch({
        statusText: 'Failed to apply polish suggestion'
      });
      return;
    }
    this.pendingPolishSuggestion = undefined;
    this.lastAppliedPolish = suggestion;
    this.pendingPolishText = limitPolishBuffer(suggestion.suggestedText);
    this.updatePolishAvailability();
    keyboardStateStore.patch({
      statusText: `Applied polish via ${suggestion.provider}`,
      showPolishSuggestion: false,
      polishSourceText: '',
      polishSuggestionText: '',
      canRevertPolish: true
    });
    void ImeTelemetry.trackBehavior('polish_apply', `provider=${suggestion.provider};source=${suggestion.source}`);
  }

  async dismissPolishSuggestion(): Promise<void> {
    if (!this.pendingPolishSuggestion) {
      return;
    }
    let suggestion = this.pendingPolishSuggestion;
    this.pendingPolishSuggestion = undefined;
    keyboardStateStore.patch({
      statusText: 'Kept original text',
      showPolishSuggestion: false,
      polishSourceText: '',
      polishSuggestionText: ''
    });
    void ImeTelemetry.trackBehavior('polish_keep_original', `provider=${suggestion.provider};source=${suggestion.source}`);
  }

  async revertLastPolish(): Promise<void> {
    if (!this.lastAppliedPolish) {
      return;
    }
    let rollback = this.lastAppliedPolish;
    if (rollback.source === 'voice_auto') {
      this.lastAppliedPolish = undefined;
      // 将编辑器中润色后的文字替换回原文
      if (this.editorAdapter && rollback.sourceText.length > 0) {
        await this.editorAdapter.replaceRecentText(rollback.suggestedText, rollback.sourceText);
      }
      keyboardStateStore.patch({
        statusText: 'Restored original voice draft',
        canRevertPolish: false
      });
      void ImeTelemetry.trackBehavior('polish_revert');
      return;
    }
    if (!this.editorAdapter) {
      return;
    }
    let reverted = await this.editorAdapter.replaceRecentText(rollback.suggestedText, rollback.sourceText);
    if (!reverted) {
      keyboardStateStore.patch({
        statusText: 'Failed to restore original text'
      });
      return;
    }
    this.lastAppliedPolish = undefined;
    this.pendingPolishText = limitPolishBuffer(rollback.sourceText);
    this.updatePolishAvailability();
    keyboardStateStore.patch({
      statusText: 'Restored original text',
      canRevertPolish: false
    });
    void ImeTelemetry.trackBehavior('polish_revert');
  }

  async insertVoiceDraft(): Promise<void> {
    if (!this.editorAdapter || this.pendingVoiceDraftText.trim().length === 0) {
      return;
    }
    let draft = this.pendingVoiceDraftText;
    let inserted = await this.editorAdapter.insertText(draft);
    if (!inserted) {
      keyboardStateStore.patch({
        statusText: 'Failed to insert voice draft'
      });
      return;
    }
    this.trackCommittedText(draft);
    this.clearVoiceDraftArtifacts();
    keyboardStateStore.patch({
      statusText: 'Voice draft inserted',
      voiceState: 'idle',
      voiceStatusText: 'Voice idle'
    });
  }

  async clearVoiceDraft(): Promise<void> {
    if (this.pendingVoiceDraftText.length === 0 &&
      (!this.pendingPolishSuggestion || this.pendingPolishSuggestion.source !== 'voice_auto')) {
      return;
    }
    this.clearVoiceDraftArtifacts();
    keyboardStateStore.patch({
      statusText: 'Voice draft cleared'
    });
  }

  async clearActiveInput(): Promise<void> {
    this.invalidatePolishActions();
    if (this.voiceCaptureService.isRecording()) {
      await this.stopVoiceInput(true);
      keyboardStateStore.patch({
        statusText: 'Voice capture canceled'
      });
      return;
    }
    if (this.pendingVoiceDraftText.length > 0 ||
      (this.pendingPolishSuggestion && this.pendingPolishSuggestion.source === 'voice_auto')) {
      await this.clearVoiceDraft();
      return;
    }
    if (this.shouldUseEnglishEngine() && this.englishEngine.hasComposition()) {
      this.englishEngine.reset();
      await this.clearCurrentPreview();
      this.updateEnglishCandidateState(this.englishEngine.getState(this.shouldAutoCapitalizeEnglish()));
      keyboardStateStore.patch({
        statusText: 'English composition cleared'
      });
      return;
    }
    if (this.currentSubtype?.engine === 'librime' && this.rimeSessionId.length > 0) {
      this.clearRollbackState();
      this.rimeService.clearComposition(this.rimeSessionId);
      let state = this.rimeService.getState(this.rimeSessionId);
      this.syncNineKeyStateFromRawInput(state.rawInput);
      await this.syncPreviewText(state.composingText);
      this.updateCandidateState(state);
      keyboardStateStore.patch({
        statusText: 'Composition cleared'
      });
      return;
    }
    keyboardStateStore.patch({
      statusText: 'No active composition to clear'
    });
  }

  dispose(): void {
    this.clearVoiceAutoStopTimer();
    if (this.rimeSessionId.length > 0) {
      this.rimeService.destroySession(this.rimeSessionId);
      this.rimeSessionId = '';
    }
    this.syncNineKeyState(this.nineKeyEngine.reset());
    this.clearRollbackState();
    this.resetSmartFeatureState();
  }

  private async refreshSessionContext(reason: string): Promise<void> {
    if (!this.editorAdapter || !this.currentSubtype) {
      return;
    }
    this.englishEngine.reset();
    this.invalidatePolishActions();
    this.activeSessionContext = await this.editorAdapter.buildSessionContext(this.currentSubtype, this.securityMode);
    this.editorAdapter.setPreviewEnabled(
      this.activeSessionContext.supportsPreviewText && this.configRepository.getConfig().input.enablePreviewText
    );
    this.activeCapabilities = SecurityPolicy.resolve(
      this.activeSessionContext.inputPattern,
      this.activeSessionContext.securityMode,
      this.currentSubtype.voiceEnabled && this.configRepository.getConfig().voice.enabled,
      this.currentSubtype.llmPolishEnabled && this.configRepository.getConfig().llmPolish.enabled,
      this.configRepository.getConfig().privacy.enablePersonalization
    );
    hilog.info(
      DOMAIN,
      TAG,
      'refreshSessionContext: subtype=%{public}s pattern=%{public}d securityMode=%{public}d capabilities=%{public}s',
      this.currentSubtype.id,
      this.activeSessionContext.inputPattern,
      this.activeSessionContext.securityMode,
      JSON.stringify(this.activeCapabilities)
    );
    this.activeSessionContext.keyboardLayout = this.getResolvedKeyboardLayout();

    keyboardStateStore.patch({
      sessionActive: true,
      statusText: `Session ready via ${reason}`,
      editorSummary: this.describeEditorContext(this.activeSessionContext),
      securitySummary: this.activeCapabilities.restrictedReason,
      currentSubtypeId: this.currentSubtype.id,
      currentSubtypeName: this.currentSubtype.name,
      keyboardLayout: this.getResolvedKeyboardLayout(),
      availableKeyboardLayouts: this.resolveKeyboardLayoutOptions(),
      voiceEnabled: this.activeCapabilities.voiceEnabled,
      polishEnabled: this.activeCapabilities.polishEnabled,
      voiceState: 'idle',
      voiceStatusText: this.activeCapabilities.voiceEnabled ? 'Voice idle' : 'Voice unavailable',
      voiceDraftText: this.pendingVoiceDraftText
    });
    this.updatePolishAvailability();

    if (this.shouldUseEnglishEngine()) {
      if (this.rimeSessionId.length > 0) {
        try {
          this.rimeService.clearComposition(this.rimeSessionId);
        } catch (_) {
        }
      }
      let englishState = this.englishEngine.getState(this.shouldAutoCapitalizeEnglish());
      this.updateEnglishCandidateState(englishState);
      this.syncNineKeyState(this.nineKeyEngine.reset());
      await this.syncPreviewText(englishState.composingText);
    } else if (this.currentSubtype.engine === 'librime') {
      await this.ensureRimeSessionReady();
      if (this.rimeSessionId.length > 0) {
        let state = this.rimeService.getState(this.rimeSessionId);
        this.updateCandidateState(state);
        this.syncNineKeyStateFromRawInput(state.rawInput);
        await this.syncPreviewText(state.composingText);
      }
    } else if (this.rimeSessionId.length > 0) {
      this.rimeService.destroySession(this.rimeSessionId);
      this.rimeSessionId = '';
      this.updateCandidateState(undefined);
      this.syncNineKeyState(this.nineKeyEngine.reset());
      await this.clearCurrentPreview();
    }
  }

  private async ensureRimeSessionReady(): Promise<void> {
    if (!this.context || !this.currentSubtype) {
      return;
    }
    try {
      let options = await this.configRepository.buildRimeInitOptions(this.context);
      hilog.info(
        DOMAIN,
        TAG,
        'ensureRimeSessionReady shared=%{public}s user=%{public}s schema=%{public}s version=%{public}s',
        options.sharedDataDir,
        options.userDataDir,
        options.schemaId,
        options.resourceVersion ?? ''
      );
      this.rimeService.initialize(options);
      if (this.rimeSessionId.length === 0) {
        this.rimeSessionId = this.rimeService.createSession(this.currentSubtype.schemaId ?? options.schemaId);
      } else if (this.currentSubtype.schemaId) {
        this.rimeService.setSchema(this.rimeSessionId, this.currentSubtype.schemaId);
      }
      this.rimeService.applyOptions(this.rimeSessionId, options.options);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to initialize Rime session: %{public}s', JSON.stringify(error));
      keyboardStateStore.patch({
        statusText: 'Rime initialization failed'
      });
    }
  }

  private async applyRimeState(state: RimeState, previousState?: RimeState): Promise<void> {
    hilog.info(
      DOMAIN,
      TAG,
      'Rime state raw=%{public}s composing=%{public}s candidates=%{public}d first=%{public}s',
      state.rawInput,
      state.composingText,
      state.candidates.length,
      state.candidates.length > 0 ? state.candidates[0].text : ''
    );
    if (state.commitText.length > 0 && this.editorAdapter) {
      if (previousState && previousState.rawInput.length > 0) {
        this.pendingRollback = {
          rawInput: previousState.rawInput,
          committedText: state.commitText,
          schemaId: previousState.schemaId.length > 0 ? previousState.schemaId : state.schemaId
        };
      }
      // Drop any active preedit preview first so the stale pinyin letters are
      // not finalized into the editor alongside the real commit text.
      await this.clearCurrentPreview();
      await this.editorAdapter.insertText(state.commitText);
      this.trackCommittedText(state.commitText);
    }
    await this.syncPreviewText(state.composingText);
    this.updateCandidateState(state);
    this.syncNineKeyStateFromRawInput(state.rawInput);
    keyboardStateStore.patch({
      statusText: state.commitText.length > 0 ? `Committed ${state.commitText}` :
        state.composingText.length > 0 ? `Composing ${state.composingText}` : 'Ready for input'
    });
  }

  private async applyEnglishState(state: EnglishEngineState): Promise<void> {
    if (state.commitText.length > 0 && this.editorAdapter) {
      await this.clearCurrentPreview();
      let inserted = await this.editorAdapter.insertText(state.commitText);
      if (inserted) {
        this.trackCommittedText(state.commitText);
      }
    }
    await this.syncPreviewText(state.composingText);
    this.updateEnglishCandidateState(state);
    this.syncNineKeyState(this.nineKeyEngine.reset());
    keyboardStateStore.patch({
      statusText: state.commitText.length > 0 ? 'Committed English text' :
        state.composingText.length > 0 ? `Composing ${state.composingText}` : 'Ready for input'
    });
  }

  private async commitDirectText(text: string, statusText: string): Promise<void> {
    if (!this.editorAdapter || text.length === 0) {
      return;
    }
    await this.clearCurrentPreview();
    let inserted = await this.editorAdapter.insertText(text);
    if (!inserted) {
      keyboardStateStore.patch({
        statusText: `Failed to insert "${text}"`
      });
      return;
    }
    this.trackCommittedText(text);
    keyboardStateStore.patch({
      statusText: statusText
    });
  }

  private async syncPreviewText(composingText: string): Promise<void> {
    if (!this.editorAdapter) {
      return;
    }
    if (composingText.length === 0) {
      await this.editorAdapter.clearPreviewText();
      return;
    }
    await this.editorAdapter.updatePreviewText(composingText);
  }

  private async clearCurrentPreview(): Promise<void> {
    if (!this.editorAdapter) {
      return;
    }
    await this.editorAdapter.clearPreviewText();
  }

  private updateCandidateState(state?: RimeState): void {
    if (!state) {
      keyboardStateStore.setCandidates('', [], 0, 0, false, false, -1);
      return;
    }
    keyboardStateStore.setCandidates(
      state.composingText,
      state.candidates,
      state.pageNo,
      state.pageSize,
      state.pageNo > 0,
      !state.isLastPage,
      state.highlightedCandidateIndex
    );
  }

  private updateEnglishCandidateState(state?: EnglishEngineState): void {
    if (!state) {
      keyboardStateStore.setCandidates('', [], 0, 0, false, false, -1);
      return;
    }
    keyboardStateStore.setCandidates(
      state.composingText,
      state.candidates,
      0,
      state.candidates.length,
      false,
      false,
      state.candidates.length > 0 ? 0 : -1
    );
  }

  private describeEditorContext(context: InputSessionContext): string {
    let bundleName = context.bundleName.length > 0 ? context.bundleName : 'unknown bundle';
    let abilityName = context.abilityName.length > 0 ? context.abilityName : 'unknown ability';
    let placeholder = context.placeholder.length > 0 ? `, placeholder "${context.placeholder}"` : '';
    return `${bundleName}/${abilityName}, ${SecurityPolicy.describePattern(context.inputPattern)}${placeholder}`;
  }

  private clearRollbackState(): void {
    this.pendingRollback = undefined;
  }

  private async finalizePendingRimeComposition(): Promise<void> {
    if (this.rimeSessionId.length === 0) {
      return;
    }
    try {
      let previousState = this.rimeService.getState(this.rimeSessionId);
      if (previousState.composingText.length > 0 || previousState.rawInput.length > 0) {
        let committedState = this.rimeService.commitComposition(this.rimeSessionId);
        await this.applyRimeState(committedState, previousState);
      } else {
        this.rimeService.clearComposition(this.rimeSessionId);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'finalizePendingRimeComposition failed: %{public}s', JSON.stringify(error));
    }
  }

  private persistRimeUserDataSafely(reason: string): void {
    try {
      this.rimeService.syncUserData();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'syncUserData(%{public}s) failed: %{public}s',
        reason, JSON.stringify(error));
    }
  }

  private initializeLanguageModelStore(context: InputMethodExtensionContext): void {
    let filesDir = '';
    try {
      filesDir = context.filesDir;
    } catch (_) {
      filesDir = '';
    }
    if (filesDir.length === 0) {
      return;
    }
    let dirPath = `${filesDir}/langmodel`;
    try {
      if (!fileIo.accessSync(dirPath)) {
        fileIo.mkdirSync(dirPath, true);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'langmodel mkdir failed: %{public}s', JSON.stringify(error));
      return;
    }
    let historyPath = `${dirPath}/history.tsv`;
    let store = new LanguageModelStore(historyPath);
    try {
      store.load(this.historyBigram);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'langmodel load failed: %{public}s', JSON.stringify(error));
    }
    this.languageModelStore = store;
  }

  private persistLanguageModelSafely(reason: string): void {
    if (!this.languageModelStore) {
      return;
    }
    try {
      this.languageModelStore.saveIfDirty(this.historyBigram);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'langmodel save(%{public}s) failed: %{public}s',
        reason, JSON.stringify(error));
    }
  }

  private recordLanguageModelCommit(text: string): void {
    let tokens = tokenizeForLanguageModel(text);
    if (tokens.length === 0) {
      return;
    }
    this.historyBigram.add(tokens);
    // Maintain a small tail used as bigram context for association lookup.
    for (let index = 0; index < tokens.length; index++) {
      this.associationContext.push(tokens[index]);
    }
    if (this.associationContext.length > ASSOCIATION_CONTEXT_LIMIT) {
      this.associationContext = this.associationContext.slice(
        this.associationContext.length - ASSOCIATION_CONTEXT_LIMIT);
    }
  }

  private refreshAssociationCandidates(): void {
    if (this.associationContext.length === 0) {
      return;
    }
    let words = this.prediction.predict(this.associationContext, ASSOCIATION_MAX_CANDIDATES);
    keyboardStateStore.patch({
      associations: words
    });
  }

  private clearAssociationCandidates(): void {
    this.associationContext = [];
    keyboardStateStore.patch({
      associations: []
    });
  }

  private async restoreCommittedComposition(snapshot: CommitRollbackSnapshot): Promise<void> {
    if (!this.editorAdapter || this.rimeSessionId.length === 0) {
      return;
    }
    await this.clearCurrentPreview();
    await this.editorAdapter.deleteBackward(snapshot.committedText.length);
    this.truncatePendingPolishText(snapshot.committedText.length);
    this.rimeService.clearComposition(this.rimeSessionId);
    if (snapshot.schemaId.length > 0) {
      this.rimeService.setSchema(this.rimeSessionId, snapshot.schemaId);
    }
    let restoredState = this.rimeService.syncInput(this.rimeSessionId, snapshot.rawInput);
    this.clearRollbackState();
    await this.applyRimeState(restoredState);
    keyboardStateStore.patch({
      statusText: 'Restored last composition'
    });
  }

  private trackCommittedText(text: string): void {
    if (text.length === 0) {
      return;
    }
    this.pendingPolishText = limitPolishBuffer(this.pendingPolishText + text);
    this.recordLanguageModelCommit(text);
    this.refreshAssociationCandidates();
    this.updatePolishAvailability();
  }

  private truncatePendingPolishText(length: number): void {
    if (length <= 0 || this.pendingPolishText.length === 0) {
      return;
    }
    this.pendingPolishText = this.pendingPolishText.slice(0, Math.max(0, this.pendingPolishText.length - length));
    this.updatePolishAvailability();
  }

  private updatePolishAvailability(): void {
    keyboardStateStore.patch({
      canPolish: this.pendingPolishText.trim().length > 0
    });
  }

  private async typePinyinLetter(text: string): Promise<void> {
    let normalized = text.toLowerCase();
    this.clearRollbackState();
    this.invalidatePolishActions();
    await this.ensureRimeSessionReady();
    if (this.rimeSessionId.length === 0) {
      return;
    }
    let previousState = this.rimeService.getState(this.rimeSessionId);
    let currentInput = previousState.rawInput;
    let maxCompositionLength = this.configRepository.getConfig().input.maxCompositionLength;
    let nextInput = appendDirectPinyinRawInput(currentInput, normalized, maxCompositionLength);
    if (nextInput === undefined) {
      keyboardStateStore.patch({
        statusText: 'Pinyin composition length limit reached'
      });
      return;
    }
    let state = this.rimeService.processText(this.rimeSessionId, normalized);
    await this.applyRimeState(state, previousState);
  }

  private async deletePinyinLetter(): Promise<void> {
    if (this.rimeSessionId.length === 0) {
      return;
    }
    this.clearRollbackState();
    let currentState = this.rimeService.getState(this.rimeSessionId);
    let currentInput = currentState.rawInput;
    if (currentInput.length === 0) {
      return;
    }
    let nextInput = backspaceDirectPinyinRawInput(currentInput);
    let state = nextInput.length > 0 ?
      this.rimeService.syncInput(this.rimeSessionId, nextInput) :
      this.rimeService.clearComposition(this.rimeSessionId);
    await this.applyRimeState(state, currentState);
  }

  private shouldUseDirectPinyinInput(text: string): boolean {
    return this.currentSubtype?.engine === 'librime' &&
      !this.shouldUseEnglishEngine() &&
      !this.isNineKeyLayoutActive() &&
      /^[a-zA-Z]$/.test(text);
  }

  private shouldUseDirectPinyinBackspace(): boolean {
    if (this.currentSubtype?.engine !== 'librime' || this.shouldUseEnglishEngine() || this.isNineKeyLayoutActive()) {
      return false;
    }
    if (this.rimeSessionId.length === 0) {
      return false;
    }
    let currentState = this.rimeService.getState(this.rimeSessionId);
    return currentState.rawInput.length > 0;
  }

  private async applyNineKeyState(state: NineKeyStateSnapshot): Promise<void> {
    this.syncNineKeyState(state);
    if (this.rimeSessionId.length === 0) {
      return;
    }
    let rimeState = state.activeSpelling.length > 0 ?
      this.rimeService.syncInput(this.rimeSessionId, state.activeSpelling) :
      this.rimeService.clearComposition(this.rimeSessionId);
    await this.applyRimeState(rimeState);
    keyboardStateStore.patch({
      statusText: state.activeSpelling.length > 0 ?
        `九键拼音 ${state.digitSequence} · ${state.activeSpelling}` : '九键拼音已清空'
    });
  }

  private syncNineKeyStateFromRawInput(rawInput: string): void {
    if (!this.isNineKeyLayoutActive()) {
      this.syncNineKeyState(this.nineKeyEngine.reset());
      return;
    }
    this.syncNineKeyState(this.nineKeyEngine.syncWithRawInput(rawInput));
  }

  private syncNineKeyState(state: NineKeyStateSnapshot): void {
    keyboardStateStore.setNineKeyState(state.digitSequence, state.spellings, state.activeSpelling);
  }

  private resolvePreferredKeyboardLayout(subtype: OffhandSubtypeConfig): KeyboardLayoutId {
    let supportedLayouts = this.resolveSupportedKeyboardLayouts(subtype);
    if (supportedLayouts.indexOf(this.currentKeyboardLayout) >= 0) {
      return this.currentKeyboardLayout;
    }
    if (supportedLayouts.indexOf(subtype.keyboardLayout) >= 0) {
      return subtype.keyboardLayout;
    }
    return supportedLayouts[0];
  }

  private resolveSupportedKeyboardLayouts(subtype: OffhandSubtypeConfig): KeyboardLayoutId[] {
    if (subtype.extra?.supportedKeyboardLayouts && subtype.extra.supportedKeyboardLayouts.length > 0) {
      return subtype.extra.supportedKeyboardLayouts.slice();
    }
    if (subtype.keyboardLayout === 'voice_panel') {
      return ['voice_panel'];
    }
    if (subtype.engine === 'local_english') {
      return ['qwerty_26'];
    }
    if (subtype.engine === 'librime') {
      return ['qwerty_26', 't9_9'];
    }
    return [subtype.keyboardLayout];
  }

  private resolveAvailableKeyboardLayouts(): KeyboardLayoutId[] {
    if (!this.currentSubtype) {
      return ['qwerty_26'];
    }
    if (this.currentSubtype.keyboardLayout === 'voice_panel') {
      return ['voice_panel'];
    }
    let layouts: KeyboardLayoutId[];
    if (this.shouldUseEnglishEngine()) {
      layouts = ['qwerty_26'];
    } else {
      layouts = this.resolveSupportedKeyboardLayouts(this.currentSubtype);
    }
    // 如果当前子类型支持语音，将语音面板加入可选布局
    if (this.currentSubtype.voiceEnabled && layouts.indexOf('voice_panel') < 0) {
      layouts.push('voice_panel');
    }
    return layouts;
  }

  private resolveKeyboardLayoutOptions(): KeyboardLayoutOption[] {
    return this.resolveAvailableKeyboardLayouts().map((layout: KeyboardLayoutId): KeyboardLayoutOption => ({
      id: layout,
      label: this.describeKeyboardLayout(layout)
    }));
  }

  private getResolvedKeyboardLayout(): KeyboardLayoutId {
    let availableLayouts = this.resolveAvailableKeyboardLayouts();
    if (availableLayouts.indexOf(this.currentKeyboardLayout) >= 0) {
      return this.currentKeyboardLayout;
    }
    return availableLayouts[0];
  }

  private isNineKeyLayoutActive(): boolean {
    return this.getResolvedKeyboardLayout() === 't9_9' && this.currentSubtype?.engine === 'librime' && !this.shouldUseEnglishEngine();
  }

  private describeKeyboardLayout(layout: KeyboardLayoutId): string {
    switch (layout) {
      case 't9_9':
        return '9 键';
      case 'voice_panel':
        return '语音';
      default:
        return '26 键';
    }
  }

  private resetSmartFeatureState(): void {
    this.pendingPolishText = '';
    this.pendingPolishSuggestion = undefined;
    this.lastAppliedPolish = undefined;
    this.updatePolishAvailability();
    this.resetVoiceState();
    keyboardStateStore.patch({
      showPolishSuggestion: false,
      polishSourceText: '',
      polishSuggestionText: '',
      canRevertPolish: false
    });
  }

  private resetVoiceState(): void {
    this.pendingVoiceDraftText = '';
    keyboardStateStore.patch({
      voiceState: 'idle',
      voiceStatusText: 'Voice idle',
      voiceTranscriptPreview: '',
      voiceDraftText: '',
      isPolishRunning: false
    });
  }

  private setVoiceDraftText(text: string): void {
    this.pendingVoiceDraftText = text;
    keyboardStateStore.patch({
      voiceDraftText: text,
      voiceTranscriptPreview: text
    });
  }

  private clearVoiceDraftArtifacts(): void {
    this.pendingVoiceDraftText = '';
    if (this.pendingPolishSuggestion?.source === 'voice_auto') {
      this.pendingPolishSuggestion = undefined;
    }
    if (this.lastAppliedPolish?.source === 'voice_auto') {
      this.lastAppliedPolish = undefined;
    }
    keyboardStateStore.patch({
      voiceDraftText: '',
      voiceTranscriptPreview: '',
      showPolishSuggestion: this.pendingPolishSuggestion !== undefined,
      polishSourceText: this.pendingPolishSuggestion ? this.pendingPolishSuggestion.sourceText : '',
      polishSuggestionText: this.pendingPolishSuggestion ? this.pendingPolishSuggestion.suggestedText : '',
      canRevertPolish: this.lastAppliedPolish !== undefined
    });
  }

  private shouldUseEnglishEngine(): boolean {
    if (this.currentSubtype?.engine === 'local_english') {
      return true;
    }
    return this.activeSessionContext !== undefined &&
      SecurityPolicy.isEmailOrUriPattern(this.activeSessionContext.inputPattern);
  }

  private shouldAutoCapitalizeEnglish(): boolean {
    if (this.activeSessionContext && SecurityPolicy.isEmailOrUriPattern(this.activeSessionContext.inputPattern)) {
      return false;
    }
    return this.currentSubtype?.extra?.autoCapitalize === true;
  }

  private presentPolishSuggestion(suggestion: PolishSuggestion): void {
    this.pendingPolishSuggestion = suggestion;
    this.lastAppliedPolish = undefined;
    keyboardStateStore.patch({
      showPolishSuggestion: true,
      polishSourceText: suggestion.sourceText,
      polishSuggestionText: suggestion.suggestedText,
      canRevertPolish: false
    });
  }

  private invalidatePolishActions(): void {
    this.pendingPolishSuggestion = undefined;
    this.lastAppliedPolish = undefined;
    keyboardStateStore.patch({
      showPolishSuggestion: false,
      polishSourceText: '',
      polishSuggestionText: '',
      canRevertPolish: false
    });
  }

  private startVoiceAutoStopTimer(maxRecordSeconds: number): void {
    this.clearVoiceAutoStopTimer();
    if (maxRecordSeconds <= 0) {
      return;
    }
    let timerId = setTimeout((): void => {
      this.voiceAutoStopHandle = undefined;
      void this.stopVoiceInput();
    }, maxRecordSeconds * 1000) as number;
    this.voiceAutoStopHandle = {
      timerId: timerId
    };
  }

  private clearVoiceAutoStopTimer(): void {
    if (!this.voiceAutoStopHandle) {
      return;
    }
    clearTimeout(this.voiceAutoStopHandle.timerId);
    this.voiceAutoStopHandle = undefined;
  }
}

function limitPolishBuffer(text: string): string {
  if (text.length <= MAX_POLISH_BUFFER_LENGTH) {
    return text;
  }
  return text.substring(text.length - MAX_POLISH_BUFFER_LENGTH);
}

/**
 * Tokenize a committed text segment into word-like units for the bigram.
 * - CJK ideographs (U+4E00..U+9FFF and extensions) become single-char tokens.
 * - Runs of ASCII letters/digits are combined into a single token.
 * - Whitespace/punctuation are treated as sentence separators and dropped.
 */
function tokenizeForLanguageModel(text: string): string[] {
  let tokens: string[] = [];
  let buffer = '';
  for (let codePoint of text) {
    let code = codePoint.codePointAt(0);
    if (code === undefined) {
      continue;
    }
    let isAscii = (code >= 0x30 && code <= 0x39)
      || (code >= 0x41 && code <= 0x5A)
      || (code >= 0x61 && code <= 0x7A)
      || code === 0x27; // apostrophe inside English words
    let isCjk = (code >= 0x3400 && code <= 0x9FFF)
      || (code >= 0x20000 && code <= 0x2FA1F);
    if (isAscii) {
      buffer += codePoint;
      continue;
    }
    if (buffer.length > 0) {
      tokens.push(buffer.toLowerCase());
      buffer = '';
    }
    if (isCjk) {
      tokens.push(codePoint);
    }
  }
  if (buffer.length > 0) {
    tokens.push(buffer.toLowerCase());
  }
  return tokens;
}
