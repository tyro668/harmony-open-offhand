export interface NineKeyStateSnapshot {
  digitSequence: string;
  spellings: string[];
  activeSpelling: string;
}

/*
 * 9-key pinyin segmenter — algorithmic counterpart to
 * fcitx5-chinese-addons' pinyin decoder (im/pinyin/pinyin.cpp) and
 * libime::PinyinSegmenter (others/libime/src/libime/pinyin/
 * pinyinsegmenter.{h,cpp}).
 *
 * Single-key-multi-letter disambiguation strategy:
 *   - Each digit 2..9 maps to 3 or 4 letters via the ITU-T E.161 layout
 *     (the same one fcitx5 uses for its T9 lookup tables).
 *   - A digit sequence is treated as a DAG: each position can start a
 *     syllable consuming 1..N digits. Edges are weighted by the rank of
 *     the syllable in RANKED_PINYIN_SYLLABLES so that common syllables
 *     like "yi/ji/di" out-compete rare ones that share the same digit
 *     prefix (e.g. "yi"=94 beats "xi"=94 through rank ordering because
 *     we cache the best result per start position).
 *   - Top-K spellings are extracted with memoised DFS + per-position
 *     beam pruning (MAX_SPELLINGS), which is equivalent to libime's
 *     SegmentGraph k-shortest-path walk for small sequences.
 *   - Partial finals (digit prefix that doesn't complete a syllable) are
 *     admitted with PARTIAL_FINAL_COST so that mid-word candidates are
 *     still offered while keeping them behind any completed parse.
 */


interface RankedPinyinSyllable {
  text: string;
  digits: string;
  rank: number;
}

interface ResolvedSpelling {
  text: string;
  score: number;
  segmentCount: number;
  hasPartial: boolean;
}

const MAX_SPELLINGS: number = 12;
const MAX_SEGMENT_COUNT: number = 6;
const FULL_SEGMENT_COST: number = 8;
// Partial-tail segments (digit prefix that doesn't complete a syllable) are
// allowed so that users typing mid-word still see a reasonable preview, but
// they must never outrank a parse in which every segment is a real syllable.
// The score adder below is only used as a tie-break within the partial set —
// the dominant signal is the `hasPartial` flag in compareCandidate.
const PARTIAL_FINAL_COST: number = 220;
const RANKED_PINYIN_SYLLABLES: string[] = (
  'yi ji di zhi yu xi shi qi xing li yan de jian wei fu xian jiao zhong ju jie qian lu chang wu yin bi hui bo qu ' +
  'shen zhu he yao zhang hu chi jue you shu jin yuan jia zi xie jing bu ye xu lv ying xiao zhen cheng mo huan e ' +
  'chu si pi gui gu dan ge sheng zheng hang tan chan yun xiang xuan du zhan yang ti fan le han lian shan xia zhuo ' +
  'yue qiu su gan qiao ke gao ling wan qing xun huo ni tiao liao diao zhe guo gong can zong fei chong tu liu wen ' +
  'mi chen lan jun dian luo da zha bao guan zhao tuo tong ren kui fen ya hao bei duo yong qin jiu hua hong ta ' +
  'quan mei lin tian dao ai chou sui feng dong xin lei an pu juan mu jiang shui qiang zhou tang chao cha long ' +
  'huang she mao bian ba er sha gou ci dai ao zhuan xue me xiu nie peng min fa bing ru die cong ping biao tai ' +
  'fang zu ting rong kai gai man ze meng lai tao pei mian lao shang shou po na kuang kuai ban que dou pan zan wo ' +
  'suo liang kan bin zuo lou gua dang cui cang kun hai dui wang chuan qie ma gang zao zai ding zui nian chun hou ' +
  'geng dun cuo pian la bang zeng song ou ming lang hun cu tui san tun mang ku kang guang chuo che wa shao lie ' +
  'tou mou beng zhai sou qiong nao zhuang se piao ceng pin nan chuang bai sai pang lun shuo pao kou zang heng ' +
  'zou ning cai zhui nuo nong men jiong ce ben za sun miao mai deng cao zun tuan rou rui luan kao duan chai ran ' +
  'pa nei chui pai kong keng shuang sao qia xiong niu nai ka hen zhun mie huai gun cuan ruan weng shuai sa kua ' +
  'rang leng cun bie xx tie kuo ga te ruo rao teng pou nu kuan zuan ken guai cen wai shun qun nv niao neng re ' +
  'pen o fou ang suan nou a shai sang ne nang lve gen pie ri gei zhua run lvan en nuan sen reng lia ca yai ' +
  'shuan nve hei ha dei chuai shua nin niang cou zen yo miu fo diu nen ei zhuai zei seng nun nia eng chua zhei ' +
  'shei eh tei sei lo fong fiao dia den'
).split(' ');
const PINYIN_SYLLABLES: RankedPinyinSyllable[] = buildRankedSyllables(RANKED_PINYIN_SYLLABLES);

export class PinyinNineKeyEngine {
  private digitSequence: string = '';
  private spellings: string[] = [];
  private activeSpelling: string = '';

  reset(): NineKeyStateSnapshot {
    this.digitSequence = '';
    this.spellings = [];
    this.activeSpelling = '';
    return this.snapshot();
  }

  hasComposition(): boolean {
    return this.digitSequence.length > 0;
  }

  getState(): NineKeyStateSnapshot {
    return this.snapshot();
  }

  appendDigit(digit: string): NineKeyStateSnapshot {
    if (!isNineKeyDigit(digit)) {
      return this.snapshot();
    }
    this.digitSequence += digit;
    return this.rebuild();
  }

  backspace(): NineKeyStateSnapshot {
    if (this.digitSequence.length === 0) {
      return this.snapshot();
    }
    this.digitSequence = this.digitSequence.substring(0, this.digitSequence.length - 1);
    return this.rebuild();
  }

  selectSpelling(spelling: string): NineKeyStateSnapshot {
    let normalized = normalizeSpelling(spelling);
    if (normalized.length === 0 || !isCompatibleSpelling(this.digitSequence, normalized)) {
      return this.snapshot();
    }
    return this.rebuild(normalized);
  }

  syncWithRawInput(rawInput: string): NineKeyStateSnapshot {
    let normalized = normalizeSpelling(rawInput);
    if (normalized.length === 0) {
      return this.reset();
    }
    this.digitSequence = spellingToDigits(normalized);
    return this.rebuild(normalized);
  }

  private rebuild(preferredSpelling?: string): NineKeyStateSnapshot {
    if (this.digitSequence.length === 0) {
      this.spellings = [];
      this.activeSpelling = '';
      return this.snapshot();
    }
    let resolved = resolveSpellings(this.digitSequence, MAX_SPELLINGS);
    let preferred = preferredSpelling ? normalizeSpelling(preferredSpelling) : '';
    if (preferred.length > 0 && isCompatibleSpelling(this.digitSequence, preferred) && resolved.indexOf(preferred) < 0) {
      resolved.unshift(preferred);
    }
    this.spellings = dedupeSpellings(resolved, MAX_SPELLINGS);
    if (preferred.length > 0 && this.spellings.indexOf(preferred) >= 0) {
      this.activeSpelling = preferred;
    } else if (this.activeSpelling.length > 0 && this.spellings.indexOf(this.activeSpelling) >= 0) {
      this.activeSpelling = this.activeSpelling;
    } else {
      this.activeSpelling = this.spellings.length > 0 ? this.spellings[0] : '';
    }
    return this.snapshot();
  }

  private snapshot(): NineKeyStateSnapshot {
    return {
      digitSequence: this.digitSequence,
      spellings: this.spellings.slice(),
      activeSpelling: this.activeSpelling
    };
  }
}

function resolveSpellings(digitSequence: string, limit: number): string[] {
  if (digitSequence.length === 0) {
    return [];
  }
  let cache: Array<ResolvedSpelling[] | undefined> = [];
  let results = resolveSpellingsFromPosition(digitSequence, 0, limit, cache);
  let rescored = applyLinguisticBias(results);
  let spellings: string[] = [];
  for (let index = 0; index < rescored.length && spellings.length < limit; index++) {
    if (rescored[index].text.length === 0 || spellings.indexOf(rescored[index].text) >= 0) {
      continue;
    }
    spellings.push(rescored[index].text);
  }
  return spellings;
}

/**
 * Top-level rescoring pass that injects tiny linguistic biases we cannot
 * express with per-syllable rank arithmetic alone. Without a phrase
 * dictionary we can still leverage two strong Chinese regularities:
 *
 *   - Reduplication (\u53e0\u5b57): doubled full syllables are extremely common for
 *     kinship and affective words (\u5988\u5988/\u7238\u7238/\u54e5\u54e5/\u59d0\u59d0/\u8c22\u8c22/\u54c8\u54c8...). When every
 *     segment is the same syllable, bump the score hard so e.g. "mama"
 *     clears "nana"/"mana"/"nama" for digit sequence 6262.
 *   - Balanced segmentation: parses whose segments are all the same
 *     length (two 2-char syllables, three 2-char syllables, ...) read as
 *     words far more often than lopsided splits; a small bump helps the
 *     right reading surface first without overwhelming rank signal.
 *
 * We only rescore full parses (hasPartial==false) so partial-tail drafts
 * keep their existing relative order.
 */
function applyLinguisticBias(source: ResolvedSpelling[]): ResolvedSpelling[] {
  let adjusted: ResolvedSpelling[] = [];
  for (let index = 0; index < source.length; index++) {
    let entry = source[index];
    let nextScore = entry.score;
    if (!entry.hasPartial && entry.segmentCount >= 2) {
      let segments = splitIntoSyllables(entry.text, entry.segmentCount);
      if (segments.length === entry.segmentCount) {
        if (isReduplicated(segments)) {
          nextScore -= reduplicationBonusFor(segments[0]);
        } else if (isBalancedSegmentation(segments)) {
          nextScore -= 40;
        }
      }
    }
    adjusted.push({
      text: entry.text,
      score: nextScore,
      segmentCount: entry.segmentCount,
      hasPartial: entry.hasPartial
    });
  }
  adjusted.sort((left: ResolvedSpelling, right: ResolvedSpelling): number => compareCandidate(left, right));
  return adjusted;
}

/**
 * Split a concatenated spelling back into its original syllables. The
 * recursive decoder assembles `text` by append, and every segment comes
 * from RANKED_PINYIN_SYLLABLES, so we can recover the split greedily by
 * consuming the longest known syllable at each offset. If the split
 * disagrees with `expectedSegments`, callers skip the bias (safe fallback).
 */
function splitIntoSyllables(text: string, expectedSegments: number): string[] {
  let segments: string[] = [];
  let offset = 0;
  while (offset < text.length) {
    if (segments.length >= expectedSegments) {
      return [];
    }
    let matched = '';
    for (let index = 0; index < PINYIN_SYLLABLES.length; index++) {
      let syllable = PINYIN_SYLLABLES[index];
      if (text.substring(offset, offset + syllable.text.length) === syllable.text
        && syllable.text.length > matched.length) {
        matched = syllable.text;
      }
    }
    if (matched.length === 0) {
      return [];
    }
    segments.push(matched);
    offset += matched.length;
  }
  return segments;
}

function isReduplicated(segments: string[]): boolean {
  if (segments.length < 2) {
    return false;
  }
  let first = segments[0];
  for (let index = 1; index < segments.length; index++) {
    if (segments[index] !== first) {
      return false;
    }
  }
  return true;
}

/**
 * Common doubled-morpheme words in modern spoken Chinese. When a parse
 * doubles one of these syllables we give it an extra bump so genuine
 * kinship/affective/onomatopoeic words win against structurally identical
 * but semantically empty doublings. Order is significance-sorted for
 * readability only \u2014 membership is all that matters.
 */
const COMMON_DOUBLED_SYLLABLES: string[] = [
  'ma', 'ba', 'ge', 'jie', 'di', 'mei', 'nai', 'ye', 'shu', 'gu',
  'xie', 'ha', 'he', 'hei', 'pa', 'po', 'zai', 'kan', 'shuo', 'tian',
  'man', 'ping', 'qing', 'wen', 'shi', 'xing', 'chang', 'zhen', 'gang',
  'ding', 'jiu', 'gun', 'pang', 'mi', 'pi', 'niu', 'gou', 'hu', 'meng'
];

function reduplicationBonusFor(segment: string): number {
  for (let index = 0; index < COMMON_DOUBLED_SYLLABLES.length; index++) {
    if (COMMON_DOUBLED_SYLLABLES[index] === segment) {
      return 600;
    }
  }
  return 150;
}

function isBalancedSegmentation(segments: string[]): boolean {
  if (segments.length < 2) {
    return false;
  }
  let length = segments[0].length;
  for (let index = 1; index < segments.length; index++) {
    if (segments[index].length !== length) {
      return false;
    }
  }
  return true;
}

function resolveSpellingsFromPosition(digitSequence: string, position: number, limit: number,
  cache: Array<ResolvedSpelling[] | undefined>): ResolvedSpelling[] {
  if (position === digitSequence.length) {
    return [{ text: '', score: 0, segmentCount: 0, hasPartial: false }];
  }
  if (cache[position]) {
    return cache[position] as ResolvedSpelling[];
  }
  let remainingDigits = digitSequence.substring(position);
  let candidates: ResolvedSpelling[] = [];
  for (let index = 0; index < PINYIN_SYLLABLES.length; index++) {
    let syllable = PINYIN_SYLLABLES[index];
    if (remainingDigits.length < syllable.digits.length) {
      if (syllable.digits.substring(0, remainingDigits.length) === remainingDigits) {
        let partialText = syllable.text.substring(0, remainingDigits.length);
        candidates.push({
          text: partialText,
          score: syllable.rank + PARTIAL_FINAL_COST,
          segmentCount: 1,
          hasPartial: true
        });
      }
      continue;
    }
    if (!matchesAt(digitSequence, syllable.digits, position)) {
      continue;
    }
    let nextPosition = position + syllable.digits.length;
    let suffixes = resolveSpellingsFromPosition(digitSequence, nextPosition, limit, cache);
    for (let suffixIndex = 0; suffixIndex < suffixes.length; suffixIndex++) {
      let suffix = suffixes[suffixIndex];
      if (suffix.segmentCount >= MAX_SEGMENT_COUNT) {
        continue;
      }
      candidates.push({
        text: syllable.text + suffix.text,
        score: syllable.rank + FULL_SEGMENT_COST + suffix.score,
        segmentCount: suffix.segmentCount + 1,
        hasPartial: suffix.hasPartial
      });
    }
  }
  let best = rankCandidates(candidates, limit);
  cache[position] = best;
  return best;
}

function buildRankedSyllables(syllables: string[]): RankedPinyinSyllable[] {
  let entries: RankedPinyinSyllable[] = [];
  for (let index = 0; index < syllables.length; index++) {
    let syllable = syllables[index];
    entries.push({
      text: syllable,
      digits: spellingToDigits(syllable),
      rank: index
    });
  }
  return entries;
}

function rankCandidates(source: ResolvedSpelling[], limit: number): ResolvedSpelling[] {
  let bestByText: Map<string, ResolvedSpelling> = new Map();
  for (let index = 0; index < source.length; index++) {
    let existing = bestByText.get(source[index].text);
    if (!existing || compareCandidate(source[index], existing) < 0) {
      bestByText.set(source[index].text, source[index]);
    }
  }
  let ranked = Array.from(bestByText.values());
  ranked.sort((left: ResolvedSpelling, right: ResolvedSpelling): number => compareCandidate(left, right));
  if (ranked.length > limit) {
    return ranked.slice(0, limit);
  }
  return ranked;
}

function compareCandidate(left: ResolvedSpelling, right: ResolvedSpelling): number {
  // All-full parses (e.g. "mama" for 6262) must rank ahead of any parse
  // with a trailing partial syllable (e.g. "maoc"). Without this guard,
  // a cheap 1-letter partial sourced from a very common syllable such as
  // "cheng" or "bu" can beat a genuine two-syllable word on rank-sum
  // arithmetic even when the full parse obviously reads better.
  if (left.hasPartial !== right.hasPartial) {
    return left.hasPartial ? 1 : -1;
  }
  if (left.score !== right.score) {
    return left.score - right.score;
  }
  if (left.segmentCount !== right.segmentCount) {
    return left.segmentCount - right.segmentCount;
  }
  if (left.text.length !== right.text.length) {
    return right.text.length - left.text.length;
  }
  return left.text > right.text ? 1 : left.text < right.text ? -1 : 0;
}

function dedupeSpellings(source: string[], limit: number): string[] {
  let spellings: string[] = [];
  for (let index = 0; index < source.length && spellings.length < limit; index++) {
    let spelling = normalizeSpelling(source[index]);
    if (spelling.length === 0 || spellings.indexOf(spelling) >= 0) {
      continue;
    }
    spellings.push(spelling);
  }
  return spellings;
}

function matchesAt(source: string, expected: string, position: number): boolean {
  return source.substring(position, position + expected.length) === expected;
}

function isCompatibleSpelling(digitSequence: string, spelling: string): boolean {
  return digitSequence.length > 0 && spellingToDigits(spelling) === digitSequence;
}

function normalizeSpelling(source: string): string {
  return source.toLowerCase().replace(/[^a-z]/g, '');
}

function spellingToDigits(spelling: string): string {
  let digits = '';
  for (let index = 0; index < spelling.length; index++) {
    let digit = charToDigit(spelling[index]);
    if (digit.length === 0) {
      continue;
    }
    digits += digit;
  }
  return digits;
}

function isNineKeyDigit(value: string): boolean {
  return /^[2-9]$/.test(value);
}

/**
 * ITU-T E.161 / fcitx5 T9 digit → letter layout. Useful when the UI wants
 * to render the "abc / def / ghi" hint above each numeric key, and for
 * reverse lookups in tests.
 */
export function getLettersForDigit(digit: string): string {
  switch (digit) {
    case '2': return 'abc';
    case '3': return 'def';
    case '4': return 'ghi';
    case '5': return 'jkl';
    case '6': return 'mno';
    case '7': return 'pqrs';
    case '8': return 'tuv';
    case '9': return 'wxyz';
    default: return '';
  }
}

export function isNineKeyDigitChar(value: string): boolean {
  return isNineKeyDigit(value);
}

export function spellingToNineKeyDigits(value: string): string {
  return spellingToDigits(normalizeSpelling(value));
}

function charToDigit(value: string): string {
  switch (value) {
    case 'a':
    case 'b':
    case 'c':
      return '2';
    case 'd':
    case 'e':
    case 'f':
      return '3';
    case 'g':
    case 'h':
    case 'i':
      return '4';
    case 'j':
    case 'k':
    case 'l':
      return '5';
    case 'm':
    case 'n':
    case 'o':
      return '6';
    case 'p':
    case 'q':
    case 'r':
    case 's':
      return '7';
    case 't':
    case 'u':
    case 'v':
      return '8';
    case 'w':
    case 'x':
    case 'y':
    case 'z':
      return '9';
    default:
      return '';
  }
}