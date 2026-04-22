/*
 * Persistence for HistoryBigram snapshots.
 *
 * File format evolution:
 *   v1 (legacy):
 *     offhand-lm\t1\t<maxSize>
 *     <word>\t<word>\t...
 *   v2 (current): explicitly tags each sentence with its source pool so
 *   libime-style 3-pool accounting survives a round-trip
 *     offhand-lm\t2\t<pool0>,<pool1>,<pool2>
 *     <poolIndex>\t<word>\t<word>\t...
 *
 * v1 files are accepted by collapsing every sentence into pool 0, which
 * matches libime's promotion order (oldest stays, newest gets weighed).
 */

import fileIo from '@ohos.file.fs';
import { HistoryBigram, HistoryBigramSnapshot, HistorySentence } from './HistoryBigram';

const MAGIC = 'offhand-lm';
const FORMAT_VERSION = 2;

export class LanguageModelStore {
  private readonly filePath: string;

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  load(target: HistoryBigram): void {
    let text: string;
    try {
      if (!fileIo.accessSync(this.filePath)) {
        return;
      }
      let raw = fileIo.readTextSync(this.filePath);
      text = raw ?? '';
    } catch (_) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    let lines = text.split('\n');
    if (lines.length === 0) {
      return;
    }
    let header = lines[0].split('\t');
    if (header.length < 2 || header[0] !== MAGIC) {
      return;
    }
    let version = parseInt(header[1], 10);
    if (!Number.isFinite(version)) {
      return;
    }
    let sentences = version >= 2
      ? parseV2Sentences(lines)
      : parseV1Sentences(lines);
    if (sentences.length === 0) {
      return;
    }
    let snapshot: HistoryBigramSnapshot = {
      version: FORMAT_VERSION,
      poolSizes: [],
      sentences: sentences
    };
    target.restore(snapshot);
  }

  saveIfDirty(source: HistoryBigram): boolean {
    if (!source.isDirty()) {
      return false;
    }
    return this.save(source);
  }

  save(source: HistoryBigram): boolean {
    let snapshot = source.snapshot();
    let lines: string[] = [];
    let sizes = snapshot.poolSizes.length > 0 ? snapshot.poolSizes.join(',') : '';
    lines.push(`${MAGIC}\t${FORMAT_VERSION}\t${sizes}`);
    for (let index = 0; index < snapshot.sentences.length; index++) {
      let sentence = snapshot.sentences[index];
      let parts: string[] = [];
      parts.push(`${sentence.pool}`);
      for (let wordIndex = 0; wordIndex < sentence.words.length; wordIndex++) {
        parts.push(sentence.words[wordIndex]);
      }
      lines.push(parts.join('\t'));
    }
    let payload = `${lines.join('\n')}\n`;
    try {
      let file = fileIo.openSync(this.filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, payload);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_) {
      return false;
    }
    source.clearDirty();
    return true;
  }
}

function parseV1Sentences(lines: string[]): HistorySentence[] {
  let sentences: HistorySentence[] = [];
  for (let index = 1; index < lines.length; index++) {
    let line = lines[index];
    if (line.length === 0) {
      continue;
    }
    let tokens = line.split('\t').filter((token: string): boolean => token.length > 0);
    if (tokens.length === 0) {
      continue;
    }
    sentences.push({ pool: 0, words: tokens });
  }
  return sentences;
}

function parseV2Sentences(lines: string[]): HistorySentence[] {
  let sentences: HistorySentence[] = [];
  for (let index = 1; index < lines.length; index++) {
    let line = lines[index];
    if (line.length === 0) {
      continue;
    }
    let tokens = line.split('\t');
    if (tokens.length < 2) {
      continue;
    }
    let poolIndex = parseInt(tokens[0], 10);
    if (!Number.isFinite(poolIndex) || poolIndex < 0) {
      poolIndex = 0;
    }
    let words: string[] = [];
    for (let wordIndex = 1; wordIndex < tokens.length; wordIndex++) {
      if (tokens[wordIndex].length > 0) {
        words.push(tokens[wordIndex]);
      }
    }
    if (words.length === 0) {
      continue;
    }
    sentences.push({ pool: poolIndex, words: words });
  }
  return sentences;
}
