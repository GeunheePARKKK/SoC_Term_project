#include "cnn.h"
#include "cnn_weights.h"

const char *const cnn_class_names[CNN_CLASSES] = { "phone", "power_bank", "scissors" };

/* Combine padded convolution, ReLU and max pooling without a full conv buffer. */
static void conv_pool(const float *input, int channels, int side,
                      const float *weights, const float *bias, int filters,
                      float *output)
{
    const int pooled = side / 2;
    for (int filter = 0; filter < filters; ++filter) {
        for (int y = 0; y < pooled; ++y) {
            for (int x = 0; x < pooled; ++x) {
                float best = 0.0f;
                for (int py = 0; py < 2; ++py) {
                    for (int px = 0; px < 2; ++px) {
                        float sum = bias[filter];
                        for (int channel = 0; channel < channels; ++channel) {
                            for (int ky = 0; ky < 3; ++ky) {
                                const int iy = y * 2 + py + ky - 1;
                                if (iy < 0 || iy >= side) {
                                    continue;
                                }
                                for (int kx = 0; kx < 3; ++kx) {
                                    const int ix = x * 2 + px + kx - 1;
                                    if (ix >= 0 && ix < side) {
                                        const int pixel = (channel * side + iy) * side + ix;
                                        const int kernel = ((filter * channels + channel) * 3 + ky) * 3 + kx;
                                        sum += input[pixel] * weights[kernel];
                                    }
                                }
                            }
                        }
                        if (sum > best) {
                            best = sum;
                        }
                    }
                }
                output[(filter * pooled + y) * pooled + x] = best;
            }
        }
    }
}

void cnn_downsample(const uint8_t capture[CNN_CAPTURE_BYTES], uint8_t rgb[CNN_IMAGE_BYTES])
{
    for (int y = 0; y < 32; ++y) {
        for (int x = 0; x < 32; ++x) {
            for (int c = 0; c < 3; ++c) {
                unsigned total = 0;
                for (int dy = 0; dy < 4; ++dy) {
                    for (int dx = 0; dx < 4; ++dx) {
                        total += capture[((y * 4 + dy) * 128 + x * 4 + dx) * 3 + c];
                    }
                }
                rgb[(y * 32 + x) * 3 + c] = (uint8_t)((total + 8) / 16);
            }
        }
    }
}
void cnn_predict(const uint8_t rgb[CNN_IMAGE_BYTES], CnnWorkspace *work,
                 float logits[CNN_CLASSES])
{
    for (int channel = 0; channel < 3; ++channel) {
        for (int pixel = 0; pixel < 32 * 32; ++pixel) {
            work->input[channel * 32 * 32 + pixel] = rgb[pixel * 3 + channel] / 255.0f;
        }
    }
    conv_pool(work->input, 3, 32, conv1_weight, conv1_bias, 8, work->pool1);
    conv_pool(work->pool1, 8, 16, conv2_weight, conv2_bias, 16, work->pool2);
    conv_pool(work->pool2, 16, 8, conv3_weight, conv3_bias, 24, work->pool3);

    for (int label = 0; label < CNN_CLASSES; ++label) {
        float sum = fc_bias[label];
        for (int feature = 0; feature < 384; ++feature) {
            sum += fc_weight[label * 384 + feature] * work->pool3[feature];
        }
        logits[label] = sum;
    }
}
