#ifndef CNN_H
#define CNN_H
#include <stdint.h>

#define CNN_CAPTURE_BYTES (128 * 128 * 3)
#define CNN_IMAGE_BYTES (32 * 32 * 3)
#define CNN_CLASSES 3   /* phone, power_bank, scissors (wallet excluded for now) */

typedef struct {
    float input[3 * 32 * 32];
    float pool1[8 * 16 * 16];
    float pool2[16 * 8 * 8];
    float pool3[24 * 4 * 4];
} CnnWorkspace;

extern const char *const cnn_class_names[CNN_CLASSES];
void cnn_downsample(const uint8_t capture[CNN_CAPTURE_BYTES], uint8_t rgb[CNN_IMAGE_BYTES]);
void cnn_predict(const uint8_t rgb[CNN_IMAGE_BYTES], CnnWorkspace *work,
                 float logits[CNN_CLASSES]);
#endif
