import { CandidateItem, KeyboardLayoutId, KeyboardLayoutOption, SubtypeSummary } from '../common/ImeTypes';
import { imeRuntime } from '../runtime/ImeRuntime';
import { KeyboardUiState, keyboardStateStore } from '../session/KeyboardStateStore';

const LETTER_ROW_TOP: string[] = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
const LETTER_ROW_MIDDLE: string[] = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
const LETTER_ROW_BOTTOM: string[] = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
const SIDE_PUNCTUATIONS: string[] = ['，', '。', '？', '！'];
const COMMON_SYMBOLS: string[] = ['，', '。', '？', '！', '@', '#', '/', '-', '_', ':', ';', '(', ')'];

interface NineGridKeyDescriptor {
  digit: string;
  label: string;
  action: 'digit' | 'text';
  value: string;
}

const NINE_GRID_ROWS: NineGridKeyDescriptor[][] = [
  [
    { digit: '1', label: '分词', action: 'text', value: '\'' },
    { digit: '2', label: 'ABC', action: 'digit', value: '2' },
    { digit: '3', label: 'DEF', action: 'digit', value: '3' }
  ],
  [
    { digit: '4', label: 'GHI', action: 'digit', value: '4' },
    { digit: '5', label: 'JKL', action: 'digit', value: '5' },
    { digit: '6', label: 'MNO', action: 'digit', value: '6' }
  ],
  [
    { digit: '7', label: 'PQRS', action: 'digit', value: '7' },
    { digit: '8', label: 'TUV', action: 'digit', value: '8' },
    { digit: '9', label: 'WXYZ', action: 'digit', value: '9' }
  ]
];

@Entry
@Component
struct KeyboardPanel {
  @State private uiState: KeyboardUiState = keyboardStateStore.getSnapshot();
  @State private showSettingsTray: boolean = false;
  @State private showSymbolPalette: boolean = false;
  private unsubscribe?: () => void;

  aboutToAppear(): void {
    this.unsubscribe = keyboardStateStore.subscribe((state: KeyboardUiState): void => {
      this.uiState = state;
      if (!state.sessionActive) {
        this.showSettingsTray = false;
        this.showSymbolPalette = false;
      }
    });
  }

  aboutToDisappear(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        this.renderTopToolbar();
        this.renderSettingsTray();
        this.renderCandidateOrSymbolStrip();
        this.renderVoiceDraftCard();
        this.renderPolishSuggestionStrip();
        if (this.uiState.keyboardLayout === 'voice_panel') {
          this.renderVoicePanel();
        } else if (this.uiState.keyboardLayout === 't9_9') {
          this.renderReferenceNineKeyKeyboard();
        } else {
          this.renderReferenceQwertyKeyboard();
        }
      }
      .width('100%')
      .padding({ top: 12, right: 12, bottom: 16, left: 12 })
    }
    .width('100%')
    .height('100%')
    .scrollable(ScrollDirection.Vertical)
    .backgroundColor('#E6E6E8')
  }

  @Builder
  private renderTopToolbar() {
    Row() {
      // 左侧：设置入口（单一图标聚合所有开关）
      this.renderTopIconButton('⌨', this.showSettingsTray, (): void => {
        this.showSettingsTray = !this.showSettingsTray;
      })

      // 中部：弹性占位，让右侧功能图标靠右分布
      Blank()
        .layoutWeight(1)

      // 语音
      this.renderTopIconButton(this.uiState.voiceState === 'recording' ? '●' : '🎤',
        this.uiState.voiceState === 'recording', (): void => {
          this.startOrStopVoice();
        }, this.uiState.voiceEnabled)

      // 润色
      this.renderTopIconButton('✦', this.uiState.polishEnabled && this.uiState.canPolish, (): void => {
        if (this.uiState.polishEnabled && this.uiState.canPolish && !this.uiState.isPolishRunning) {
          void imeRuntime.getSessionManager()?.polishPendingText();
        }
      }, this.uiState.polishEnabled)

      // 符号面板
      this.renderTopIconButton('☺', this.showSymbolPalette, (): void => {
        this.showSymbolPalette = !this.showSymbolPalette;
      })

      // 分隔线
      Column()
        .width(1)
        .height(20)
        .backgroundColor('#D4D4D8')
        .margin({ left: 6, right: 6 })

      // 收起键盘
      this.renderTopIconButton('∨', false, (): void => {
        void imeRuntime.getSessionManager()?.handleKeyboardHide();
      })
    }
    .width('100%')
    .height(44)
    .padding({ left: 6, right: 6 })
  }

  @Builder
  private renderSettingsTray() {
    if (this.showSettingsTray) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.uiState.currentSubtypeName.length > 0 ? this.uiState.currentSubtypeName : 'Offhand IME')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202020')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)

          Text(this.resolveLayoutDisplayLabel(this.uiState.keyboardLayout))
            .fontSize(11)
            .fontColor('#585858')
            .padding({ top: 5, right: 9, bottom: 5, left: 9 })
            .backgroundColor('#F1F1F4')
            .borderRadius(999)
        }
        .width('100%')

        this.renderStatusChipRow()

        if (this.uiState.availableKeyboardLayouts.length > 1) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.uiState.availableKeyboardLayouts, (layout: KeyboardLayoutOption) => {
                this.renderTrayPill(layout.label, layout.id === this.uiState.keyboardLayout, (): void => {
                  if (layout.id !== this.uiState.keyboardLayout) {
                    void imeRuntime.getSessionManager()?.switchKeyboardLayout(layout.id);
                  }
                })
              }, (layout: KeyboardLayoutOption): string => layout.id)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
        }

        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.uiState.availableSubtypes, (subtype: SubtypeSummary) => {
              this.renderTrayPill(subtype.name, subtype.id === this.uiState.currentSubtypeId, (): void => {
                if (subtype.id !== this.uiState.currentSubtypeId) {
                  void imeRuntime.getSessionManager()?.switchSubtype(subtype.id);
                }
              })
            }, (subtype: SubtypeSummary): string => subtype.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')

        Text(this.uiState.editorSummary)
          .fontSize(11)
          .fontColor('#727272')
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(2)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(22)
    }
  }

  @Builder
  private renderStatusChipRow() {
    Scroll() {
      Row({ space: 8 }) {
        this.renderStatusChip(`字段 ${this.uiState.securitySummary}`)
        this.renderStatusChip(`语音 ${this.uiState.voiceEnabled ? '开' : '关'}`)
        this.renderStatusChip(`润色 ${this.uiState.polishEnabled ? '开' : '关'}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
  }

  @Builder
  private renderStatusChip(label: string) {
    Text(label)
      .fontSize(10)
      .fontColor('#5F5F63')
      .padding({ top: 5, right: 8, bottom: 5, left: 8 })
      .backgroundColor('#F2F2F5')
      .borderRadius(999)
  }

  @Builder
  private renderTrayPill(label: string, selected: boolean, action: () => void) {
    Button(label)
      .type(ButtonType.Capsule)
      .fontSize(12)
      .fontColor(selected ? '#FFFFFF' : '#46484D')
      .backgroundColor(selected ? '#6D7366' : '#F1F1F4')
      .onClick(() => {
        action();
      })
  }

  @Builder
  private renderCandidateOrSymbolStrip() {
    if (this.showSymbolPalette) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(COMMON_SYMBOLS, (symbol: string) => {
            Button(symbol)
              .type(ButtonType.Capsule)
              .fontSize(16)
              .fontColor('#232323')
              .backgroundColor('#FFFFFF')
              .onClick(() => {
                this.commitText(symbol);
                this.showSymbolPalette = false;
              })
          }, (symbol: string): string => symbol)
        }
        .padding({ left: 4, right: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
      .padding(8)
      .backgroundColor('#F5F5F7')
      .borderRadius(20)
    } else if (this.uiState.candidates.length > 0 ||
      this.uiState.preedit.length > 0 ||
      this.uiState.activeNineKeySpelling.length > 0 ||
      this.uiState.nineKeySpellings.length > 0 ||
      this.uiState.sessionActive) {
      this.renderCandidateStripBody()
    }
  }

  @Builder
  private renderCandidateStripBody() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('‹')
          .width(34)
          .height(34)
          .fontSize(18)
          .fontColor(this.uiState.hasPreviousCandidatePage ? '#333333' : '#B9BAC0')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .opacity(this.uiState.hasPreviousCandidatePage ? 1 : 0.55)
          .onClick(() => {
            if (this.uiState.hasPreviousCandidatePage) {
              void imeRuntime.getSessionManager()?.pageCandidateBackward();
            }
          })

        Scroll() {
          Row({ space: 8 }) {
            if (this.uiState.candidates.length === 0) {
              Text(this.resolveCandidatePlaceholder())
                .fontSize(12)
                .fontColor('#7B7C83')
            } else {
              ForEach(this.uiState.candidates, (candidate: CandidateItem) => {
                Button(`${candidate.label}. ${candidate.text}`)
                  .type(ButtonType.Capsule)
                  .fontSize(13)
                  .fontColor(candidate.highlighted ? '#1D1D1F' : '#35363A')
                  .backgroundColor(candidate.highlighted ? '#DDE6D3' : '#FFFFFF')
                  .onClick(() => {
                    void imeRuntime.getSessionManager()?.selectCandidate(candidate.index);
                  })
              }, (candidate: CandidateItem): string => `${candidate.index}-${candidate.label}`)
            }
          }
          .padding({ left: 2, right: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .layoutWeight(1)
        .height(38)

        Button('›')
          .width(34)
          .height(34)
          .fontSize(18)
          .fontColor(this.uiState.hasNextCandidatePage ? '#333333' : '#B9BAC0')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .opacity(this.uiState.hasNextCandidatePage ? 1 : 0.55)
          .onClick(() => {
            if (this.uiState.hasNextCandidatePage) {
              void imeRuntime.getSessionManager()?.pageCandidateForward();
            }
          })
      }
      .width('100%')

      if (this.uiState.nineKeySpellings.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.uiState.nineKeySpellings, (spelling: string) => {
              Button(spelling)
                .type(ButtonType.Capsule)
                .fontSize(12)
                .fontColor(spelling === this.uiState.activeNineKeySpelling ? '#FFFFFF' : '#4C4D52')
                .backgroundColor(spelling === this.uiState.activeNineKeySpelling ? '#7E856F' : '#FFFFFF')
                .onClick(() => {
                  if (spelling !== this.uiState.activeNineKeySpelling) {
                    void imeRuntime.getSessionManager()?.selectNineKeySpelling(spelling);
                  }
                })
            }, (spelling: string): string => spelling)
          }
          .padding({ left: 2, right: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F5F5F7')
    .borderRadius(20)
  }

  @Builder
  private renderVoiceDraftCard() {
    if (this.uiState.voiceDraftText.length > 0) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('语音草稿')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#2E2E2E')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)

          Text('先确认，再插入')
            .fontSize(10)
            .fontColor('#75767C')
        }
        .width('100%')

        Text(this.uiState.voiceDraftText)
          .fontSize(14)
          .fontColor('#1C1C1E')
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(4)

        Row({ space: 8 }) {
          Button('插入')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor('#7A835E')
            .borderRadius(12)
            .onClick(() => {
              void imeRuntime.getSessionManager()?.insertVoiceDraft();
            })

          Button('清空')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#4C4D52')
            .backgroundColor('#ECECEF')
            .borderRadius(12)
            .onClick(() => {
              void imeRuntime.getSessionManager()?.clearVoiceDraft();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
    }
  }

  @Builder
  private renderPolishSuggestionStrip() {
    if (this.uiState.showPolishSuggestion || this.uiState.canRevertPolish) {
      Column({ space: 8 }) {
        if (this.uiState.showPolishSuggestion) {
          Text('润色建议')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#2E2E2E')
            .width('100%')
            .textAlign(TextAlign.Start)

          if (this.uiState.polishSourceText.length > 0) {
            Text(`原文：${this.uiState.polishSourceText}`)
              .fontSize(12)
              .fontColor('#73757B')
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
          }

          Text(`建议：${this.uiState.polishSuggestionText}`)
            .fontSize(12)
            .fontColor('#2E2E2E')
            .width('100%')
            .textAlign(TextAlign.Start)
            .maxLines(3)

          Row({ space: 8 }) {
            Button('应用')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor('#7A835E')
              .borderRadius(12)
              .onClick(() => {
                void imeRuntime.getSessionManager()?.acceptPolishSuggestion();
              })

            Button('保留原文')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor('#4C4D52')
              .backgroundColor('#ECECEF')
              .borderRadius(12)
              .onClick(() => {
                void imeRuntime.getSessionManager()?.dismissPolishSuggestion();
              })
          }
          .width('100%')
        } else {
          Row({ space: 8 }) {
            Text('已应用润色结果。')
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#4C4D52')
              .textAlign(TextAlign.Start)

            Button('撤销')
              .width(84)
              .height(36)
              .fontSize(13)
              .fontColor('#4C4D52')
              .backgroundColor('#ECECEF')
              .borderRadius(12)
              .onClick(() => {
                void imeRuntime.getSessionManager()?.revertLastPolish();
              })
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
    }
  }

  @Builder
  private renderReferenceNineKeyKeyboard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        this.renderPunctuationRail()

        Column({ space: 8 }) {
          ForEach(NINE_GRID_ROWS, (row: NineGridKeyDescriptor[]) => {
            Row({ space: 8 }) {
              ForEach(row, (descriptor: NineGridKeyDescriptor) => {
                this.renderNineGridKey(descriptor)
              }, (descriptor: NineGridKeyDescriptor): string => `${descriptor.digit}-${descriptor.label}`)
            }
            .width('100%')
          }, (row: NineGridKeyDescriptor[]): string => `row-${row[0].digit}`)
        }
        .layoutWeight(1)

        Column({ space: 8 }) {
          this.renderSideActionKey('⌫', (): void => {
            void imeRuntime.getSessionManager()?.pressBackspace();
          })

          this.renderSideActionKey('清空', (): void => {
            void imeRuntime.getSessionManager()?.clearActiveInput();
          })

          this.renderTallSideActionKey('换行', (): void => {
            void imeRuntime.getSessionManager()?.pressEnter();
          })
        }
        .width(98)
      }
      .width('100%')

      Row({ space: 8 }) {
        this.renderBottomActionKey('符号', this.showSymbolPalette, (): void => {
          this.showSymbolPalette = !this.showSymbolPalette;
        })

        this.renderBottomActionKey(this.resolveQuickSwitchLabel(), false, (): void => {
          this.switchQuickSubtype();
        })

        this.renderVoicePadKey()

        this.renderBottomActionKey(this.supportsTwentySixKey() ? '26键' : 'ABC', false, (): void => {
          if (this.supportsTwentySixKey()) {
            void imeRuntime.getSessionManager()?.switchKeyboardLayout('qwerty_26');
          }
        }, this.supportsTwentySixKey())
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#DCDCE0')
    .borderRadius(24)
  }

  @Builder
  private renderReferenceQwertyKeyboard() {
    Column({ space: 8 }) {
      this.renderQwertyRow(LETTER_ROW_TOP)
      this.renderQwertyRowIndented(LETTER_ROW_MIDDLE, 18)

      Row({ space: 6 }) {
        this.renderQwertyActionKey(this.supportsNineKey() ? '9键' : '，', (): void => {
          if (this.supportsNineKey()) {
            void imeRuntime.getSessionManager()?.switchKeyboardLayout('t9_9');
          } else {
            this.commitText('，');
          }
        })

        ForEach(LETTER_ROW_BOTTOM, (key: string) => {
          this.renderQwertyLetterKey(key)
        }, (key: string): string => key)

        this.renderQwertyActionKey('删除', (): void => {
          void imeRuntime.getSessionManager()?.pressBackspace();
        })
      }
      .width('100%')

      Row({ space: 6 }) {
        this.renderQwertyActionKey(this.resolveQuickSwitchLabel(), (): void => {
          this.switchQuickSubtype();
        })

        this.renderQwertyActionKey('符号', (): void => {
          this.showSymbolPalette = !this.showSymbolPalette;
        })

        Button('空格')
          .layoutWeight(3)
          .height(48)
          .fontSize(16)
          .fontColor('#1C1C1E')
          .backgroundColor('#FFFFFF')
          .borderRadius(18)
          .onClick(() => {
            this.commitText(' ');
          })

        this.renderQwertyActionKey('回车', (): void => {
          void imeRuntime.getSessionManager()?.pressEnter();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#DCDCE0')
    .borderRadius(24)
  }

  @Builder
  private renderVoicePanel() {
    Column({ space: 12 }) {
      Text(this.uiState.voiceState === 'recording' ? '正在监听，点按钮结束录音。' : '点击开始录音，识别结果会先进草稿。')
        .fontSize(13)
        .fontColor('#606168')
        .width('100%')
        .textAlign(TextAlign.Center)

      Button(this.uiState.voiceState === 'recording' ? '停止录音' : '开始录音')
        .width('100%')
        .height(74)
        .fontSize(18)
        .fontColor('#FFFFFF')
        .backgroundColor(this.uiState.voiceState === 'recording' ? '#B36D47' : '#7A835E')
        .borderRadius(22)
        .opacity(this.uiState.voiceEnabled ? 1 : 0.65)
        .onClick(() => {
          this.startOrStopVoice();
        })

      Row({ space: 8 }) {
        this.renderBottomActionKey(this.resolveQuickSwitchLabel(), false, (): void => {
          this.switchQuickSubtype();
        })

        this.renderBottomActionKey('清空', false, (): void => {
          void imeRuntime.getSessionManager()?.clearActiveInput();
        })

        this.renderBottomActionKey('回车', false, (): void => {
          void imeRuntime.getSessionManager()?.pressEnter();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#DCDCE0')
    .borderRadius(24)
  }

  @Builder
  private renderTopIconButton(label: string, active: boolean, action: () => void, enabled: boolean = true) {
    Button(label)
      .width(46)
      .height(46)
      .fontSize(label.length > 1 ? 15 : 22)
      .fontWeight(FontWeight.Medium)
      .fontColor(enabled ? '#1B1B1D' : '#B1B3B9')
      .backgroundColor(active ? '#E7EEE0' : '#F4F4F1')
      .borderRadius(23)
      .opacity(enabled ? 1 : 0.55)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  @Builder
  private renderFeatureButton(label: string, active: boolean, action: () => void, enabled: boolean = true) {
    Button(label)
      .layoutWeight(1)
      .height(44)
      .fontSize(label.length > 1 ? 13 : 18)
      .fontWeight(FontWeight.Medium)
      .fontColor(enabled ? '#44464D' : '#B8BAC0')
      .backgroundColor(active ? '#FFFFFF' : '#ECECEF')
      .borderRadius(14)
      .opacity(enabled ? 1 : 0.55)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  @Builder
  private renderPunctuationRail() {
    Column({ space: 18 }) {
      ForEach(SIDE_PUNCTUATIONS, (symbol: string) => {
        Text(symbol)
          .fontSize(24)
          .fontColor('#171717')
          .width('100%')
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.commitText(symbol);
          })
      }, (symbol: string): string => symbol)
    }
    .justifyContent(FlexAlign.SpaceAround)
    .width(76)
    .height(252)
    .padding({ top: 16, bottom: 16 })
    .backgroundColor('#FFFFFF')
    .borderRadius(22)
  }

  @Builder
  private renderNineGridKey(descriptor: NineGridKeyDescriptor) {
    Column({ space: 6 }) {
      Text(descriptor.digit)
        .fontSize(12)
        .fontColor('#9B9CA3')

      Text(descriptor.label)
        .fontSize(descriptor.label.length > 2 ? 22 : 26)
        .fontWeight(FontWeight.Medium)
        .fontColor('#161616')
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(78)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
    .onClick(() => {
      if (descriptor.action === 'digit') {
        void imeRuntime.getSessionManager()?.typeNineKeyDigit(descriptor.value);
      } else {
        this.commitText(descriptor.value);
      }
    })
  }

  @Builder
  private renderSideActionKey(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .height(78)
      .fontSize(label === '⌫' ? 30 : 20)
      .fontWeight(FontWeight.Medium)
      .fontColor('#262626')
      .backgroundColor('#C9CAD1')
      .borderRadius(20)
      .onClick(() => {
        action();
      })
  }

  @Builder
  private renderTallSideActionKey(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .height(164)
      .fontSize(20)
      .fontWeight(FontWeight.Medium)
      .fontColor('#262626')
      .backgroundColor('#C9CAD1')
      .borderRadius(20)
      .onClick(() => {
        action();
      })
  }

  @Builder
  private renderBottomActionKey(label: string, active: boolean, action: () => void, enabled: boolean = true) {
    Button(label)
      .layoutWeight(1)
      .height(70)
      .fontSize(label.length > 2 ? 16 : 18)
      .fontWeight(FontWeight.Medium)
      .fontColor(enabled ? '#202020' : '#B0B2B8')
      .backgroundColor(active ? '#D8E1D1' : '#C9CAD1')
      .borderRadius(20)
      .opacity(enabled ? 1 : 0.55)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  @Builder
  private renderVoicePadKey() {
    Column({ space: 4 }) {
      Text('0')
        .fontSize(12)
        .fontColor('#9B9CA3')

      Text(this.uiState.voiceState === 'recording' ? '停止语音' : '麦克风')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#181818')

      Text(this.uiState.voiceEnabled ? this.resolveVoicePadSubline() : '当前字段不可用')
        .fontSize(10)
        .fontColor('#7A7C82')
        .maxLines(1)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(2.1)
    .height(70)
    .backgroundColor('#FFFFFF')
    .borderRadius(22)
    .opacity(this.uiState.voiceEnabled ? 1 : 0.65)
    .onClick(() => {
      if (this.uiState.voiceEnabled) {
        this.startOrStopVoice();
      } else {
        this.commitText(' ');
      }
    })
  }

  @Builder
  private renderQwertyRow(keys: string[]) {
    Row({ space: 6 }) {
      ForEach(keys, (key: string) => {
        this.renderQwertyLetterKey(key)
      }, (key: string): string => key)
    }
    .width('100%')
  }

  @Builder
  private renderQwertyRowIndented(keys: string[], inset: number) {
    Row({ space: 6 }) {
      ForEach(keys, (key: string) => {
        this.renderQwertyLetterKey(key)
      }, (key: string): string => `${inset}-${key}`)
    }
    .width('100%')
    .padding({ left: inset, right: inset })
  }

  @Builder
  private renderQwertyLetterKey(key: string) {
    Column() {
      Text(key.toUpperCase())
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor('#181818')
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .height(46)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .onClick(() => {
      this.commitText(key);
    })
  }

  @Builder
  private renderQwertyActionKey(label: string, action: () => void) {
    Button(label)
      .layoutWeight(1.15)
      .height(46)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor('#323338')
      .backgroundColor('#C9CAD1')
      .borderRadius(16)
      .onClick(() => {
        action();
      })
  }

  private handlePrimaryToolbarAction(): void {
    if (this.uiState.voiceDraftText.length > 0) {
      void imeRuntime.getSessionManager()?.insertVoiceDraft();
      return;
    }
    if (this.uiState.showPolishSuggestion) {
      void imeRuntime.getSessionManager()?.acceptPolishSuggestion();
      return;
    }
    if (this.uiState.polishEnabled && this.uiState.canPolish && !this.uiState.isPolishRunning) {
      void imeRuntime.getSessionManager()?.polishPendingText();
      return;
    }
    if (this.uiState.candidates.length > 0) {
      void imeRuntime.getSessionManager()?.selectCandidate(0);
    }
  }

  private handleSendAction(): void {
    if (this.uiState.voiceDraftText.length > 0) {
      void imeRuntime.getSessionManager()?.insertVoiceDraft();
      return;
    }
    void imeRuntime.getSessionManager()?.pressEnter();
  }

  private startOrStopVoice(): void {
    if (this.uiState.voiceState === 'recording') {
      void imeRuntime.getSessionManager()?.stopVoiceInput();
      return;
    }
    if (this.uiState.voiceState === 'idle' || this.uiState.voiceState === 'error') {
      void imeRuntime.getSessionManager()?.startVoiceInput();
    }
  }

  private commitText(text: string): void {
    void imeRuntime.getSessionManager()?.typeText(text);
  }

  private cycleKeyboardLayout(): void {
    if (this.uiState.availableKeyboardLayouts.length <= 1) {
      return;
    }
    let currentIndex = -1;
    for (let index = 0; index < this.uiState.availableKeyboardLayouts.length; index++) {
      if (this.uiState.availableKeyboardLayouts[index].id === this.uiState.keyboardLayout) {
        currentIndex = index;
        break;
      }
    }
    let nextIndex = currentIndex >= 0 ? (currentIndex + 1) % this.uiState.availableKeyboardLayouts.length : 0;
    let target = this.uiState.availableKeyboardLayouts[nextIndex];
    void imeRuntime.getSessionManager()?.switchKeyboardLayout(target.id);
  }

  private supportsNineKey(): boolean {
    return this.hasLayoutOption('t9_9');
  }

  private supportsTwentySixKey(): boolean {
    return this.hasLayoutOption('qwerty_26');
  }

  private hasLayoutOption(layout: KeyboardLayoutId): boolean {
    for (let index = 0; index < this.uiState.availableKeyboardLayouts.length; index++) {
      if (this.uiState.availableKeyboardLayouts[index].id === layout) {
        return true;
      }
    }
    return false;
  }

  private resolveQuickSwitchLabel(): string {
    return this.uiState.currentSubtypeId.startsWith('en-') ? '拼音' : '中/英';
  }

  private resolveQuickSwitchIconLabel(): string {
    return this.uiState.currentSubtypeId.startsWith('en-') ? '中' : 'EN';
  }

  private switchQuickSubtype(): void {
    let targetSubtype = this.resolveQuickSwitchSubtypeId();
    if (targetSubtype.length === 0) {
      return;
    }
    void imeRuntime.getSessionManager()?.switchSubtype(targetSubtype);
  }

  private resolveQuickSwitchSubtypeId(): string {
    if (this.uiState.currentSubtypeId.startsWith('en-')) {
      let zhSubtype = this.findSubtypeById('zh-Hans-pinyin');
      return zhSubtype.length > 0 ? zhSubtype : this.findFirstSubtypeByLocale('zh');
    }
    let englishSubtype = this.findSubtypeById('en-US-qwerty');
    if (englishSubtype.length > 0) {
      return englishSubtype;
    }
    return this.findFirstSubtypeByLocale('en');
  }

  private findSubtypeById(subtypeId: string): string {
    for (let index = 0; index < this.uiState.availableSubtypes.length; index++) {
      if (this.uiState.availableSubtypes[index].id === subtypeId) {
        return subtypeId;
      }
    }
    return '';
  }

  private findFirstSubtypeByLocale(prefix: string): string {
    for (let index = 0; index < this.uiState.availableSubtypes.length; index++) {
      if (this.uiState.availableSubtypes[index].id.startsWith(prefix)) {
        return this.uiState.availableSubtypes[index].id;
      }
    }
    return '';
  }

  private resolveComposeHeadline(): string {
    if (this.uiState.voiceDraftText.length > 0) {
      return this.uiState.voiceDraftText;
    }
    if (this.uiState.preedit.length > 0) {
      return this.uiState.preedit;
    }
    if (this.uiState.activeNineKeySpelling.length > 0) {
      return this.uiState.activeNineKeySpelling;
    }
    if (this.uiState.candidates.length > 0) {
      return this.uiState.candidates[0].text;
    }
    return '开始输入';
  }

  private resolveComposeSubline(): string {
    if (this.uiState.voiceDraftText.length > 0) {
      return '点 + 或 ↑ 直接插入草稿';
    }
    if (this.uiState.showPolishSuggestion) {
      return '有润色建议待处理';
    }
    if (this.uiState.preedit.length > 0) {
      return `候选第 ${this.uiState.candidatePageNo + 1} 页`;
    }
    if (this.uiState.activeNineKeySpelling.length > 0 || this.uiState.nineKeySequence.length > 0) {
      return this.uiState.nineKeySequence.length > 0 ? `9 键编码 ${this.uiState.nineKeySequence}` : '9 键拼音';
    }
    if (this.uiState.sessionActive) {
      return `${this.uiState.currentSubtypeName} · ${this.resolveLayoutDisplayLabel(this.uiState.keyboardLayout)}`;
    }
    return '等待 inputStart';
  }

  private resolveCandidatePlaceholder(): string {
    if (this.uiState.activeNineKeySpelling.length > 0 || this.uiState.nineKeySequence.length > 0) {
      return '继续输入 9 键拼音，候选会显示在这里。';
    }
    if (this.uiState.sessionActive) {
      return '输入拼音或英文后，这里会显示候选。';
    }
    return '等待输入法会话绑定。';
  }

  private resolveLayoutIconLabel(): string {
    switch (this.uiState.keyboardLayout) {
      case 't9_9':
        return '9';
      case 'voice_panel':
        return '语';
      default:
        return '26';
    }
  }

  private resolveLayoutDisplayLabel(layout: KeyboardLayoutId): string {
    switch (layout) {
      case 't9_9':
        return '9 键';
      case 'voice_panel':
        return '语音';
      default:
        return '26 键';
    }
  }

  private resolveVoicePadSubline(): string {
    switch (this.uiState.voiceState) {
      case 'recording':
        return '点击停止';
      case 'processing':
        return '正在转写';
      case 'error':
        return '可再次尝试';
      default:
        return '语音输入';
    }
  }
}
