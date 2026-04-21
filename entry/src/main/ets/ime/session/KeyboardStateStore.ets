import { CandidateItem, KeyboardLayoutId, KeyboardLayoutOption, SubtypeSummary, VoiceInputState } from '../common/ImeTypes';

export interface KeyboardUiState {
  isReady: boolean;
  sessionActive: boolean;
  statusText: string;
  editorSummary: string;
  securitySummary: string;
  preedit: string;
  candidates: CandidateItem[];
  currentSubtypeId: string;
  currentSubtypeName: string;
  keyboardLayout: KeyboardLayoutId;
  availableKeyboardLayouts: KeyboardLayoutOption[];
  availableSubtypes: SubtypeSummary[];
  nineKeySequence: string;
  nineKeySpellings: string[];
  activeNineKeySpelling: string;
  voiceEnabled: boolean;
  polishEnabled: boolean;
  candidatePageNo: number;
  candidatePageSize: number;
  hasPreviousCandidatePage: boolean;
  hasNextCandidatePage: boolean;
  highlightedCandidateIndex: number;
  voiceState: VoiceInputState;
  voiceStatusText: string;
  voiceTranscriptPreview: string;
  voiceDraftText: string;
  canPolish: boolean;
  isPolishRunning: boolean;
  showPolishSuggestion: boolean;
  polishSourceText: string;
  polishSuggestionText: string;
  canRevertPolish: boolean;
}

type KeyboardStateListener = (state: KeyboardUiState) => void;

const DEFAULT_STATE: KeyboardUiState = {
  isReady: false,
  sessionActive: false,
  statusText: 'Preparing IME bootstrap',
  editorSummary: 'Not attached to an editor',
  securitySummary: 'Capabilities unavailable',
  preedit: '',
  candidates: [],
  currentSubtypeId: '',
  currentSubtypeName: '',
  keyboardLayout: 'qwerty_26',
  availableKeyboardLayouts: [
    { id: 'qwerty_26', label: '26 键' }
  ],
  availableSubtypes: [],
  nineKeySequence: '',
  nineKeySpellings: [],
  activeNineKeySpelling: '',
  voiceEnabled: false,
  polishEnabled: false,
  candidatePageNo: 0,
  candidatePageSize: 0,
  hasPreviousCandidatePage: false,
  hasNextCandidatePage: false,
  highlightedCandidateIndex: -1,
  voiceState: 'idle',
  voiceStatusText: 'Voice idle',
  voiceTranscriptPreview: '',
  voiceDraftText: '',
  canPolish: false,
  isPolishRunning: false,
  showPolishSuggestion: false,
  polishSourceText: '',
  polishSuggestionText: '',
  canRevertPolish: false
};

class KeyboardStateStore {
  private state: KeyboardUiState = cloneKeyboardUiState(DEFAULT_STATE);

  private readonly listeners: Set<KeyboardStateListener> = new Set();

  getSnapshot(): KeyboardUiState {
    return cloneKeyboardUiState(this.state);
  }

  subscribe(listener: KeyboardStateListener): () => void {
    this.listeners.add(listener);
    listener(this.getSnapshot());
    return (): void => {
      this.listeners.delete(listener);
    };
  }

  patch(nextState: Partial<KeyboardUiState>): void {
    let updatedState = cloneKeyboardUiState(this.state);
    if (nextState.isReady !== undefined) {
      updatedState.isReady = nextState.isReady;
    }
    if (nextState.sessionActive !== undefined) {
      updatedState.sessionActive = nextState.sessionActive;
    }
    if (nextState.statusText !== undefined) {
      updatedState.statusText = nextState.statusText;
    }
    if (nextState.editorSummary !== undefined) {
      updatedState.editorSummary = nextState.editorSummary;
    }
    if (nextState.securitySummary !== undefined) {
      updatedState.securitySummary = nextState.securitySummary;
    }
    if (nextState.preedit !== undefined) {
      updatedState.preedit = nextState.preedit;
    }
    if (nextState.candidates !== undefined) {
      updatedState.candidates = cloneCandidates(nextState.candidates);
    }
    if (nextState.currentSubtypeId !== undefined) {
      updatedState.currentSubtypeId = nextState.currentSubtypeId;
    }
    if (nextState.currentSubtypeName !== undefined) {
      updatedState.currentSubtypeName = nextState.currentSubtypeName;
    }
    if (nextState.keyboardLayout !== undefined) {
      updatedState.keyboardLayout = nextState.keyboardLayout;
    }
    if (nextState.availableKeyboardLayouts !== undefined) {
      updatedState.availableKeyboardLayouts = cloneKeyboardLayoutOptions(nextState.availableKeyboardLayouts);
    }
    if (nextState.availableSubtypes !== undefined) {
      updatedState.availableSubtypes = cloneSubtypeSummaries(nextState.availableSubtypes);
    }
    if (nextState.nineKeySequence !== undefined) {
      updatedState.nineKeySequence = nextState.nineKeySequence;
    }
    if (nextState.nineKeySpellings !== undefined) {
      updatedState.nineKeySpellings = nextState.nineKeySpellings.slice();
    }
    if (nextState.activeNineKeySpelling !== undefined) {
      updatedState.activeNineKeySpelling = nextState.activeNineKeySpelling;
    }
    if (nextState.voiceEnabled !== undefined) {
      updatedState.voiceEnabled = nextState.voiceEnabled;
    }
    if (nextState.polishEnabled !== undefined) {
      updatedState.polishEnabled = nextState.polishEnabled;
    }
    if (nextState.candidatePageNo !== undefined) {
      updatedState.candidatePageNo = nextState.candidatePageNo;
    }
    if (nextState.candidatePageSize !== undefined) {
      updatedState.candidatePageSize = nextState.candidatePageSize;
    }
    if (nextState.hasPreviousCandidatePage !== undefined) {
      updatedState.hasPreviousCandidatePage = nextState.hasPreviousCandidatePage;
    }
    if (nextState.hasNextCandidatePage !== undefined) {
      updatedState.hasNextCandidatePage = nextState.hasNextCandidatePage;
    }
    if (nextState.highlightedCandidateIndex !== undefined) {
      updatedState.highlightedCandidateIndex = nextState.highlightedCandidateIndex;
    }
    if (nextState.voiceState !== undefined) {
      updatedState.voiceState = nextState.voiceState;
    }
    if (nextState.voiceStatusText !== undefined) {
      updatedState.voiceStatusText = nextState.voiceStatusText;
    }
    if (nextState.voiceTranscriptPreview !== undefined) {
      updatedState.voiceTranscriptPreview = nextState.voiceTranscriptPreview;
    }
    if (nextState.voiceDraftText !== undefined) {
      updatedState.voiceDraftText = nextState.voiceDraftText;
    }
    if (nextState.canPolish !== undefined) {
      updatedState.canPolish = nextState.canPolish;
    }
    if (nextState.isPolishRunning !== undefined) {
      updatedState.isPolishRunning = nextState.isPolishRunning;
    }
    if (nextState.showPolishSuggestion !== undefined) {
      updatedState.showPolishSuggestion = nextState.showPolishSuggestion;
    }
    if (nextState.polishSourceText !== undefined) {
      updatedState.polishSourceText = nextState.polishSourceText;
    }
    if (nextState.polishSuggestionText !== undefined) {
      updatedState.polishSuggestionText = nextState.polishSuggestionText;
    }
    if (nextState.canRevertPolish !== undefined) {
      updatedState.canRevertPolish = nextState.canRevertPolish;
    }
    this.state = updatedState;
    this.emit();
  }

  setCandidates(preedit: string, candidates: CandidateItem[], pageNo: number, pageSize: number,
    hasPreviousPage: boolean, hasNextPage: boolean, highlightedCandidateIndex: number): void {
    let updatedState = cloneKeyboardUiState(this.state);
    updatedState.preedit = preedit;
    updatedState.candidates = cloneCandidates(candidates);
    updatedState.candidatePageNo = pageNo;
    updatedState.candidatePageSize = pageSize;
    updatedState.hasPreviousCandidatePage = hasPreviousPage;
    updatedState.hasNextCandidatePage = hasNextPage;
    updatedState.highlightedCandidateIndex = highlightedCandidateIndex;
    this.state = updatedState;
    this.emit();
  }

  setSubtypes(subtypes: SubtypeSummary[], currentSubtypeId: string, currentSubtypeName: string): void {
    let updatedState = cloneKeyboardUiState(this.state);
    updatedState.availableSubtypes = cloneSubtypeSummaries(subtypes);
    updatedState.currentSubtypeId = currentSubtypeId;
    updatedState.currentSubtypeName = currentSubtypeName;
    this.state = updatedState;
    this.emit();
  }

  setNineKeyState(sequence: string, spellings: string[], activeSpelling: string): void {
    let updatedState = cloneKeyboardUiState(this.state);
    updatedState.nineKeySequence = sequence;
    updatedState.nineKeySpellings = spellings.slice();
    updatedState.activeNineKeySpelling = activeSpelling;
    this.state = updatedState;
    this.emit();
  }

  resetTransientState(): void {
    let updatedState = cloneKeyboardUiState(this.state);
    updatedState.sessionActive = false;
    updatedState.statusText = this.state.isReady ? 'Waiting for inputStart' : DEFAULT_STATE.statusText;
    updatedState.editorSummary = DEFAULT_STATE.editorSummary;
    updatedState.securitySummary = DEFAULT_STATE.securitySummary;
    updatedState.preedit = '';
    updatedState.candidates = [];
    updatedState.nineKeySequence = '';
    updatedState.nineKeySpellings = [];
    updatedState.activeNineKeySpelling = '';
    updatedState.voiceEnabled = false;
    updatedState.polishEnabled = false;
    updatedState.candidatePageNo = 0;
    updatedState.candidatePageSize = 0;
    updatedState.hasPreviousCandidatePage = false;
    updatedState.hasNextCandidatePage = false;
    updatedState.highlightedCandidateIndex = -1;
    updatedState.voiceState = 'idle';
    updatedState.voiceStatusText = DEFAULT_STATE.voiceStatusText;
    updatedState.voiceTranscriptPreview = '';
    updatedState.voiceDraftText = '';
    updatedState.canPolish = false;
    updatedState.isPolishRunning = false;
    updatedState.showPolishSuggestion = false;
    updatedState.polishSourceText = '';
    updatedState.polishSuggestionText = '';
    updatedState.canRevertPolish = false;
    this.state = updatedState;
    this.emit();
  }

  private emit(): void {
    let snapshot = this.getSnapshot();
    this.listeners.forEach((listener: KeyboardStateListener): void => {
      listener(snapshot);
    });
  }
}

export const keyboardStateStore: KeyboardStateStore = new KeyboardStateStore();

function cloneKeyboardUiState(source: KeyboardUiState): KeyboardUiState {
  let state: KeyboardUiState = {
    isReady: source.isReady,
    sessionActive: source.sessionActive,
    statusText: source.statusText,
    editorSummary: source.editorSummary,
    securitySummary: source.securitySummary,
    preedit: source.preedit,
    candidates: cloneCandidates(source.candidates),
    currentSubtypeId: source.currentSubtypeId,
    currentSubtypeName: source.currentSubtypeName,
    keyboardLayout: source.keyboardLayout,
    availableKeyboardLayouts: cloneKeyboardLayoutOptions(source.availableKeyboardLayouts),
    availableSubtypes: cloneSubtypeSummaries(source.availableSubtypes),
    nineKeySequence: source.nineKeySequence,
    nineKeySpellings: source.nineKeySpellings.slice(),
    activeNineKeySpelling: source.activeNineKeySpelling,
    voiceEnabled: source.voiceEnabled,
    polishEnabled: source.polishEnabled,
    candidatePageNo: source.candidatePageNo,
    candidatePageSize: source.candidatePageSize,
    hasPreviousCandidatePage: source.hasPreviousCandidatePage,
    hasNextCandidatePage: source.hasNextCandidatePage,
    highlightedCandidateIndex: source.highlightedCandidateIndex,
    voiceState: source.voiceState,
    voiceStatusText: source.voiceStatusText,
    voiceTranscriptPreview: source.voiceTranscriptPreview,
    voiceDraftText: source.voiceDraftText,
    canPolish: source.canPolish,
    isPolishRunning: source.isPolishRunning,
    showPolishSuggestion: source.showPolishSuggestion,
    polishSourceText: source.polishSourceText,
    polishSuggestionText: source.polishSuggestionText,
    canRevertPolish: source.canRevertPolish
  };
  return state;
}

function cloneCandidates(source: CandidateItem[]): CandidateItem[] {
  let candidates: CandidateItem[] = [];
  for (let index = 0; index < source.length; index++) {
    let candidate: CandidateItem = {
      index: source[index].index,
      text: source[index].text,
      comment: source[index].comment,
      label: source[index].label,
      highlighted: source[index].highlighted
    };
    candidates.push(candidate);
  }
  return candidates;
}

function cloneSubtypeSummaries(source: SubtypeSummary[]): SubtypeSummary[] {
  let summaries: SubtypeSummary[] = [];
  for (let index = 0; index < source.length; index++) {
    let summary: SubtypeSummary = {
      id: source[index].id,
      name: source[index].name
    };
    summaries.push(summary);
  }
  return summaries;
}

function cloneKeyboardLayoutOptions(source: KeyboardLayoutOption[]): KeyboardLayoutOption[] {
  let options: KeyboardLayoutOption[] = [];
  for (let index = 0; index < source.length; index++) {
    options.push({
      id: source[index].id,
      label: source[index].label
    });
  }
  return options;
}
