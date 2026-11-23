"""
Stage 4 CNN training - 3 classes (phone, power_bank, scissors), wallet excluded for now.

Recipe (the one that scored 39/42 = 92.9% on our test split as the "baseline"):
  - same network as the teammate's cnn.c : conv3x3(8)+ReLU+maxpool -> conv3x3(16)+ReLU+maxpool
                                           -> conv3x3(24)+ReLU+maxpool -> FC(384 -> 3)
  - same input path as the board        : 128x128 RGB888 -> 4x4 average ((sum+8)/16) -> 32x32 -> /255
  - no augmentation, no class weights, no dropout
  - AdamW lr 1e-3 (weight decay 0) + cosine LR schedule, batch 32
  - 200 epochs, the epoch with the best validation score is kept (checkpoint)
  - several seeds, the seed with the best VALIDATION score is exported (test is not used to choose)

Usage (from the repo root):
  py -3 stage4_cnn\\train.py --data stage3_capture\\captures --out stage4_cnn\\out

Output (stage4_cnn\\out\\, written at the very end):
  cnn_weights.h      weights for the board (use with sdk\\cnn.c, sdk\\cnn.h)
  model.pt           PyTorch state_dict
  test_vectors.json  test images with label / prediction / logits (board parity check)
  report.json        split, per-seed scores, test accuracy, confusion matrix
"""
import argparse
import json
import os
import random
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

CLASSES = ["phone", "power_bank", "scissors"]
FOLDERS = {"phone": "phone", "power_bank": "powerbank", "scissors": "scissors"}


# ----------------------------------------------------------------------------- data
def downsample_like_board(img128):
    """exactly cnn_downsample() in cnn.c: 4x4 block sum, (sum + 8) // 16, uint8"""
    a = img128.astype(np.uint32).reshape(32, 4, 32, 4, 3).sum(axis=(1, 3))
    return ((a + 8) // 16).astype(np.uint8)


def load_split(data_dir, gap=3, val_frac=0.15, test_frac=0.15):
    """chronological split per class (consecutive frames are near-duplicates):
       first part -> train, gap, middle -> val, gap, last -> test"""
    split = {"train": [], "val": [], "test": []}
    for ci, name in enumerate(CLASSES):
        folder = os.path.join(data_dir, FOLDERS[name])
        files = sorted(f for f in os.listdir(folder) if f.endswith(".png") and "_x" not in f)
        n = len(files)
        n_test = max(1, round(n * test_frac))
        n_val = max(1, round(n * val_frac))
        n_train = n - n_test - n_val - 2 * gap
        parts = {
            "train": files[:n_train],
            "val": files[n_train + gap:n_train + gap + n_val],
            "test": files[n - n_test:],
        }
        for k, fl in parts.items():
            for f in fl:
                img = np.array(Image.open(os.path.join(folder, f)).convert("RGB"))
                assert img.shape == (128, 128, 3), (f, img.shape)
                split[k].append((downsample_like_board(img), ci, f"{FOLDERS[name]}/{f}"))
    return split


def to_tensor(items):
    x = torch.tensor(np.stack([i[0] for i in items]), dtype=torch.float32).permute(0, 3, 1, 2) / 255.0
    y = torch.tensor([i[1] for i in items], dtype=torch.long)
    return x, y


# ----------------------------------------------------------------------------- model
class Net(nn.Module):
    def __init__(self, n_cls=len(CLASSES)):
        super().__init__()
        self.c1 = nn.Conv2d(3, 8, 3, padding=1)
        self.c2 = nn.Conv2d(8, 16, 3, padding=1)
        self.c3 = nn.Conv2d(16, 24, 3, padding=1)
        self.fc = nn.Linear(24 * 4 * 4, n_cls)

    def forward(self, x):
        x = F.max_pool2d(F.relu(self.c1(x)), 2)
        x = F.max_pool2d(F.relu(self.c2(x)), 2)
        x = F.max_pool2d(F.relu(self.c3(x)), 2)
        return self.fc(x.flatten(1))


def macro_recall(pred, y, n_cls=len(CLASSES)):
    r = [(pred[y == c] == c).float().mean().item() for c in range(n_cls) if (y == c).sum() > 0]
    return float(np.mean(r))


def confusion(pred, y, n_cls=len(CLASSES)):
    cm = np.zeros((n_cls, n_cls), dtype=int)
    for t, p in zip(y.tolist(), pred.tolist()):
        cm[t, p] += 1
    return cm.tolist()


def train_one(xtr, ytr, xva, yva, epochs, seed, tag, t0):
    torch.manual_seed(seed); random.seed(seed); np.random.seed(seed)
    net = Net()
    opt = torch.optim.AdamW(net.parameters(), lr=1e-3, weight_decay=0.0)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epochs)
    lossf = nn.CrossEntropyLoss()
    best = (-1.0, 0, None)
    bs = 32
    for ep in range(1, epochs + 1):
        net.train()
        perm = torch.randperm(len(xtr))
        tot, nb = 0.0, 0
        for i in range(0, len(xtr), bs):
            idx = perm[i:i + bs]
            loss = lossf(net(xtr[idx]), ytr[idx])
            opt.zero_grad(); loss.backward(); opt.step()
            tot += loss.item(); nb += 1
        sched.step()
        net.eval()
        with torch.no_grad():
            mr = macro_recall(net(xva).argmax(1), yva)
        if mr > best[0] + 1e-9:
            best = (mr, ep, {k: v.clone() for k, v in net.state_dict().items()})
        print(f"{tag} ep {ep:3d}/{epochs}  loss {tot / nb:.3f}  val {mr:.3f}  "
              f"best {best[0]:.3f}@{best[1]}  ({time.time() - t0:.0f}s)", flush=True)
    net.load_state_dict(best[2]); net.eval()
    return net, best[0], best[1]


# ----------------------------------------------------------------------------- export
def export_weights_h(net, path):
    sd = {k: v.detach().cpu().numpy().astype(np.float32) for k, v in net.state_dict().items()}
    names = [("conv1_weight", "c1.weight"), ("conv1_bias", "c1.bias"),
             ("conv2_weight", "c2.weight"), ("conv2_bias", "c2.bias"),
             ("conv3_weight", "c3.weight"), ("conv3_bias", "c3.bias"),
             ("fc_weight", "fc.weight"), ("fc_bias", "fc.bias")]
    with open(path, "w", newline="\n") as f:
        f.write("#ifndef CNN_WEIGHTS_H\n#define CNN_WEIGHTS_H\n")
        f.write("/* generated by stage4_cnn/train.py - classes: " + ", ".join(CLASSES) + " */\n\n")
        for cname, key in names:
            a = sd[key].reshape(-1)
            f.write(f"static const float {cname}[{a.size}] = {{\n")
            for i in range(0, a.size, 6):
                f.write("    " + ", ".join(f"{v:.9e}f" for v in a[i:i + 6]) + ",\n")
            f.write("};\n\n")
        f.write("#endif\n")


def c_reference(net, rgb32):
    """numpy re-implementation of cnn.c (float32) for a parity check"""
    sd = {k: v.detach().cpu().numpy().astype(np.float32) for k, v in net.state_dict().items()}
    x = (rgb32.astype(np.float32) / np.float32(255.0)).transpose(2, 0, 1)

    def conv_pool(inp, w, b):
        c_out, side = w.shape[0], inp.shape[1]
        pad = np.pad(inp, ((0, 0), (1, 1), (1, 1)))
        conv = np.zeros((c_out, side, side), dtype=np.float32)
        for o in range(c_out):
            acc = np.full((side, side), b[o], dtype=np.float32)
            for c in range(inp.shape[0]):
                for ky in range(3):
                    for kx in range(3):
                        acc += pad[c, ky:ky + side, kx:kx + side] * w[o, c, ky, kx]
            conv[o] = acc
        conv = np.maximum(conv, 0)
        return conv.reshape(c_out, side // 2, 2, side // 2, 2).max(axis=(2, 4))

    x = conv_pool(x, sd["c1.weight"], sd["c1.bias"])
    x = conv_pool(x, sd["c2.weight"], sd["c2.bias"])
    x = conv_pool(x, sd["c3.weight"], sd["c3.bias"])
    return sd["fc.weight"] @ x.reshape(-1) + sd["fc.bias"]


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join("stage3_capture", "captures"))
    ap.add_argument("--out", default=os.path.join("stage4_cnn", "out"))
    ap.add_argument("--epochs", type=int, default=200)
    ap.add_argument("--seeds", type=int, nargs="+", default=[1, 2, 3])
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    t0 = time.time()

    split = load_split(args.data)
    xtr, ytr = to_tensor(split["train"]); xva, yva = to_tensor(split["val"]); xte, yte = to_tensor(split["test"])
    print("split sizes:", {k: len(v) for k, v in split.items()},
          "train per class:", torch.bincount(ytr).tolist(), flush=True)

    runs, best_net, best_key = [], None, None
    for i, s in enumerate(args.seeds, 1):
        net, val, ep = train_one(xtr, ytr, xva, yva, args.epochs, s, f"[seed {s} ({i}/{len(args.seeds)})]", t0)
        with torch.no_grad():
            pt = net(xte).argmax(1)
        acc = (pt == yte).float().mean().item()
        runs.append({"seed": s, "val_macro_recall": val, "best_epoch": ep, "test_accuracy": acc})
        print(f"==> seed {s}: val {val:.3f} @ep{ep}   test {int((pt == yte).sum())}/{len(yte)} = {acc:.3f}", flush=True)
        if best_key is None or val > best_key[0] + 1e-9:      # chosen by VALIDATION only
            best_key, best_net = (val, s, ep), net

    net = best_net
    with torch.no_grad():
        p_te = net(xte).argmax(1)
        logits_t = net(xte).numpy()
    acc = (p_te == yte).float().mean().item()
    print(f"\nCHOSEN seed {best_key[1]} (best validation {best_key[0]:.3f} @ep{best_key[2]})")
    print(f"TEST {int((p_te == yte).sum())}/{len(yte)} = {acc:.3f}   macro-recall {macro_recall(p_te, yte):.3f}")
    print("confusion (rows=true, cols=pred, order", CLASSES, "):", confusion(p_te, yte))

    torch.save(net.state_dict(), os.path.join(args.out, "model.pt"))
    export_weights_h(net, os.path.join(args.out, "cnn_weights.h"))

    examples, max_err, agree = [], 0.0, 0
    for i, (rgb, ci, name) in enumerate(split["test"]):
        lc = c_reference(net, rgb)
        max_err = max(max_err, float(np.abs(lc - logits_t[i]).max()))
        agree += int(np.argmax(lc) == np.argmax(logits_t[i]))
        examples.append({"name": name, "label": ci, "predicted": int(np.argmax(logits_t[i])),
                         "logits": [float(v) for v in logits_t[i]]})
    with open(os.path.join(args.out, "test_vectors.json"), "w") as f:
        json.dump({"classes": CLASSES, "examples": examples}, f, indent=1)
    report = {
        "classes": CLASSES, "split": {k: len(v) for k, v in split.items()},
        "train_per_class": torch.bincount(ytr).tolist(),
        "recipe": "no augmentation, no class weights, AdamW lr 1e-3 wd 0 + cosine, batch 32, best-validation checkpoint",
        "epochs": args.epochs, "runs": runs,
        "chosen_seed": best_key[1], "chosen_val": best_key[0], "chosen_epoch": best_key[2],
        "test_accuracy": acc, "test_macro_recall": macro_recall(p_te, yte),
        "test_confusion": confusion(p_te, yte),
        "c_reference_parity": {"argmax_agree": agree, "n": len(examples), "max_abs_logit_error": max_err},
        "params": int(sum(p.numel() for p in net.parameters())),
        "train_seconds": round(time.time() - t0, 1),
    }
    with open(os.path.join(args.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(f"C-reference parity: argmax {agree}/{len(examples)}, max |logit err| {max_err:.2e}")
    print("saved:", os.path.abspath(args.out))


if __name__ == "__main__":
    main()
