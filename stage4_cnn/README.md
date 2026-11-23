# Stage 4: CNN (3 classes: phone, power_bank, scissors)

지갑(wallet)은 사진이 부족해서 이번 버전에서는 뺐습니다. 다음에 더 찍어서 다시 넣을 예정입니다.

## 폴더 구성

| 파일 | 내용 |
|---|---|
| `train.py` | 학습 코드 (PyTorch, CPU로 실행 가능) |
| `sdk/cnn.c`, `sdk/cnn.h` | 보드용 C 추론 코드. 팀원 버전에서 **클래스 수만 4 → 3으로 수정** |
| `out/cnn_weights.h` | 학습된 가중치 (`train.py` 실행 결과) |
| `out/model.pt` | PyTorch 모델 |
| `out/test_vectors.json` | 테스트 사진별 정답, 예측, logits (보드 검증용) |
| `out/report.json` | 데이터 분할, 시드별 점수, 테스트 정확도, 혼동표 |

## 학습 방법 (저장소 루트에서)

```bat
py -3 stage4_cnn\train.py --data stage3_capture\captures --out stage4_cnn\out
```

- 에폭마다 진행 상황이 출력됩니다. 결과 파일은 **마지막에 한꺼번에** 저장됩니다.
- 옵션: `--epochs 200` (기본), `--seeds 1 2 3` (기본)

## 학습 방식

- 신경망: 팀원 `cnn.c`와 동일. conv3x3(8) → conv3x3(16) → conv3x3(24), 각각 ReLU + maxpool, 그다음 FC(384 → 3)
- 입력: 128×128 RGB → 4×4 평균((합+8)/16) → 32×32 → /255. 보드 `cnn_downsample()`와 똑같이 계산
- 데이터 분할: 클래스별로 촬영 순서대로 학습 70% / 검증 15% / 테스트 15%. 연속 사진이 겹치지 않게 사이에 3장 간격
- 증강 없음, 클래스 가중치 없음. AdamW(lr 1e-3, weight decay 0) + cosine 학습률, 배치 32
- 200에폭 동안 **검증 점수가 가장 좋았던 시점**을 저장. 시드 3개 중 **검증 점수가 가장 좋은 모델**을 내보냄(테스트 점수로는 고르지 않음)

## 시도했다가 뺀 것 (2026-11-23)

데이터 증강(회전, 뒤집기, 이동, 밝기·색), 클래스 가중치, Dropout, GAP 머리, 밝기 정규화, train+val 재학습을 넣어봤지만 결과가 **오히려 나빠졌습니다**.

| 방식 | 테스트 (42장) |
|---|---|
| 증강 없음 (현재 방식) | 39/42 = 92.9% |
| 개선 적용, train만 | 34/42 = 81.0% |
| 개선 적용, train+val 재학습 | 28/42 = 66.7% |

휴대폰과 보조배터리를 서로 헷갈리는 경우가 늘었습니다. 둘 다 직사각형이라 색과 밝기가 중요한 단서인데, 밝기 정규화와 색 변화가 그걸 지운 것으로 보입니다.

## 보드에 넣는 법

1. `sdk/cnn.c`, `sdk/cnn.h`, `out/cnn_weights.h`를 SDK 앱 `src`에 복사
2. SDK 빌드는 최적화(-O2) 권장
3. 사용:
   ```c
   static CnnWorkspace work;
   static uint8_t rgb32[CNN_IMAGE_BYTES];
   static float logits[CNN_CLASSES];
   cnn_downsample(capture128, rgb32);   /* capture128: 128x128 R,G,B 바이트 (49,152) */
   cnn_predict(rgb32, &work, logits);   /* argmax(logits) = 0 phone, 1 power_bank, 2 scissors */
   ```
   capture IP 픽셀은 `0x00RRGGBB` 워드라서, R, G, B 바이트로 풀어서 `capture128`에 넣어야 합니다.
