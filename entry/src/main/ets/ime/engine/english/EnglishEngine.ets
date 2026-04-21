import { CandidateItem } from '../../common/ImeTypes';

export interface EnglishEngineState {
  rawInput: string;
  composingText: string;
  commitText: string;
  candidates: CandidateItem[];
}

const MAX_CANDIDATES = 6;
const COMMON_WORDS: string[] = [
  'about', 'account', 'agent', 'all', 'allow', 'already', 'also', 'and', 'api', 'app',
  'apply', 'are', 'article', 'background', 'because', 'before', 'between', 'browser',
  'build', 'button', 'call', 'candidate', 'chat', 'check', 'clear', 'client', 'cloud',
  'code', 'config', 'contact', 'content', 'continue', 'create', 'default', 'delete',
  'deploy', 'design', 'device', 'email', 'engine', 'enter', 'error', 'event', 'field',
  'finish', 'follow', 'formal', 'good', 'great', 'hello', 'http', 'https', 'input',
  'language', 'layout', 'link', 'meeting', 'message', 'model', 'network', 'note',
  'office', 'offhand', 'open', 'option', 'panel', 'password', 'people', 'please',
  'polish', 'preview', 'project', 'prompt', 'request', 'result', 'review', 'route',
  'schema', 'screen', 'server', 'session', 'setting', 'smart', 'space', 'start',
  'status', 'store', 'style', 'support', 'switch', 'system', 'text', 'thanks',
  'today', 'update', 'url', 'user', 'value', 'voice', 'want', 'when', 'where',
  'window', 'work', 'write', 'www'
];

export class EnglishEngine {
  private rawInput: string = '';
  private capitalizeNext: boolean = true;

  reset(): void {
    this.rawInput = '';
  }

  hasComposition(): boolean {
    return this.rawInput.length > 0;
  }

  typeText(text: string, autoCapitalize: boolean): EnglishEngineState {
    let normalized = normalizeCharacter(text);
    if (normalized.length === 0) {
      return this.snapshot('');
    }
    this.rawInput += normalized;
    return this.snapshot('', autoCapitalize);
  }

  processBackspace(autoCapitalize: boolean): EnglishEngineState {
    if (this.rawInput.length > 0) {
      this.rawInput = this.rawInput.substring(0, this.rawInput.length - 1);
    }
    return this.snapshot('', autoCapitalize);
  }

  processSpace(autoCapitalize: boolean): EnglishEngineState {
    if (this.rawInput.length === 0) {
      return this.snapshot(' ');
    }
    let selected = this.resolveSelectedWord(autoCapitalize);
    this.rawInput = '';
    this.capitalizeNext = false;
    return this.snapshot(`${selected} `);
  }

  processEnter(autoCapitalize: boolean): EnglishEngineState {
    if (this.rawInput.length === 0) {
      this.capitalizeNext = true;
      return this.snapshot('\n');
    }
    let selected = this.resolveSelectedWord(autoCapitalize);
    this.rawInput = '';
    this.capitalizeNext = true;
    return this.snapshot(`${selected}\n`);
  }

  selectCandidate(index: number, autoCapitalize: boolean): EnglishEngineState {
    if (this.rawInput.length === 0) {
      return this.snapshot('');
    }
    let candidates = this.buildCandidates(autoCapitalize);
    let candidate = index >= 0 && index < candidates.length ? candidates[index] : candidates[0];
    let selected = candidate ? candidate.text : this.formatWord(this.rawInput, autoCapitalize);
    this.rawInput = '';
    this.capitalizeNext = false;
    return this.snapshot(selected);
  }

  getState(autoCapitalize: boolean): EnglishEngineState {
    return this.snapshot('', autoCapitalize);
  }

  private snapshot(commitText: string, autoCapitalize: boolean = false): EnglishEngineState {
    let candidates = this.buildCandidates(autoCapitalize);
    let composingText = this.rawInput.length > 0 ? this.formatWord(this.rawInput, autoCapitalize) : '';
    return {
      rawInput: this.rawInput,
      composingText: composingText,
      commitText: commitText,
      candidates: candidates
    };
  }

  private buildCandidates(autoCapitalize: boolean): CandidateItem[] {
    if (this.rawInput.length === 0) {
      return [];
    }
    let buffer = this.rawInput.toLowerCase();
    let words: string[] = [];
    addUnique(words, this.formatWord(buffer, autoCapitalize));
    for (let index = 0; index < COMMON_WORDS.length && words.length < MAX_CANDIDATES; index++) {
      let word = COMMON_WORDS[index];
      if (!word.startsWith(buffer)) {
        continue;
      }
      addUnique(words, this.formatWord(word, autoCapitalize));
    }
    if (words.length < 2) {
      addUnique(words, this.formatWord(`${buffer}s`, autoCapitalize));
      addUnique(words, this.formatWord(`${buffer}ing`, autoCapitalize));
    }
    let candidates: CandidateItem[] = [];
    for (let index = 0; index < words.length && index < MAX_CANDIDATES; index++) {
      candidates.push({
        index: index,
        text: words[index],
        comment: index === 0 ? 'typed' : 'match',
        label: `${index + 1}`,
        highlighted: index === 0
      });
    }
    return candidates;
  }

  private resolveSelectedWord(autoCapitalize: boolean): string {
    let candidates = this.buildCandidates(autoCapitalize);
    if (candidates.length > 0) {
      return candidates[0].text;
    }
    return this.formatWord(this.rawInput, autoCapitalize);
  }

  private formatWord(word: string, autoCapitalize: boolean): string {
    if (!autoCapitalize || !this.capitalizeNext || word.length === 0) {
      return word;
    }
    return word[0].toUpperCase() + word.substring(1);
  }
}

function normalizeCharacter(text: string): string {
  if (!/^[a-zA-Z]$/.test(text)) {
    return '';
  }
  return text.toLowerCase();
}

function addUnique(target: string[], value: string): void {
  if (value.length === 0) {
    return;
  }
  if (target.indexOf(value) >= 0) {
    return;
  }
  target.push(value);
}
