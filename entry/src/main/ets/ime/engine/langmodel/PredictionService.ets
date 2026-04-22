/*
 * ArkTS port of libime::Prediction (others/libime/src/libime/core/
 * prediction.{h,cpp}).
 *
 * Pipeline mirrors libime::Prediction::predictWithScore:
 *   1. Pool candidates from the history bigram (and, in the C++ source,
 *      from a static LM prediction trie — we don't ship one, so only the
 *      history branch fires here).
 *   2. Score each candidate through the state-aware HistoryBigram score,
 *      which already applies the bigram/unigram interpolation from
 *      historybigram.cpp:466-493.
 *   3. Sort by score descending, break ties lexicographically (matching
 *      the C++ comparator at prediction.cpp:111-117).
 *   4. Truncate to `realMaxSize`.
 *
 * The `maxSize * 2` search widening at prediction.cpp:79 is preserved so
 * rare-but-plausible follow-ups aren't starved by noise near the top of
 * the bigram prefix iteration.
 */

import { HistoryBigram, LanguageModelState, createLanguageModelState } from './HistoryBigram';

interface ScoredCandidate {
  word: string;
  score: number;
}

export interface PredictionResult {
  word: string;
  score: number;
}

export class PredictionService {
  private readonly bigram: HistoryBigram;

  constructor(bigram: HistoryBigram) {
    this.bigram = bigram;
  }

  predict(sentence: string[], maxSize: number): string[] {
    let scored = this.predictWithScore(sentence, maxSize);
    let words: string[] = [];
    for (let index = 0; index < scored.length; index++) {
      words.push(scored[index].word);
    }
    return words;
  }

  predictWithScore(sentence: string[], realMaxSize: number): PredictionResult[] {
    if (realMaxSize <= 0) {
      return [];
    }
    let searchSize = realMaxSize * 2;
    let pool = new Set<string>();
    this.bigram.fillPredict(sentence, pool, searchSize);
    if (pool.size === 0) {
      return [];
    }
    let state = createLanguageModelState(
      sentence.length > 0 ? sentence[sentence.length - 1] : '');
    let scratch: LanguageModelState = createLanguageModelState('');
    let scored: ScoredCandidate[] = [];
    pool.forEach((word: string): void => {
      let score = this.bigram.scoreWithState(state, word, scratch);
      scored.push({ word: word, score: score });
    });
    scored.sort((left: ScoredCandidate, right: ScoredCandidate): number => {
      if (left.score !== right.score) {
        return right.score - left.score;
      }
      return left.word < right.word ? -1 : (left.word > right.word ? 1 : 0);
    });
    let output: PredictionResult[] = [];
    for (let index = 0; index < scored.length && output.length < realMaxSize; index++) {
      output.push({ word: scored[index].word, score: scored[index].score });
    }
    return output;
  }
}
