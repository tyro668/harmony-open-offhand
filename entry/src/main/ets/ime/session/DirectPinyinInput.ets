export function appendDirectPinyinRawInput(rawInput: string, letter: string, maxCompositionLength: number): string | undefined {
  let nextInput = `${rawInput}${letter.toLowerCase()}`;
  if (maxCompositionLength > 0 && nextInput.length > maxCompositionLength) {
    return undefined;
  }
  return nextInput;
}

export function backspaceDirectPinyinRawInput(rawInput: string): string {
  if (rawInput.length === 0) {
    return '';
  }
  return rawInput.substring(0, rawInput.length - 1);
}

export function formatDirectPinyinRawInput(rawInput: string): string {
  let parts = normalizeDirectPinyinRawInputParts(rawInput);
  if (parts.length === 0) {
    return '';
  }
  let segments: string[] = [];
  for (let index = 0; index < parts.length; index++) {
    segments = segments.concat(segmentDirectPinyinRawInput(parts[index]));
  }
  return segments.join('\'');
}

interface PinyinSegmentation {
  segments: string[];
  partialCount: number;
  rankScore: number;
}

const MAX_PINYIN_SEGMENT_RESULTS: number = 8;
const PARTIAL_PINYIN_RANK: number = 100000;
const PINYIN_SYLLABLE_RANKS: Record<string, number> = buildPinyinSyllableRanks((
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
).split(' '));
const PINYIN_SYLLABLES: string[] = Object.keys(PINYIN_SYLLABLE_RANKS);

function normalizeDirectPinyinRawInputParts(rawInput: string): string[] {
  let parts: string[] = [];
  let normalized = '';
  for (let index = 0; index < rawInput.length; index++) {
    let code = rawInput.charCodeAt(index);
    if (code >= 65 && code <= 90) {
      normalized += String.fromCharCode(code + 32);
    } else if (code >= 97 && code <= 122) {
      normalized += rawInput[index];
    } else if (normalized.length > 0) {
      parts.push(normalized);
      normalized = '';
    }
  }
  if (normalized.length > 0) {
    parts.push(normalized);
  }
  return parts;
}

function segmentDirectPinyinRawInput(rawInput: string): string[] {
  let cache: Array<PinyinSegmentation[] | undefined> = [];
  let results = segmentPinyinFrom(rawInput, 0, cache);
  return results.length > 0 ? results[0].segments : [rawInput];
}

function segmentPinyinFrom(
  rawInput: string,
  offset: number,
  cache: Array<PinyinSegmentation[] | undefined>
): PinyinSegmentation[] {
  if (offset >= rawInput.length) {
    return [{ segments: [], partialCount: 0, rankScore: 0 }];
  }
  if (cache[offset] !== undefined) {
    return cache[offset] as PinyinSegmentation[];
  }

  let results: PinyinSegmentation[] = [];
  for (let end = offset + 1; end <= rawInput.length; end++) {
    let syllable = rawInput.substring(offset, end);
    if (!isKnownPinyinSyllable(syllable)) {
      continue;
    }
    let tails = segmentPinyinFrom(rawInput, end, cache);
    for (let index = 0; index < tails.length; index++) {
      let tail = tails[index];
      results.push({
        segments: [syllable].concat(tail.segments),
        partialCount: tail.partialCount,
        rankScore: resolvePinyinSyllableRank(syllable) + tail.rankScore
      });
    }
  }

  let remaining = rawInput.substring(offset);
  if (results.length === 0 || isPotentialPinyinPrefix(remaining)) {
    results.push({
      segments: [remaining],
      partialCount: 1,
      rankScore: PARTIAL_PINYIN_RANK
    });
  }

  results.sort(comparePinyinSegmentation);
  if (results.length > MAX_PINYIN_SEGMENT_RESULTS) {
    results = results.slice(0, MAX_PINYIN_SEGMENT_RESULTS);
  }
  cache[offset] = results;
  return results;
}

function comparePinyinSegmentation(left: PinyinSegmentation, right: PinyinSegmentation): number {
  if (left.partialCount !== right.partialCount) {
    return left.partialCount - right.partialCount;
  }
  if (left.segments.length !== right.segments.length) {
    return left.segments.length - right.segments.length;
  }
  let sharedLength = Math.min(left.segments.length, right.segments.length);
  for (let index = 0; index < sharedLength; index++) {
    if (left.segments[index].length !== right.segments[index].length) {
      return right.segments[index].length - left.segments[index].length;
    }
  }
  if (left.rankScore !== right.rankScore) {
    return left.rankScore - right.rankScore;
  }
  let leftText = left.segments.join('\'');
  let rightText = right.segments.join('\'');
  if (leftText < rightText) {
    return -1;
  }
  if (leftText > rightText) {
    return 1;
  }
  return 0;
}

function isKnownPinyinSyllable(value: string): boolean {
  return PINYIN_SYLLABLE_RANKS[value] !== undefined && value !== 'xx';
}

function resolvePinyinSyllableRank(value: string): number {
  let rank = PINYIN_SYLLABLE_RANKS[value];
  return rank === undefined ? PARTIAL_PINYIN_RANK : rank;
}

function isPotentialPinyinPrefix(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  for (let index = 0; index < PINYIN_SYLLABLES.length; index++) {
    let syllable = PINYIN_SYLLABLES[index];
    if (syllable !== 'xx' && syllable.startsWith(value)) {
      return true;
    }
  }
  return false;
}

function buildPinyinSyllableRanks(source: string[]): Record<string, number> {
  let ranks: Record<string, number> = {};
  for (let index = 0; index < source.length; index++) {
    let syllable = source[index];
    if (syllable.length > 0 && ranks[syllable] === undefined) {
      ranks[syllable] = index + 1;
    }
  }
  return ranks;
}
