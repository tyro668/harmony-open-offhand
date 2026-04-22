import { hilog } from '@kit.PerformanceAnalysisKit';
import nativeBridge from 'libentry.so';
import { CandidateItem, RimeInitOptions, RimeOptionState, RimeState } from '../../common/ImeTypes';

const DOMAIN = 0xFF10;
const TAG = 'RimeService';
const BACKSPACE_KEY_CODE = 8;
const SPACE_KEY_CODE = 32;

interface NativeStatusEnvelope {
  ok: boolean;
  message?: string;
}

interface NativeRimeBridgeModule {
  init(sharedDataDir: string, userDataDir: string): string;
  deployIfNeeded(): string;
  createSession(schemaId: string): string;
  destroySession(sessionId: string): void;
  processKey(sessionId: string, keyCode: number, modifier: number): string;
  getState(sessionId: string): string;
  selectCandidate(sessionId: string, index: number): string;
  setSchema(sessionId: string, schemaId: string): string;
  setOption(sessionId: string, optionName: string, value: boolean): string;
  clearComposition(sessionId: string): string;
  commitComposition(sessionId: string): string;
  setInput(sessionId: string, input: string): string;
  pageUp(sessionId: string): string;
  pageDown(sessionId: string): string;
  syncUserData(): string;
}

const bridge: NativeRimeBridgeModule = nativeBridge as NativeRimeBridgeModule;

export class RimeService {
  private initialized: boolean = false;
  private initSignature: string = '';

  initialize(options: RimeInitOptions): void {
    let nextSignature = `${options.sharedDataDir}|${options.userDataDir}|${options.resourceVersion ?? ''}`;
    if (this.initialized && this.initSignature === nextSignature) {
      return;
    }
    let initStatus = bridge.init(options.sharedDataDir, options.userDataDir);
    hilog.info(DOMAIN, TAG, 'init status %{public}s', initStatus);
    this.ensureStatusOk(initStatus, 'init');
    let deployStatus = bridge.deployIfNeeded();
    hilog.info(DOMAIN, TAG, 'deploy status %{public}s', deployStatus);
    this.ensureStatusOk(deployStatus, 'deploy');
    this.initialized = true;
    this.initSignature = nextSignature;
  }

  createSession(schemaId: string): string {
    let sessionId = bridge.createSession(schemaId);
    hilog.info(DOMAIN, TAG, 'createSession(%{public}s) => %{public}s', schemaId, sessionId);
    return sessionId;
  }

  destroySession(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    bridge.destroySession(sessionId);
  }

  processText(sessionId: string, text: string): RimeState {
    let state = this.getState(sessionId);
    for (let index = 0; index < text.length; index++) {
      state = this.processKey(sessionId, text.charCodeAt(index), 0);
    }
    return state;
  }

  processSpace(sessionId: string): RimeState {
    return this.processKey(sessionId, SPACE_KEY_CODE, 0);
  }

  processBackspace(sessionId: string): RimeState {
    return this.processKey(sessionId, BACKSPACE_KEY_CODE, 0);
  }

  processKey(sessionId: string, keyCode: number, modifier: number): RimeState {
    return this.parseRimeState(bridge.processKey(sessionId, keyCode, modifier));
  }

  getState(sessionId: string): RimeState {
    return this.parseRimeState(bridge.getState(sessionId));
  }

  selectCandidate(sessionId: string, index: number): RimeState {
    return this.parseRimeState(bridge.selectCandidate(sessionId, index));
  }

  setSchema(sessionId: string, schemaId: string): RimeState {
    return this.parseRimeState(bridge.setSchema(sessionId, schemaId));
  }

  applyOptions(sessionId: string, options: RimeOptionState): RimeState {
    let state = this.getState(sessionId);
    state = this.parseRimeState(bridge.setOption(sessionId, 'ascii_mode', options.ascii_mode));
    state = this.parseRimeState(bridge.setOption(sessionId, 'full_shape', options.full_shape));
    if (options.emoji_suggestion !== undefined) {
      state = this.parseRimeState(bridge.setOption(sessionId, 'emoji_suggestion', options.emoji_suggestion));
    }
    return state;
  }

  clearComposition(sessionId: string): RimeState {
    return this.parseRimeState(bridge.clearComposition(sessionId));
  }

  commitComposition(sessionId: string): RimeState {
    return this.parseRimeState(bridge.commitComposition(sessionId));
  }

  setInput(sessionId: string, input: string): RimeState {
    return this.parseRimeState(bridge.setInput(sessionId, input));
  }

  syncInput(sessionId: string, targetInput: string): RimeState {
    let state = this.getState(sessionId);
    let currentInput = state.rawInput ?? '';
    if (targetInput === currentInput) {
      return state;
    }
    let prefixLength = commonPrefixLength(currentInput, targetInput);
    while (currentInput.length > prefixLength) {
      state = this.processBackspace(sessionId);
      currentInput = state.rawInput ?? '';
    }
    for (let index = prefixLength; index < targetInput.length; index++) {
      state = this.processKey(sessionId, targetInput.charCodeAt(index), 0);
    }
    return state;
  }

  pageUp(sessionId: string): RimeState {
    return this.parseRimeState(bridge.pageUp(sessionId));
  }

  pageDown(sessionId: string): RimeState {
    return this.parseRimeState(bridge.pageDown(sessionId));
  }

  syncUserData(): void {
    this.ensureStatusOk(bridge.syncUserData(), 'syncUserData');
  }

  private ensureStatusOk(raw: string, action: string): void {
    let envelope = JSON.parse(raw) as NativeStatusEnvelope;
    if (envelope.ok !== true) {
      throw new Error(envelope.message ? envelope.message : `${action} failed`);
    }
  }

  private parseRimeState(raw: string): RimeState {
    try {
      let state = JSON.parse(raw) as RimeState;
      let candidates = normalizeCandidates(state.candidates);
      return {
        schemaId: state.schemaId ?? 'offhand_pinyin',
        rawInput: state.rawInput ?? '',
        composingText: state.composingText ?? '',
        commitText: state.commitText ?? '',
        candidates: candidates,
        isAsciiMode: state.isAsciiMode === true,
        options: state.options ? state.options : defaultOptions(),
        pageSize: typeof state.pageSize === 'number' ? state.pageSize : 0,
        pageNo: typeof state.pageNo === 'number' ? state.pageNo : 0,
        isLastPage: state.isLastPage === true,
        highlightedCandidateIndex: typeof state.highlightedCandidateIndex === 'number' ? state.highlightedCandidateIndex : -1,
        selectKeys: typeof state.selectKeys === 'string' ? state.selectKeys : ''
      };
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to parse native Rime state: %{public}s', JSON.stringify(error));
      return emptyRimeState();
    }
  }
}

function normalizeCandidates(source: CandidateItem[] | undefined): CandidateItem[] {
  let candidates: CandidateItem[] = [];
  if (!Array.isArray(source)) {
    return candidates;
  }
  for (let index = 0; index < source.length; index++) {
    let candidate: CandidateItem = {
      index: source[index].index,
      text: source[index].text ?? '',
      comment: source[index].comment ?? '',
      label: source[index].label ?? `${source[index].index + 1}`,
      highlighted: source[index].highlighted === true
    };
    candidates.push(candidate);
  }
  return candidates;
}

function emptyRimeState(): RimeState {
  return {
    schemaId: 'offhand_pinyin',
    rawInput: '',
    composingText: '',
    commitText: '',
    candidates: [],
    isAsciiMode: false,
    options: defaultOptions(),
    pageSize: 0,
    pageNo: 0,
    isLastPage: true,
    highlightedCandidateIndex: -1,
    selectKeys: ''
  };
}

function defaultOptions(): RimeOptionState {
  let options: RimeOptionState = {
    ascii_mode: false,
    full_shape: false
  };
  return options;
}

function commonPrefixLength(left: string, right: string): number {
  let length = Math.min(left.length, right.length);
  let index = 0;
  while (index < length && left[index] === right[index]) {
    index++;
  }
  return index;
}
