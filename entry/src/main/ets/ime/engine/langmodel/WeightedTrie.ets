/*
 * ArkTS analogue of libime::WeightedTrie / DATrie<int32_t>
 * (others/libime/src/libime/core/historybigram.cpp:47 and
 *  others/libime/src/libime/core/datrie.{h,cpp}).
 *
 * The real libime implementation is a cedar-based double-array trie that
 * stores int32 frequency values keyed by plain byte strings. We cannot
 * ship cedar in pure ArkTS without sizeable work, but the *API surface*
 * and *key layout* used by HistoryBigram are what matter for algorithmic
 * equivalence, so this module mirrors them faithfully over a plain Map.
 *
 * Bigram keys follow libime's exact format: "<prev>|<cur>" — see
 * historybigram.cpp:314-322 for the C++ side.
 */

export type TrieUpdater = (current: number) => number;
export type TrieForEachCallback = (key: string, value: number) => boolean;

export class WeightedTrie {
  private readonly entries: Map<string, number> = new Map<string, number>();
  private total: number = 0;

  size(): number {
    return this.entries.size;
  }

  /** Sum of all stored values (matches DATrie::freq total semantics). */
  totalWeight(): number {
    return this.total;
  }

  clear(): void {
    this.entries.clear();
    this.total = 0;
  }

  freq(key: string): number {
    let value = this.entries.get(key);
    return value === undefined ? 0 : value;
  }

  hasExactMatch(key: string): boolean {
    return this.entries.has(key);
  }

  set(key: string, value: number): void {
    let current = this.entries.get(key);
    let previous = current === undefined ? 0 : current;
    if (value <= 0) {
      if (current !== undefined) {
        this.entries.delete(key);
        this.total -= previous;
      }
      return;
    }
    this.entries.set(key, value);
    this.total += (value - previous);
  }

  update(key: string, updater: TrieUpdater): void {
    let current = this.entries.get(key);
    let previous = current === undefined ? 0 : current;
    let next = updater(previous);
    if (next <= 0) {
      if (current !== undefined) {
        this.entries.delete(key);
        this.total -= previous;
      }
      return;
    }
    this.entries.set(key, next);
    this.total += (next - previous);
  }

  incFreq(key: string, delta: number): void {
    this.update(key, (previous: number): number => previous + delta);
  }

  erase(key: string): boolean {
    let current = this.entries.get(key);
    if (current === undefined) {
      return false;
    }
    this.entries.delete(key);
    this.total -= current;
    return true;
  }

  /**
   * Iterate over keys that start with the given prefix. The callback
   * receives the remaining suffix (the bytes after the prefix) together
   * with the stored value — matching the cedar `foreach(prefix, cb)`
   * contract used by libime's Prediction::predictWithScore.
   */
  foreachPrefix(prefix: string, callback: TrieForEachCallback): void {
    let iterator = this.entries.keys();
    let step = iterator.next();
    while (!step.done) {
      let key = step.value;
      if (key.length > prefix.length && key.startsWith(prefix)) {
        let value = this.entries.get(key);
        if (value !== undefined) {
          let keep = callback(key.substring(prefix.length), value);
          if (!keep) {
            return;
          }
        }
      }
      step = iterator.next();
    }
  }

  forEachEntry(callback: TrieForEachCallback): void {
    this.entries.forEach((value: number, key: string): void => {
      callback(key, value);
    });
  }
}
