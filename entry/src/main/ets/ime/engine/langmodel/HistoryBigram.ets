/*
 * ArkTS port of libime::HistoryBigram (others/libime/src/libime/core/
 * historybigram.{h,cpp}).
 *
 * Key ideas mirrored from the C++ source:
 *  - Counts are kept in three "pools" of increasing size — recent history
 *    lives in pool 0, gets promoted to pool 1 when pool 0 overflows, and
 *    eventually lands in pool 2 before being forgotten. Each pool has
 *    its own unigram + bigram WeightedTrie so we can weigh recent input
 *    much higher than old input (historybigram.cpp:143-220).
 *  - Sentence bookkeeping wraps every committed sequence in <s>/</s>
 *    markers (historybigram.cpp:239-241) so bigram context works at
 *    sentence boundaries.
 *  - Bigram keys use the libime "prev|cur" format so the prefix scan in
 *    fillPredict matches libime's cedar `foreach("prev|", cb)` semantics.
 *  - score(prev, cur) reproduces the exact weighted-backoff formula from
 *    historybigram.cpp:466-493, including the poolWeight/2 smoothing and
 *    the log10(unknown) floor.
 *  - The model is paired with a tiny LanguageModelState (analogue of
 *    libime::UserLanguageModel::State) so that predictors can call
 *    scoreWithState(state, word, out) and have `out.prevWord` correctly
 *    advance for chained predictions.
 */

import { WeightedTrie } from './WeightedTrie';

const SENTENCE_START = '<s>';
const SENTENCE_END = '</s>';
const UNKNOWN_TOKEN = '<unk>';

/** libime constants.h:15 and historybigram.cpp defaults. */
const DEFAULT_UNKNOWN_PROBABILITY = 1.0 / 60000000.0;
/** Fixed bigram/unigram split used by libime when useOnlyUnigram==false. */
const BIGRAM_WEIGHT = 0.8;
/** MIN_LOG_SCORE mirrors libime::MinLogScore used by the KenLM bridge. */
const MIN_LOG_SCORE = -20;

/**
 * Pool sizes — libime ships [128, 8192, 65536] for desktop. We keep the
 * same ratios but shrink to mobile-friendly numbers so that a device
 * without sqlite-grade storage can still round-trip the history.
 */
const POOL_SIZES: number[] = [128, 1024, 4096];
/**
 * Pool weights — libime derives these from p = 1/(1+alpha); with the
 * default alpha=1 that yields p=0.5 and a geometric decay per pool.
 * We materialise integer weights that preserve the 2^k ratio so that
 * scoring arithmetic stays exact in f64.
 */
const POOL_WEIGHTS: number[] = [64, 4, 1];
const POOL_COUNT = 3;

export interface HistorySentence {
  pool: number;
  words: string[];
}

export interface HistoryBigramSnapshot {
  version: number;
  poolSizes: number[];
  sentences: HistorySentence[];
}

export interface LanguageModelState {
  prevWord: string;
  hasContext: boolean;
}

interface HistoryPool {
  unigram: WeightedTrie;
  bigram: WeightedTrie;
  sentences: string[][];
  unigramTotal: number;
}

export function createLanguageModelState(prev?: string): LanguageModelState {
  let word = (prev === undefined || prev === null) ? '' : prev;
  return {
    prevWord: word.length > 0 ? word : SENTENCE_START,
    hasContext: word.length > 0
  };
}

export class HistoryBigram {
  private readonly pools: HistoryPool[] = [];
  private useOnlyUnigram: boolean = false;
  private dirty: boolean = false;
  /** log10(1/60,000,000) per libime constants.h. */
  private readonly unknownLogScore: number = Math.log(DEFAULT_UNKNOWN_PROBABILITY) / Math.LN10;

  constructor(_legacyCapacity: number = 512) {
    for (let index = 0; index < POOL_COUNT; index++) {
      this.pools.push({
        unigram: new WeightedTrie(),
        bigram: new WeightedTrie(),
        sentences: [],
        unigramTotal: 0
      });
    }
  }

  /** Total soft capacity across all pools (for legacy callers). */
  capacity(): number {
    let total = 0;
    for (let index = 0; index < POOL_SIZES.length; index++) {
      total += POOL_SIZES[index];
    }
    return total;
  }

  size(): number {
    let total = 0;
    for (let index = 0; index < this.pools.length; index++) {
      total += this.pools[index].sentences.length;
    }
    return total;
  }

  isDirty(): boolean {
    return this.dirty;
  }

  clearDirty(): void {
    this.dirty = false;
  }

  setUseOnlyUnigram(value: boolean): void {
    this.useOnlyUnigram = value;
  }

  clear(): void {
    for (let index = 0; index < this.pools.length; index++) {
      let pool = this.pools[index];
      pool.unigram.clear();
      pool.bigram.clear();
      pool.sentences.length = 0;
      pool.unigramTotal = 0;
    }
    this.dirty = true;
  }

  snapshot(): HistoryBigramSnapshot {
    let sentences: HistorySentence[] = [];
    for (let poolIndex = 0; poolIndex < this.pools.length; poolIndex++) {
      let pool = this.pools[poolIndex];
      for (let sentenceIndex = 0; sentenceIndex < pool.sentences.length; sentenceIndex++) {
        sentences.push({
          pool: poolIndex,
          words: pool.sentences[sentenceIndex].slice()
        });
      }
    }
    return {
      version: 2,
      poolSizes: POOL_SIZES.slice(),
      sentences: sentences
    };
  }

  restore(snapshot: HistoryBigramSnapshot): void {
    this.clear();
    if (!snapshot || !Array.isArray(snapshot.sentences)) {
      this.dirty = false;
      return;
    }
    for (let index = 0; index < snapshot.sentences.length; index++) {
      let entry = snapshot.sentences[index];
      if (!entry || !Array.isArray(entry.words) || entry.words.length === 0) {
        continue;
      }
      let targetPool = entry.pool;
      if (!Number.isFinite(targetPool) || targetPool < 0 || targetPool >= POOL_COUNT) {
        targetPool = 0;
      }
      this.insertIntoPool(targetPool, entry.words, false);
    }
    this.dirty = false;
  }

  add(sentence: string[]): void {
    this.insertIntoPool(0, sentence, true);
    this.rebalancePools();
  }

  private insertIntoPool(poolIndex: number, sentence: string[], markDirty: boolean): void {
    let sanitized = sanitizeSentence(sentence);
    if (sanitized.length === 0) {
      return;
    }
    let pool = this.pools[poolIndex];
    pool.sentences.push(sanitized);
    this.applyCounts(pool, sanitized, 1);
    if (markDirty) {
      this.dirty = true;
    }
  }

  /**
   * Implements libime's pool overflow: when pool[i] exceeds its configured
   * size the oldest sentence is popped and pushed into pool[i+1]; pool 2
   * simply forgets its oldest sentence.
   */
  private rebalancePools(): void {
    for (let index = 0; index < this.pools.length; index++) {
      let limit = POOL_SIZES[index];
      while (this.pools[index].sentences.length > limit) {
        let pool = this.pools[index];
        let oldest = pool.sentences.shift();
        if (!oldest) {
          break;
        }
        this.applyCounts(pool, oldest, -1);
        if (index + 1 < this.pools.length) {
          let nextPool = this.pools[index + 1];
          nextPool.sentences.push(oldest);
          this.applyCounts(nextPool, oldest, 1);
        }
      }
    }
  }

  /**
   * Remove every sentence that contains `word` from all pools, mirroring
   * libime::HistoryBigram::forget.
   */
  forget(word: string): void {
    if (word.length === 0) {
      return;
    }
    for (let poolIndex = 0; poolIndex < this.pools.length; poolIndex++) {
      let pool = this.pools[poolIndex];
      let keep: string[][] = [];
      for (let sentenceIndex = 0; sentenceIndex < pool.sentences.length; sentenceIndex++) {
        let sentence = pool.sentences[sentenceIndex];
        if (sentence.indexOf(word) >= 0) {
          this.applyCounts(pool, sentence, -1);
        } else {
          keep.push(sentence);
        }
      }
      pool.sentences.length = 0;
      for (let keepIndex = 0; keepIndex < keep.length; keepIndex++) {
        pool.sentences.push(keep[keepIndex]);
      }
    }
    this.dirty = true;
  }

  isUnknown(word: string): boolean {
    return this.unigramFreq(word) === 0;
  }

  /** Weighted unigram sum across all pools, matching libime. */
  unigramFreq(word: string): number {
    let sum = 0;
    for (let index = 0; index < this.pools.length; index++) {
      sum += this.pools[index].unigram.freq(word) * POOL_WEIGHTS[index];
    }
    return sum;
  }

  unigramSize(): number {
    let sum = 0;
    for (let index = 0; index < this.pools.length; index++) {
      sum += this.pools[index].unigramTotal * POOL_WEIGHTS[index];
    }
    return sum;
  }

  bigramFreq(prev: string, cur: string): number {
    let key = bigramKey(prev, cur);
    let sum = 0;
    for (let index = 0; index < this.pools.length; index++) {
      sum += this.pools[index].bigram.freq(key) * POOL_WEIGHTS[index];
    }
    return sum;
  }

  /**
   * log10 P(cur|prev) — exact port of libime::HistoryBigram::score.
   */
  score(prev: string, cur: string): number {
    let resolvedPrev = prev.length > 0 ? prev : SENTENCE_START;
    let resolvedCur = cur.length > 0 ? cur : UNKNOWN_TOKEN;

    let uf0 = this.unigramFreq(resolvedPrev);
    let bf = this.bigramFreq(resolvedPrev, resolvedCur);
    let uf1 = this.unigramFreq(resolvedCur);

    let smoothing = POOL_WEIGHTS[0] / 2;
    let bigramWeight = this.useOnlyUnigram ? 0.0 : BIGRAM_WEIGHT;
    let pr = 0.0;
    pr += bigramWeight * bf / (uf0 + smoothing);
    pr += (1.0 - bigramWeight) * uf1 / (this.unigramSize() + smoothing);
    if (pr > 1.0) {
      pr = 1.0;
    }
    if (pr <= 0) {
      return this.unknownLogScore;
    }
    let value = Math.log(pr) / Math.LN10;
    return value < MIN_LOG_SCORE ? MIN_LOG_SCORE : value;
  }

  /**
   * State-aware scoring mirrors libime::UserLanguageModel::score: update
   * `out` with the word just scored so chained predictors can keep
   * walking the bigram trie without manually tracking context.
   */
  scoreWithState(state: LanguageModelState, word: string, out: LanguageModelState): number {
    let prev = state.hasContext ? state.prevWord : SENTENCE_START;
    let result = this.score(prev, word);
    out.prevWord = word;
    out.hasContext = true;
    return result;
  }

  /**
   * Fill `sink` with follow-up words for the bigram context implied by
   * `sentence` (last word wins, matching libime::Prediction semantics at
   * prediction.cpp:68-133). When no bigram hit exists the top unigram
   * words from the most recent pool are used as a fallback so brand-new
   * installs still offer something to associate with.
   */
  fillPredict(sentence: string[], sink: Set<string>, maxSize: number): void {
    let limit = maxSize > 0 ? maxSize : Number.MAX_SAFE_INTEGER;
    let prev = sentence.length > 0 ? sentence[sentence.length - 1] : '';
    if (prev.length > 0) {
      let prefix = `${prev}|`;
      for (let poolIndex = 0; poolIndex < this.pools.length; poolIndex++) {
        this.pools[poolIndex].bigram.foreachPrefix(prefix,
          (suffix: string, _value: number): boolean => {
            if (suffix.length > 0 && suffix !== SENTENCE_END) {
              sink.add(suffix);
            }
            return sink.size < limit;
          });
        if (sink.size >= limit) {
          return;
        }
      }
    }
    if (sink.size >= limit) {
      return;
    }
    // Unigram fallback — pick the top entries from the freshest pool.
    let collected: Array<UnigramSample> = [];
    this.pools[0].unigram.forEachEntry((key: string, value: number): boolean => {
      if (key !== SENTENCE_START && key !== SENTENCE_END && key !== UNKNOWN_TOKEN) {
        collected.push({ word: key, freq: value });
      }
      return true;
    });
    collected.sort((left: UnigramSample, right: UnigramSample): number => right.freq - left.freq);
    for (let index = 0; index < collected.length && sink.size < limit; index++) {
      sink.add(collected[index].word);
    }
  }

  private applyCounts(pool: HistoryPool, sentence: string[], delta: number): void {
    // Sentence boundary counts — matches historybigram.cpp:239-241.
    bumpUnigram(pool, SENTENCE_START, delta);
    bumpUnigram(pool, SENTENCE_END, delta);
    pool.bigram.incFreq(bigramKey(SENTENCE_START, sentence[0]), delta);
    pool.bigram.incFreq(bigramKey(sentence[sentence.length - 1], SENTENCE_END), delta);
    for (let index = 0; index < sentence.length; index++) {
      bumpUnigram(pool, sentence[index], delta);
      if (index + 1 < sentence.length) {
        pool.bigram.incFreq(bigramKey(sentence[index], sentence[index + 1]), delta);
      }
    }
  }
}

interface UnigramSample {
  word: string;
  freq: number;
}

function bumpUnigram(pool: HistoryPool, key: string, delta: number): void {
  pool.unigram.incFreq(key, delta);
  pool.unigramTotal += delta;
  if (pool.unigramTotal < 0) {
    pool.unigramTotal = 0;
  }
}

function sanitizeSentence(sentence: string[]): string[] {
  if (!sentence) {
    return [];
  }
  let result: string[] = [];
  for (let index = 0; index < sentence.length; index++) {
    let word = sentence[index];
    if (typeof word !== 'string' || word.length === 0) {
      continue;
    }
    if (word.indexOf('\0') >= 0 || word.indexOf('|') >= 0) {
      // "|" would collide with libime's bigram separator — drop the sentence.
      return [];
    }
    result.push(word);
  }
  return result;
}

function bigramKey(prev: string, cur: string): string {
  return `${prev}|${cur}`;
}
