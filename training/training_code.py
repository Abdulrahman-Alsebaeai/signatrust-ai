# ================================================================
# GLOBAL ONLINE SIGNATURE VERIFICATION — ONE KAGGLE CELL
# Public datasets: MOBISIG + SVC2004 Task1/Task2
# SSL handwriting: OnHW + UNIPEN
# Automatically scans additional licensed datasets in /kaggle/input
# Exports: TorchScript, ONNX, checkpoint, threshold, metrics, ZIP
# ================================================================

import os, sys, re, json, math, time, random, shutil, zipfile, tarfile, warnings, subprocess
from pathlib import Path
warnings.filterwarnings("ignore")

# ------------------------- Configuration -------------------------

SEED = 2026
FULL_TRAIN = True                 # False فقط لاختبار أن الخلية تعمل بسرعة
DOWNLOAD_MOBISIG = True
DOWNLOAD_SVC2004 = True
DOWNLOAD_ONHW = True              # حوالي 895 MB، للتدريب التمهيدي
DOWNLOAD_UNIPEN = False              # Zenodo currently returns 403; enable only when a valid source is available
SCAN_KAGGLE_INPUT = True          # يقرأ أي Dataset تضيفها عبر Add Input

SEQ_LEN = 192
BASE_FEATURES = 16
INPUT_FEATURES = 37               # 16 features + 16 presence masks + 5 metadata
EMBED_DIM = 192
MODEL_DIM = 160
TRANSFORMER_LAYERS = 4
TRANSFORMER_HEADS = 8

MAX_SSL_SAMPLES = 15000 if FULL_TRAIN else 2500
MAX_FILES_TO_SCAN = 120000 if FULL_TRAIN else 5000
SSL_EPOCHS = 8 if FULL_TRAIN else 1
VERIFY_EPOCHS = 30 if FULL_TRAIN else 2
SSL_BATCH = 64 if FULL_TRAIN else 16
PAIR_BATCH = 32 if FULL_TRAIN else 8
LEARNING_RATE = 1.5e-4
WEIGHT_DECAY = 1e-4
HARD_MINE_EVERY = 2
SOFT_DTW_EVERY = 20
SOFT_DTW_SUBSET = 4
NUM_WORKERS = 0

ROOT = Path("/kaggle/working/global_signature_project")
DATA_DIR = ROOT / "data"
EXTRACT_DIR = ROOT / "extracted"
STRONG_ROOT = Path("/kaggle/working/global_signature_project_strong_v2")
CKPT_DIR = STRONG_ROOT / "checkpoints"
EXPORT_DIR = STRONG_ROOT / "deployment"
for p in [ROOT, DATA_DIR, EXTRACT_DIR, STRONG_ROOT, CKPT_DIR, EXPORT_DIR]:
    p.mkdir(parents=True, exist_ok=True)

random.seed(SEED)
os.environ["PYTHONHASHSEED"] = str(SEED)

# ------------------------- Dependencies --------------------------

def pip_install(packages):
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "-q", *packages],
        check=False
    )

pip_install(["onnx", "onnxruntime", "requests", "tqdm"])

import numpy as np
import pandas as pd
import requests
import torch
import torch.nn as nn
import torch.nn.functional as F

from torch.utils.data import Dataset, DataLoader
from sklearn.metrics import roc_curve, roc_auc_score, accuracy_score
from tqdm.auto import tqdm

torch.manual_seed(SEED)
np.random.seed(SEED)
if torch.cuda.is_available():
    torch.cuda.manual_seed_all(SEED)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
AMP = DEVICE.type == "cuda"

print("=" * 72)
print("Device:", DEVICE)
if DEVICE.type == "cuda":
    print("GPU:", torch.cuda.get_device_name(0))
else:
    print("WARNING: فعّل GPU من إعدادات Kaggle قبل التدريب الكامل.")
print("=" * 72)

# ------------------------- Download helpers ----------------------

def download_file(url, destination, timeout=120):
    destination = Path(destination)
    if destination.exists() and destination.stat().st_size > 1024:
        print("Already downloaded:", destination.name)
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    print("Downloading on Kaggle server:", destination.name)

    with requests.get(
        url,
        stream=True,
        timeout=timeout,
        headers={"User-Agent": "Mozilla/5.0"}
    ) as response:
        response.raise_for_status()
        total = int(response.headers.get("content-length", 0))
        with open(destination, "wb") as f, tqdm(
            total=total,
            unit="B",
            unit_scale=True,
            desc=destination.name
        ) as bar:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f.write(chunk)
                    bar.update(len(chunk))
    return destination

def extract_archive(archive, destination):
    archive, destination = Path(archive), Path(destination)
    marker = destination / ".extracted_ok"
    if marker.exists():
        return destination

    destination.mkdir(parents=True, exist_ok=True)
    print("Extracting:", archive.name)

    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            z.extractall(destination)
    elif tarfile.is_tarfile(archive):
        with tarfile.open(archive) as t:
            t.extractall(destination)
    else:
        raise RuntimeError(f"Unsupported archive: {archive}")

    marker.touch()
    return destination

downloaded_roots = []

# MOBISIG
if DOWNLOAD_MOBISIG:
    try:
        f = download_file(
            "https://www.ms.sapientia.ro/~manyi/mobisig/MOBISIG.ZIP",
            DATA_DIR / "MOBISIG.ZIP"
        )
        downloaded_roots.append(
            extract_archive(f, EXTRACT_DIR / "MOBISIG")
        )
    except Exception as e:
        print("MOBISIG download failed:", repr(e))

# SVC2004
if DOWNLOAD_SVC2004:
    for task, url in [
        ("SVC2004_Task1", "https://cse.hkust.edu.hk/svc2004/Task1.zip"),
        ("SVC2004_Task2", "https://cse.hkust.edu.hk/svc2004/Task2.zip"),
    ]:
        try:
            f = download_file(url, DATA_DIR / f"{task}.zip")
            downloaded_roots.append(
                extract_archive(f, EXTRACT_DIR / task)
            )
        except Exception as e:
            print(task, "download failed:", repr(e))

# OnHW
if DOWNLOAD_ONHW:
    try:
        f = download_file(
            "https://www2.iis.fraunhofer.de/LV-OnHW/onhw-chars_2021-06-30.zip",
            DATA_DIR / "OnHW_chars.zip",
            timeout=300
        )
        downloaded_roots.append(
            extract_archive(f, EXTRACT_DIR / "OnHW")
        )
    except Exception as e:
        print("OnHW download failed:", repr(e))

# UNIPEN through Zenodo API
if DOWNLOAD_UNIPEN:
    try:
        api = requests.get(
            "https://zenodo.org/api/records/1195803",
            timeout=60,
            headers={"User-Agent": "Mozilla/5.0"}
        )
        api.raise_for_status()
        files = api.json().get("files", [])
        chosen = None
        for item in files:
            name = item.get("key", "").lower()
            if name.endswith((".tgz", ".tar.gz", ".zip")):
                chosen = item
                break
        if chosen:
            url = (
                chosen.get("links", {}).get("self")
                or chosen.get("links", {}).get("download")
            )
            filename = chosen.get("key", "UNIPEN.tgz")
            f = download_file(url, DATA_DIR / filename, timeout=300)
            downloaded_roots.append(
                extract_archive(f, EXTRACT_DIR / "UNIPEN")
            )
        else:
            print("UNIPEN archive was not found in the Zenodo record.")
    except Exception as e:
        print("UNIPEN download failed:", repr(e))

# Existing attached Kaggle datasets, including licensed datasets
if SCAN_KAGGLE_INPUT and Path("/kaggle/input").exists():
    downloaded_roots.append(Path("/kaggle/input"))

print("\nData roots:")
for r in downloaded_roots:
    print(" -", r)

# ------------------------- Parsing utilities ---------------------

FLOAT_PATTERN = re.compile(
    r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"
)

def robust_scale(v):
    v = np.asarray(v, dtype=np.float32)
    finite = np.isfinite(v)
    if not finite.any():
        return np.zeros_like(v, dtype=np.float32)

    med = np.nanmedian(v[finite])
    q1, q3 = np.nanpercentile(v[finite], [25, 75])
    scale = max(float(q3 - q1), 1e-6)

    out = (np.nan_to_num(v, nan=med, posinf=med, neginf=med) - med) / scale
    return np.clip(out, -8, 8).astype(np.float32)

def minmax01(v):
    v = np.asarray(v, dtype=np.float32)
    v = np.nan_to_num(v)
    lo, hi = np.percentile(v, [1, 99]) if len(v) > 4 else (v.min(), v.max())
    if hi <= lo + 1e-8:
        return np.zeros_like(v, dtype=np.float32)
    return np.clip((v - lo) / (hi - lo), 0, 1).astype(np.float32)

def read_numeric_rows(path, max_rows=30000):
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                nums = [float(x) for x in FLOAT_PATTERN.findall(line)]
                if len(nums) == 1 and not rows:
                    # SVC first line may contain number of points
                    continue
                if len(nums) >= 2:
                    rows.append(nums)
                if len(rows) >= max_rows:
                    break
    except Exception:
        return []

    if len(rows) < 8:
        return []

    common = min(max(len(r) for r in rows), 32)
    usable = []
    for r in rows:
        if len(r) >= 2:
            usable.append((r + [0.0] * common)[:common])

    if len(usable) < 8:
        return []
    return [np.asarray(usable, dtype=np.float32)]

def read_numpy_sequences(path):
    try:
        obj = np.load(path, allow_pickle=True)
        arrays = []
        if isinstance(obj, np.lib.npyio.NpzFile):
            values = [obj[k] for k in obj.files]
        else:
            values = [obj]

        for value in values:
            value = np.asarray(value)
            if value.dtype == object:
                for sub in value.flat:
                    a = np.asarray(sub)
                    if a.ndim == 2 and a.shape[0] >= 8 and a.shape[1] >= 2:
                        arrays.append(a.astype(np.float32))
            elif value.ndim == 2 and value.shape[0] >= 8 and value.shape[1] >= 2:
                arrays.append(value.astype(np.float32))
            elif value.ndim == 3:
                arrays.extend(
                    a.astype(np.float32)
                    for a in value
                    if a.shape[0] >= 8 and a.shape[1] >= 2
                )
        return arrays[:1000]
    except Exception:
        return []

def read_unipen_segments(path, max_segments=1000):
    segments, current = [], []
    try:
        with open(path, "r", encoding="latin-1", errors="ignore") as f:
            for line in f:
                text = line.strip()
                upper = text.upper()

                if (
                    upper.startswith(".SEGMENT")
                    or upper.startswith(".PEN_DOWN")
                    or upper.startswith(".PEN_UP")
                ):
                    if len(current) >= 8:
                        segments.append(np.asarray(current, dtype=np.float32))
                    current = []
                    if len(segments) >= max_segments:
                        break
                    continue

                if text.startswith("."):
                    continue

                nums = [float(x) for x in FLOAT_PATTERN.findall(text)]
                if len(nums) >= 2:
                    current.append(nums[:8])

            if len(current) >= 8 and len(segments) < max_segments:
                segments.append(np.asarray(current, dtype=np.float32))
    except Exception:
        pass
    return segments

def load_sequences_from_file(path):
    suffix = path.suffix.lower()
    s = str(path).lower()

    if suffix in {".npy", ".npz"}:
        return read_numpy_sequences(path)

    if "unipen" in s:
        segs = read_unipen_segments(path)
        if segs:
            return segs

    if suffix in {".csv", ".txt", ".dat", ".tsv", ".sig", ".svc"}:
        return read_numeric_rows(path)

    return []

def infer_metadata(path):
    s = str(path).replace("\\", "/").lower()
    name = path.stem

    info = {
        "domain": "unknown",
        "claim": None,
        "genuine": None,
        "session": 0,
        "finger": 0.0,
        "stylus": 0.0,
        "sampling_rate": 0.0,
    }

    # MOBISIG
    m = re.search(
        r"sign_(gen|for)_user(\d+)_user(\d+)_(\d+)",
        name,
        re.I
    )
    if m:
        kind, claimed, actual, number = m.groups()
        n = int(number)
        info.update({
            "domain": "MOBISIG",
            "claim": f"MOBISIG:{claimed}",
            "genuine": kind.lower() == "gen",
            "session": 1 if n <= 15 else (2 if n <= 30 else 3),
            "finger": 1.0,
            "stylus": 0.0,
            "sampling_rate": 100.0,
        })
        return info

    # SVC2004 U1S1 naming
    m = re.search(r"u(\d+)s(\d+)", name, re.I)
    if m and ("svc2004" in s or "task1" in s or "task2" in s):
        user, sample = map(int, m.groups())
        domain = "SVC2004_Task2" if "task2" in s else "SVC2004_Task1"
        info.update({
            "domain": domain,
            "claim": f"{domain}:U{user}",
            "genuine": sample <= 20,
            "session": 0,
            "finger": 0.0,
            "stylus": 1.0,
            "sampling_rate": 100.0,
        })
        return info

    if "onhw" in s:
        info.update({
            "domain": "OnHW",
            "finger": 0.0,
            "stylus": 1.0,
            "sampling_rate": 100.0,
        })
        return info

    if "unipen" in s:
        info.update({
            "domain": "UNIPEN",
            "stylus": 1.0,
        })
        return info

    # Generic support for attached licensed datasets
    if "deepsign" in s:
        info["domain"] = "DeepSignDB"
    elif "ebiosign" in s or "e-biosign" in s:
        info["domain"] = "eBioSign"
    elif "msds" in s:
        info["domain"] = "MSDS"
    elif "susig" in s:
        info["domain"] = "SUSIG"
    elif "isig" in s:
        info["domain"] = "iSignDB"
    elif "xlong" in s:
        info["domain"] = "xLongSignDB"
    elif "mcyt" in s:
        info["domain"] = "MCYT"
    elif "casia" in s:
        info["domain"] = "CASIA"
    else:
        info["domain"] = path.parts[-3] if len(path.parts) >= 3 else "attached"

    forged_tokens = ["forg", "fake", "fraud", "skilled", "impostor"]
    genuine_tokens = ["genuine", "_gen_", "-gen-", "/gen/", "/real/", "_real_"]

    if any(t in s for t in forged_tokens):
        info["genuine"] = False
    elif any(t in s for t in genuine_tokens):
        info["genuine"] = True

    # Prefer a numeric parent directory as claimed writer identity
    writer = None
    for part in reversed(path.parts[:-1]):
        clean = re.sub(r"(forg|fake|genuine|gen|real)", "", part, flags=re.I)
        digits = re.findall(r"\d+", clean)
        if digits:
            writer = digits[-1]
            break

    if writer is None:
        m = re.search(r"(?:user|writer|subject|signer|person|u)[_-]?(\d+)", s)
        if m:
            writer = m.group(1)

    if writer is not None and info["genuine"] is not None:
        info["claim"] = f"{info['domain']}:{writer}"

    info["finger"] = 1.0 if "finger" in s else 0.0
    info["stylus"] = 1.0 if any(x in s for x in ["stylus", "wacom", "pen"]) else 0.0
    return info

def resample_features(features, length=SEQ_LEN):
    features = np.asarray(features, dtype=np.float32)
    n = len(features)
    if n == length:
        return features
    old = np.linspace(0, 1, n)
    new = np.linspace(0, 1, length)
    out = np.stack(
        [np.interp(new, old, features[:, i]) for i in range(features.shape[1])],
        axis=1
    )
    return out.astype(np.float32)

def canonicalize(arr, info):
    arr = np.asarray(arr, dtype=np.float32)
    arr = arr[np.all(np.isfinite(arr[:, :2]), axis=1)]
    if len(arr) < 8:
        return None

    n, c = arr.shape
    feat = np.zeros((n, BASE_FEATURES), dtype=np.float32)
    mask = np.zeros_like(feat)

    domain = info["domain"].lower()

    if domain == "onhw" and c >= 14:
        # OnHW: timestamp, accelerometers, gyroscope, magnetometer, force
        t = arr[:, 0] if c > 0 else np.arange(n)
        acc_x = arr[:, 1] if c > 1 else np.zeros(n)
        acc_y = arr[:, 2] if c > 2 else np.zeros(n)
        acc_z = arr[:, 3] if c > 3 else np.zeros(n)
        gyro_x = arr[:, 7] if c > 7 else np.zeros(n)
        gyro_y = arr[:, 8] if c > 8 else np.zeros(n)
        gyro_z = arr[:, 9] if c > 9 else np.zeros(n)
        pressure = arr[:, 13] if c > 13 else np.zeros(n)

        dt = np.diff(t, prepend=t[0])
        acc_mag = np.sqrt(acc_x**2 + acc_y**2 + acc_z**2)

        values = {
            2: robust_scale(dt),
            3: minmax01(pressure),
            8: robust_scale(acc_mag),
            11: robust_scale(acc_x),
            12: robust_scale(acc_y),
            13: robust_scale(gyro_x),
            14: robust_scale(gyro_y),
            15: robust_scale(gyro_z),
        }
        for i, v in values.items():
            feat[:, i], mask[:, i] = v, 1.0

    else:
        x = arr[:, 0]
        y = arr[:, 1]

        x = robust_scale(x)
        y = robust_scale(y)

        if c >= 3:
            t_candidate = arr[:, 2]
            monotonic = np.mean(np.diff(t_candidate) >= 0) > 0.75
            t = t_candidate if monotonic else np.arange(n, dtype=np.float32)
        else:
            t = np.arange(n, dtype=np.float32)

        dt = np.diff(t, prepend=t[0])
        positive_dt = dt[dt > 0]
        replacement = np.median(positive_dt) if len(positive_dt) else 1.0
        dt[dt <= 0] = replacement
        dt_scaled = robust_scale(dt)

        dx = np.diff(x, prepend=x[0])
        dy = np.diff(y, prepend=y[0])
        speed = np.sqrt(dx**2 + dy**2) / np.maximum(np.abs(dt), 1e-6)
        acceleration = np.diff(speed, prepend=speed[0]) / np.maximum(np.abs(dt), 1e-6)
        angle = np.arctan2(dy, dx)

        pressure = np.zeros(n, dtype=np.float32)
        touch = np.zeros(n, dtype=np.float32)
        acc_x = np.zeros(n, dtype=np.float32)
        acc_y = np.zeros(n, dtype=np.float32)
        gyro_x = np.zeros(n, dtype=np.float32)
        gyro_y = np.zeros(n, dtype=np.float32)
        gyro_z = np.zeros(n, dtype=np.float32)

        has_pressure = False

        if domain == "mobisig":
            if c > 3:
                pressure, has_pressure = minmax01(arr[:, 3]), True
            if c > 4:
                touch = minmax01(arr[:, 4])
            if c > 7:
                acc_x = robust_scale(arr[:, 7])
            if c > 8:
                acc_y = robust_scale(arr[:, 8])
            if c > 10:
                gyro_x = robust_scale(arr[:, 10])
            if c > 11:
                gyro_y = robust_scale(arr[:, 11])
            if c > 12:
                gyro_z = robust_scale(arr[:, 12])
        elif "task2" in domain and c >= 7:
            pressure, has_pressure = minmax01(arr[:, -1]), True
        elif c >= 4:
            candidate = arr[:, -1]
            if np.nanstd(candidate) > 1e-8:
                pressure, has_pressure = minmax01(candidate), True

        feat[:, 0], mask[:, 0] = x, 1
        feat[:, 1], mask[:, 1] = y, 1
        feat[:, 2], mask[:, 2] = dt_scaled, 1
        feat[:, 5], mask[:, 5] = robust_scale(dx), 1
        feat[:, 6], mask[:, 6] = robust_scale(dy), 1
        feat[:, 7], mask[:, 7] = robust_scale(speed), 1
        feat[:, 8], mask[:, 8] = robust_scale(acceleration), 1
        feat[:, 9], mask[:, 9] = np.sin(angle), 1
        feat[:, 10], mask[:, 10] = np.cos(angle), 1

        if has_pressure:
            feat[:, 3], mask[:, 3] = pressure, 1
        if np.any(touch):
            feat[:, 4], mask[:, 4] = touch, 1
        if np.any(acc_x):
            feat[:, 11], mask[:, 11] = acc_x, 1
        if np.any(acc_y):
            feat[:, 12], mask[:, 12] = acc_y, 1
        if np.any(gyro_x):
            feat[:, 13], mask[:, 13] = gyro_x, 1
        if np.any(gyro_y):
            feat[:, 14], mask[:, 14] = gyro_y, 1
        if np.any(gyro_z):
            feat[:, 15], mask[:, 15] = gyro_z, 1

    has_pressure = float(mask[:, 3].max() > 0)
    meta = np.tile(
        np.array([
            info.get("finger", 0.0),
            info.get("stylus", 0.0),
            has_pressure,
            min(float(info.get("sampling_rate", 0.0)) / 250.0, 2.0),
            min(float(info.get("session", 0.0)) / 5.0, 1.0),
        ], dtype=np.float32),
        (n, 1)
    )

    combined = np.concatenate([feat, mask, meta], axis=1)
    return resample_features(combined, SEQ_LEN)

# ------------------------- Build/cache records -------------------

CACHE_FILE = ROOT / "parsed_sequences_cache.pt"

if CACHE_FILE.exists():
    print("\nLoading parsed sequence cache...")
    records = torch.load(CACHE_FILE, weights_only=False)
else:
    valid_extensions = {
        ".csv", ".txt", ".dat", ".tsv", ".sig", ".svc", ".npy", ".npz"
    }
    files = []
    for root in downloaded_roots:
        if not Path(root).exists():
            continue
        for p in Path(root).rglob("*"):
            if p.is_file() and p.suffix.lower() in valid_extensions:
                files.append(p)
                if len(files) >= MAX_FILES_TO_SCAN:
                    break
        if len(files) >= MAX_FILES_TO_SCAN:
            break

    print(f"\nCandidate sequence files: {len(files):,}")
    records = []
    ssl_count = 0

    for path in tqdm(files, desc="Parsing datasets"):
        info = infer_metadata(path)
        sequences = load_sequences_from_file(path)
        if not sequences:
            continue

        for sub_index, arr in enumerate(sequences):
            seq = canonicalize(arr, info)
            if seq is None:
                continue

            labeled_signature = (
                info["claim"] is not None and
                info["genuine"] is not None
            )

            if not labeled_signature and ssl_count >= MAX_SSL_SAMPLES:
                continue

            records.append({
                "seq": seq.astype(np.float32),
                "domain": info["domain"],
                "claim": info["claim"],
                "genuine": info["genuine"],
                "source": str(path),
                "sub_index": sub_index,
            })

            if not labeled_signature:
                ssl_count += 1

    torch.save(records, CACHE_FILE)

print(f"\nTotal parsed sequences: {len(records):,}")

domain_counts = {}
labeled_counts = {}
for r in records:
    domain_counts[r["domain"]] = domain_counts.get(r["domain"], 0) + 1
    if r["claim"] is not None:
        labeled_counts[r["domain"]] = labeled_counts.get(r["domain"], 0) + 1

print("\nAll parsed data:")
for k, v in sorted(domain_counts.items(), key=lambda x: -x[1]):
    print(f"  {k:24s}: {v:,}")

print("\nLabeled signature data:")
for k, v in sorted(labeled_counts.items(), key=lambda x: -x[1]):
    print(f"  {k:24s}: {v:,}")

labeled_indices = [
    i for i, r in enumerate(records)
    if r["claim"] is not None and r["genuine"] is not None
]

if len(labeled_indices) < 100:
    raise RuntimeError(
        "لم يتم العثور على عدد كافٍ من التوقيعات المصنفة. "
        "تأكد من نجاح تنزيل MOBISIG وSVC2004 أو أضف Dataset إلى /kaggle/input."
    )

# ------------------------- Writer-independent split --------------

claims_by_domain = {}
for i in labeled_indices:
    r = records[i]
    claims_by_domain.setdefault(r["domain"], set()).add(r["claim"])

train_claims, val_claims, test_claims = set(), set(), set()
rng = random.Random(SEED)

for domain, claims in claims_by_domain.items():
    claims = list(claims)
    rng.shuffle(claims)
    n = len(claims)

    n_train = max(1, int(n * 0.70))
    n_val = max(1, int(n * 0.15)) if n >= 5 else 0

    train_claims.update(claims[:n_train])
    val_claims.update(claims[n_train:n_train + n_val])
    test_claims.update(claims[n_train + n_val:])

train_indices = [
    i for i in labeled_indices if records[i]["claim"] in train_claims
]
val_indices = [
    i for i in labeled_indices if records[i]["claim"] in val_claims
]
test_indices = [
    i for i in labeled_indices if records[i]["claim"] in test_claims
]

unlabeled_indices = [
    i for i, r in enumerate(records)
    if r["claim"] is None or r["genuine"] is None
]

ssl_indices = train_indices + unlabeled_indices[:MAX_SSL_SAMPLES]

writer_to_id = {
    claim: i for i, claim in enumerate(sorted(train_claims))
}
domain_to_id = {
    d: i for i, d in enumerate(sorted({r["domain"] for r in records}))
}

print("\nWriter-independent split:")
print("  Train signatures:", len(train_indices), "writers:", len(train_claims))
print("  Validation:", len(val_indices), "writers:", len(val_claims))
print("  Test:", len(test_indices), "writers:", len(test_claims))
print("  SSL total:", len(ssl_indices))
print("  Domains:", len(domain_to_id))


# =====================================================================
# STRONG V2 PIPELINE
# - Balanced SSL instead of letting OnHW dominate the training
# - TCN + BiGRU + local temporal alignment encoder
# - ArcFace writer supervision
# - Skilled/random hard-negative mining
# - Three-model ensemble
# - Five-reference enrollment protocol
# - Validation calibration and secure operating threshold
# - Stable TorchScript and ONNX export
# =====================================================================

ENSEMBLE_SIZE = 3 if FULL_TRAIN else 1
ENROLLMENT_REFS = 5
RANDOM_IMPOSTORS_PER_WRITER = 5
LOCAL_DIM = 160
GRU_HIDDEN = 96
VERIFY_EVAL_EVERY = 2
TARGET_SECURE_FAR = 0.05
MODEL_SEEDS = [2026, 2041, 2063][:ENSEMBLE_SIZE]

# Do not let accidental one-file matches such as iSignDB dominate the domain head.
active_domains = sorted([
    domain for domain, count in domain_counts.items()
    if count >= 100
])
domain_to_id = {domain: i for i, domain in enumerate(active_domains)}
DEFAULT_DOMAIN_ID = domain_to_id.get("OnHW", 0)

def get_domain_id(record):
    return domain_to_id.get(record["domain"], DEFAULT_DOMAIN_ID)

# Balance the SSL pool: signatures are repeated, while OnHW is capped.
ssl_rng = random.Random(SEED)
ssl_signature_indices = list(train_indices)
ssl_handwriting_indices = [
    i for i in unlabeled_indices
    if records[i]["domain"] in {"OnHW", "UNIPEN"}
]
ssl_rng.shuffle(ssl_handwriting_indices)
ssl_handwriting_indices = ssl_handwriting_indices[:MAX_SSL_SAMPLES]
ssl_balanced_indices = (
    ssl_signature_indices * 3
    + ssl_handwriting_indices
)
ssl_rng.shuffle(ssl_balanced_indices)

print("\nStrong-V2 settings:")
print("  Balanced SSL samples:", len(ssl_balanced_indices))
print("  Active domains:", active_domains)
print("  Ensemble models:", ENSEMBLE_SIZE)
print("  Enrollment references:", ENROLLMENT_REFS)
print("  Checkpoints:", CKPT_DIR)

# ------------------------- Reproducibility ------------------------------

def set_all_seeds(seed):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)

set_all_seeds(SEED)

# ------------------------- Augmentation ---------------------------------

def _interpolate_sequence(x, new_length):
    # x: [T,F]
    y = F.interpolate(
        x.transpose(0, 1).unsqueeze(0),
        size=new_length,
        mode="linear",
        align_corners=True,
    )
    return y.squeeze(0).transpose(0, 1)


def augment_sequence_strong(x, strong=False):
    y = x.clone()
    values = y[:, :BASE_FEATURES]
    masks = y[:, BASE_FEATURES:BASE_FEATURES * 2]

    # Small rotation for coordinates and derivatives.
    angle = (torch.rand(1, device=y.device).item() - 0.5) * (0.10 if strong else 0.06)
    c, s = math.cos(angle), math.sin(angle)
    for i, j in [(0, 1), (5, 6)]:
        xi, yi = values[:, i].clone(), values[:, j].clone()
        values[:, i] = c * xi - s * yi
        values[:, j] = s * xi + c * yi

    # Anisotropic spatial scaling.
    sx = 0.88 + torch.rand(1, device=y.device).item() * 0.24
    sy = 0.88 + torch.rand(1, device=y.device).item() * 0.24
    values[:, [0, 5]] *= sx
    values[:, [1, 6]] *= sy
    values[:, 7] *= (sx + sy) * 0.5

    # Jitter only where the channel exists.
    noise_std = 0.020 if strong else 0.012
    values += torch.randn_like(values) * noise_std * masks

    # Random crop followed by interpolation: mild temporal warp.
    if random.random() < (0.65 if strong else 0.35):
        keep_ratio = random.uniform(0.82 if strong else 0.90, 1.0)
        keep = max(24, int(SEQ_LEN * keep_ratio))
        start = random.randint(0, max(0, SEQ_LEN - keep))
        cropped = y[start:start + keep]
        y = _interpolate_sequence(cropped, SEQ_LEN)
        values = y[:, :BASE_FEATURES]
        masks = y[:, BASE_FEATURES:BASE_FEATURES * 2]

    # Block masking.
    if random.random() < (0.55 if strong else 0.30):
        width = random.randint(4, 18 if strong else 10)
        start = random.randint(0, SEQ_LEN - width)
        y[start:start + width, :BASE_FEATURES] = 0.0

    # Modality dropout makes the verifier robust when pressure/sensors are absent.
    sensor_groups = [[3], [4], [11, 12], [13, 14, 15]]
    for group in sensor_groups:
        if random.random() < (0.25 if strong else 0.12):
            y[:, group] = 0.0
            y[:, [BASE_FEATURES + g for g in group]] = 0.0

    return y

# ------------------------- Datasets -------------------------------------

class BalancedSSLDataset(Dataset):
    def __init__(self, indices):
        self.indices = list(indices)

    def __len__(self):
        return len(self.indices)

    def __getitem__(self, index):
        record = records[self.indices[index]]
        sequence = torch.from_numpy(record["seq"]).float()
        writer = -1
        if record["genuine"] is True and record["claim"] in writer_to_id:
            writer = writer_to_id[record["claim"]]
        return sequence, writer, get_domain_id(record)


class StrongQuadrupletDataset(Dataset):
    def __init__(self, indices, seed=SEED):
        self.indices = list(indices)
        self.rng = random.Random(seed)
        self.by_claim_genuine = {}
        self.by_claim_forged = {}
        for idx in self.indices:
            record = records[idx]
            if record["genuine"] is True:
                self.by_claim_genuine.setdefault(record["claim"], []).append(idx)
            elif record["genuine"] is False:
                self.by_claim_forged.setdefault(record["claim"], []).append(idx)

        self.genuine = [
            idx for idx in self.indices
            if records[idx]["genuine"] is True
            and len(self.by_claim_genuine.get(records[idx]["claim"], [])) >= 2
        ]
        self.hard_random_map = {}
        self.hard_skilled_pool = {}

    def __len__(self):
        return max(len(self.genuine) * 4, 2000)

    def set_hard_mining(self, random_map=None, skilled_pool=None):
        self.hard_random_map = random_map or {}
        self.hard_skilled_pool = skilled_pool or {}

    def _random_other_writer(self, claim):
        while True:
            idx = random.choice(self.genuine)
            if records[idx]["claim"] != claim:
                return idx

    def __getitem__(self, index):
        anchor_idx = self.genuine[index % len(self.genuine)]
        claim = records[anchor_idx]["claim"]

        positives = [
            idx for idx in self.by_claim_genuine[claim]
            if idx != anchor_idx
        ]
        positive_idx = random.choice(positives)

        if claim in self.hard_skilled_pool and random.random() < 0.80:
            skilled_idx = random.choice(self.hard_skilled_pool[claim])
        elif self.by_claim_forged.get(claim):
            skilled_idx = random.choice(self.by_claim_forged[claim])
        else:
            skilled_idx = self._random_other_writer(claim)

        if anchor_idx in self.hard_random_map and random.random() < 0.80:
            random_idx = self.hard_random_map[anchor_idx]
        else:
            random_idx = self._random_other_writer(claim)

        def tensor(idx):
            return torch.from_numpy(records[idx]["seq"]).float()

        return (
            tensor(anchor_idx),
            tensor(positive_idx),
            tensor(skilled_idx),
            tensor(random_idx),
            writer_to_id[claim],
            get_domain_id(records[anchor_idx]),
            get_domain_id(records[positive_idx]),
            get_domain_id(records[skilled_idx]),
            get_domain_id(records[random_idx]),
            anchor_idx,
        )

# ------------------------- Strong model ---------------------------------

class TCNBlock(nn.Module):
    def __init__(self, channels, dilation, dropout=0.10):
        super().__init__()
        self.conv1 = nn.Conv1d(
            channels, channels, kernel_size=5,
            padding=2 * dilation, dilation=dilation
        )
        self.norm1 = nn.GroupNorm(8, channels)
        self.conv2 = nn.Conv1d(
            channels, channels, kernel_size=3,
            padding=dilation, dilation=dilation
        )
        self.norm2 = nn.GroupNorm(8, channels)
        self.dropout = nn.Dropout(dropout)
        self.se = nn.Sequential(
            nn.AdaptiveAvgPool1d(1),
            nn.Conv1d(channels, max(channels // 8, 8), 1),
            nn.GELU(),
            nn.Conv1d(max(channels // 8, 8), channels, 1),
            nn.Sigmoid(),
        )

    def forward(self, x):
        residual = x
        y = self.conv1(x)
        y = F.gelu(self.norm1(y))
        y = self.dropout(y)
        y = self.conv2(y)
        y = self.norm2(y)
        y = y * self.se(y)
        return F.gelu(residual + y)


class GradientReverse(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x, strength):
        ctx.strength = strength
        return x.view_as(x)

    @staticmethod
    def backward(ctx, grad_output):
        return -ctx.strength * grad_output, None


class StrongSignatureEncoder(nn.Module):
    def __init__(self, domain_classes):
        super().__init__()
        self.input_projection = nn.Sequential(
            nn.Linear(INPUT_FEATURES, MODEL_DIM),
            nn.LayerNorm(MODEL_DIM),
            nn.GELU(),
        )
        self.tcn = nn.Sequential(
            TCNBlock(MODEL_DIM, 1),
            TCNBlock(MODEL_DIM, 2),
            TCNBlock(MODEL_DIM, 4),
            TCNBlock(MODEL_DIM, 8),
        )
        self.gru = nn.GRU(
            MODEL_DIM,
            GRU_HIDDEN,
            num_layers=2,
            batch_first=True,
            bidirectional=True,
            dropout=0.10,
        )
        self.local_projection = nn.Sequential(
            nn.Linear(GRU_HIDDEN * 2, LOCAL_DIM),
            nn.LayerNorm(LOCAL_DIM),
            nn.GELU(),
        )
        self.attention = nn.Sequential(
            nn.Linear(LOCAL_DIM, LOCAL_DIM // 2),
            nn.Tanh(),
            nn.Linear(LOCAL_DIM // 2, 1),
        )
        self.embedding = nn.Sequential(
            nn.Linear(LOCAL_DIM * 4, EMBED_DIM),
            nn.LayerNorm(EMBED_DIM),
        )
        self.reconstruction_head = nn.Linear(LOCAL_DIM, BASE_FEATURES)
        self.next_step_head = nn.Linear(LOCAL_DIM, BASE_FEATURES)
        self.domain_head = nn.Sequential(
            nn.Linear(EMBED_DIM, 128),
            nn.GELU(),
            nn.Linear(128, max(domain_classes, 1)),
        )

    def forward(self, x):
        h = self.input_projection(x)
        h = self.tcn(h.transpose(1, 2)).transpose(1, 2)
        h, _ = self.gru(h)
        local = self.local_projection(h)

        weights = torch.softmax(self.attention(local), dim=1)
        weighted_mean = torch.sum(local * weights, dim=1)
        centered = local - weighted_mean.unsqueeze(1)
        weighted_std = torch.sqrt(
            torch.sum(centered.pow(2) * weights, dim=1).clamp_min(1e-6)
        )
        ordinary_mean = local.mean(dim=1)
        maximum = local.max(dim=1).values
        pooled = torch.cat(
            [weighted_mean, weighted_std, ordinary_mean, maximum],
            dim=1,
        )
        embedding = F.normalize(self.embedding(pooled), dim=1)
        return embedding, local

    def domain_logits(self, embedding, strength):
        reversed_embedding = GradientReverse.apply(embedding, strength)
        return self.domain_head(reversed_embedding)


class LocalAlignmentComparator(nn.Module):
    def __init__(self):
        super().__init__()
        input_size = EMBED_DIM * 2 + 10
        self.net = nn.Sequential(
            nn.Linear(input_size, 384),
            nn.LayerNorm(384),
            nn.GELU(),
            nn.Dropout(0.15),
            nn.Linear(384, 128),
            nn.LayerNorm(128),
            nn.GELU(),
            nn.Dropout(0.10),
            nn.Linear(128, 1),
        )

    def make_features(self, emb_a, local_a, emb_b, local_b):
        # Downsample before local all-to-all matching.
        la = F.normalize(local_a[:, ::4], dim=-1)
        lb = F.normalize(local_b[:, ::4], dim=-1)
        similarity = torch.bmm(la, lb.transpose(1, 2))
        row_best = similarity.max(dim=2).values
        col_best = similarity.max(dim=1).values
        diagonal = similarity.diagonal(dim1=1, dim2=2)

        cosine = F.cosine_similarity(emb_a, emb_b).unsqueeze(1)
        euclidean = torch.norm(emb_a - emb_b, dim=1, keepdim=True)
        local_stats = torch.stack([
            row_best.mean(dim=1),
            col_best.mean(dim=1),
            row_best.std(dim=1, unbiased=False),
            col_best.std(dim=1, unbiased=False),
            diagonal.mean(dim=1),
            similarity.mean(dim=(1, 2)),
            similarity.amax(dim=(1, 2)),
            similarity.std(dim=(1, 2), unbiased=False),
        ], dim=1)
        return torch.cat([
            torch.abs(emb_a - emb_b),
            emb_a * emb_b,
            cosine,
            euclidean,
            local_stats,
        ], dim=1), cosine.squeeze(1)

    def forward(self, emb_a, local_a, emb_b, local_b):
        features, cosine = self.make_features(emb_a, local_a, emb_b, local_b)
        return self.net(features).squeeze(1), cosine


class ArcMarginProduct(nn.Module):
    def __init__(self, in_features, out_features, scale=24.0, margin=0.28):
        super().__init__()
        self.scale = scale
        self.margin = margin
        self.weight = nn.Parameter(torch.empty(out_features, in_features))
        nn.init.xavier_uniform_(self.weight)

    def forward(self, embeddings, labels):
        with torch.autocast(device_type=embeddings.device.type, enabled=False):
            embeddings = embeddings.float()
            weight = self.weight.float()
            cosine = F.linear(
                F.normalize(embeddings),
                F.normalize(weight)
            ).clamp(-1 + 1e-6, 1 - 1e-6)
            theta = torch.acos(cosine)
            target_cosine = torch.cos(theta + self.margin)
            one_hot = F.one_hot(labels, num_classes=cosine.shape[1]).float()
            logits = cosine * (1.0 - one_hot) + target_cosine * one_hot
            return logits * self.scale

# ------------------------- Numerically safe losses ----------------------

def nt_xent(z1, z2, temperature=0.10):
    with torch.autocast(device_type=z1.device.type, enabled=False):
        z1 = F.normalize(z1.float(), dim=1)
        z2 = F.normalize(z2.float(), dim=1)
        batch = z1.size(0)
        z = torch.cat([z1, z2], dim=0)
        logits = z @ z.t() / temperature
        mask = torch.eye(2 * batch, device=z.device, dtype=torch.bool)
        logits = logits.masked_fill(mask, float("-inf"))
        targets = (torch.arange(2 * batch, device=z.device) + batch) % (2 * batch)
        return F.cross_entropy(logits, targets)


def supervised_contrastive(z, labels, temperature=0.10):
    with torch.autocast(device_type=z.device.type, enabled=False):
        z = F.normalize(z.float(), dim=1)
        labels = labels.long()
        n = z.shape[0]
        similarity = z @ z.t() / temperature
        eye = torch.eye(n, device=z.device, dtype=torch.bool)
        positives = labels[:, None].eq(labels[None, :]) & ~eye
        logits = similarity.masked_fill(eye, float("-inf"))
        log_probability = F.log_softmax(logits, dim=1)
        counts = positives.sum(dim=1)
        valid = counts > 0
        if not valid.any():
            return z.sum() * 0.0
        selected = torch.where(
            positives,
            log_probability,
            torch.zeros_like(log_probability),
        )
        return (-selected.sum(dim=1) / counts.clamp_min(1))[valid].mean()


def focal_binary_loss(logits, targets, gamma=2.0):
    logits = logits.float()
    targets = targets.float()
    bce = F.binary_cross_entropy_with_logits(logits, targets, reduction="none")
    probabilities = torch.sigmoid(logits)
    pt = probabilities * targets + (1.0 - probabilities) * (1.0 - targets)
    return (((1.0 - pt).pow(gamma)) * bce).mean()


def soft_dtw_distance(x, y, gamma=0.10):
    with torch.autocast(device_type=x.device.type, enabled=False):
        x, y = x.float(), y.float()
        distance = torch.cdist(x, y, p=2).pow(2)
        batch, n, m = distance.shape
        large = torch.full((batch,), 1e20, device=x.device)
        matrix = [[None] * (m + 1) for _ in range(n + 1)]
        matrix[0][0] = torch.zeros(batch, device=x.device)
        for i in range(1, n + 1):
            matrix[i][0] = large
        for j in range(1, m + 1):
            matrix[0][j] = large
        for i in range(1, n + 1):
            for j in range(1, m + 1):
                previous = torch.stack([
                    matrix[i - 1][j - 1],
                    matrix[i - 1][j],
                    matrix[i][j - 1],
                ], dim=-1)
                soft_min = -gamma * torch.logsumexp(-previous / gamma, dim=-1)
                matrix[i][j] = distance[:, i - 1, j - 1] + soft_min
        return matrix[n][m]

# ------------------------- Evaluation protocol --------------------------

def build_multi_reference_protocol(indices, refs=ENROLLMENT_REFS, random_impostors=0):
    genuine_by_claim, forged_by_claim = {}, {}
    for idx in indices:
        record = records[idx]
        if record["genuine"] is True:
            genuine_by_claim.setdefault(record["claim"], []).append(idx)
        elif record["genuine"] is False:
            forged_by_claim.setdefault(record["claim"], []).append(idx)

    claims = sorted(genuine_by_claim)
    all_other_genuine = [idx for values in genuine_by_claim.values() for idx in values]
    protocol = []
    local_rng = random.Random(SEED + len(indices) + refs + random_impostors)

    for claim in claims:
        genuine = sorted(
            genuine_by_claim[claim],
            key=lambda idx: (records[idx]["source"], records[idx]["sub_index"]),
        )
        if len(genuine) < 2:
            continue
        number_of_refs = min(refs, len(genuine) - 1)
        references = genuine[:number_of_refs]
        genuine_queries = genuine[number_of_refs:]

        for query in genuine_queries:
            protocol.append({
                "claim": claim,
                "references": references,
                "query": query,
                "label": 1,
                "kind": "genuine",
                "domain": records[query]["domain"],
            })

        for query in forged_by_claim.get(claim, []):
            protocol.append({
                "claim": claim,
                "references": references,
                "query": query,
                "label": 0,
                "kind": "skilled",
                "domain": records[query]["domain"],
            })

        if random_impostors > 0:
            alternatives = [
                idx for idx in all_other_genuine
                if records[idx]["claim"] != claim
            ]
            for query in local_rng.sample(
                alternatives,
                min(random_impostors, len(alternatives)),
            ):
                protocol.append({
                    "claim": claim,
                    "references": references,
                    "query": query,
                    "label": 0,
                    "kind": "random",
                    "domain": records[query]["domain"],
                })
    return protocol


def calculate_metrics(labels, scores, threshold=None):
    labels = np.asarray(labels, dtype=np.int64)
    scores = np.asarray(scores, dtype=np.float64)
    if len(np.unique(labels)) < 2:
        return {
            "auc": None, "eer": None, "threshold": 0.5,
            "far": None, "frr": None, "accuracy": None,
        }
    fpr, tpr, thresholds = roc_curve(labels, scores)
    fnr = 1.0 - tpr
    position = int(np.nanargmin(np.abs(fpr - fnr)))
    eer = float((fpr[position] + fnr[position]) * 0.5)
    if threshold is None:
        threshold = float(thresholds[position])
    predictions = (scores >= threshold).astype(np.int64)
    negative = labels == 0
    positive = labels == 1
    return {
        "auc": float(roc_auc_score(labels, scores)),
        "eer": eer,
        "threshold": float(threshold),
        "far": float(np.mean(predictions[negative] == 1)) if negative.any() else None,
        "frr": float(np.mean(predictions[positive] == 0)) if positive.any() else None,
        "accuracy": float(accuracy_score(labels, predictions)),
    }


def threshold_for_target_far(labels, scores, target_far=TARGET_SECURE_FAR):
    labels = np.asarray(labels)
    scores = np.asarray(scores)
    negatives = scores[labels == 0]
    positives = scores[labels == 1]
    candidates = np.unique(np.concatenate([scores, [1.0, 0.0]]))[::-1]
    best = 1.0
    best_frr = 1.0
    for threshold in candidates:
        far = float(np.mean(negatives >= threshold)) if len(negatives) else 0.0
        frr = float(np.mean(positives < threshold)) if len(positives) else 1.0
        if far <= target_far and frr <= best_frr:
            best, best_frr = float(threshold), frr
    return best


def trimmed_reference_mean(values):
    # values: [K]. K is normally five.
    if values.numel() >= 3:
        return (values.sum() - values.max() - values.min()) / (values.numel() - 2)
    return values.mean()


@torch.no_grad()
def score_protocol_single_model(encoder, comparator, protocol, query_batch_size=96):
    encoder.eval()
    comparator.eval()
    grouped = {}
    for position, item in enumerate(protocol):
        grouped.setdefault(item["claim"], []).append((position, item))

    logits_out = np.zeros(len(protocol), dtype=np.float32)
    cosine_out = np.zeros(len(protocol), dtype=np.float32)

    for claim, entries in grouped.items():
        references = entries[0][1]["references"]
        reference_batch = torch.stack([
            torch.from_numpy(records[idx]["seq"]).float()
            for idx in references
        ]).to(DEVICE)
        ref_embedding, ref_local = encoder(reference_batch)
        number_of_references = reference_batch.shape[0]

        for chunk_start in range(0, len(entries), query_batch_size):
            chunk = entries[chunk_start:chunk_start + query_batch_size]
            query_batch = torch.stack([
                torch.from_numpy(records[item["query"]]["seq"]).float()
                for _, item in chunk
            ]).to(DEVICE)
            query_embedding, query_local = encoder(query_batch)
            number_of_queries = query_batch.shape[0]

            expanded_ref_embedding = ref_embedding.unsqueeze(0).expand(
                number_of_queries, -1, -1
            ).reshape(number_of_queries * number_of_references, -1)
            expanded_ref_local = ref_local.unsqueeze(0).expand(
                number_of_queries, -1, -1, -1
            ).reshape(
                number_of_queries * number_of_references,
                ref_local.shape[1],
                ref_local.shape[2],
            )
            expanded_query_embedding = query_embedding.unsqueeze(1).expand(
                -1, number_of_references, -1
            ).reshape(number_of_queries * number_of_references, -1)
            expanded_query_local = query_local.unsqueeze(1).expand(
                -1, number_of_references, -1, -1
            ).reshape(
                number_of_queries * number_of_references,
                query_local.shape[1],
                query_local.shape[2],
            )

            pair_logits, pair_cosine = comparator(
                expanded_ref_embedding,
                expanded_ref_local,
                expanded_query_embedding,
                expanded_query_local,
            )
            pair_logits = pair_logits.reshape(number_of_queries, number_of_references)
            pair_cosine = pair_cosine.reshape(number_of_queries, number_of_references)

            if number_of_references >= 3:
                aggregate_logits = (
                    pair_logits.sum(dim=1)
                    - pair_logits.max(dim=1).values
                    - pair_logits.min(dim=1).values
                ) / (number_of_references - 2)
                aggregate_cosine = (
                    pair_cosine.sum(dim=1)
                    - pair_cosine.max(dim=1).values
                    - pair_cosine.min(dim=1).values
                ) / (number_of_references - 2)
            else:
                aggregate_logits = pair_logits.mean(dim=1)
                aggregate_cosine = pair_cosine.mean(dim=1)

            for local_position, (original_position, _) in enumerate(chunk):
                logits_out[original_position] = float(aggregate_logits[local_position].cpu())
                cosine_out[original_position] = float(aggregate_cosine[local_position].cpu())

    return logits_out, cosine_out

# ------------------------- Stage 1: balanced SSL ------------------------

PRETRAIN_CHECKPOINT = CKPT_DIR / "strong_v2_pretrain.pt"

if PRETRAIN_CHECKPOINT.exists():
    print("\nLoading Strong-V2 pretraining checkpoint...")
    pretrain_state = torch.load(PRETRAIN_CHECKPOINT, map_location="cpu", weights_only=False)
else:
    print("\n" + "=" * 76)
    print("STAGE A: BALANCED SELF-SUPERVISED PRETRAINING")
    print("=" * 76)

    pretrain_encoder = StrongSignatureEncoder(len(domain_to_id)).to(DEVICE)
    pretrain_arcface = ArcMarginProduct(
        EMBED_DIM, max(len(writer_to_id), 1)
    ).to(DEVICE)
    ssl_dataset = BalancedSSLDataset(ssl_balanced_indices)
    ssl_loader = DataLoader(
        ssl_dataset,
        batch_size=SSL_BATCH,
        shuffle=True,
        num_workers=NUM_WORKERS,
        pin_memory=AMP,
        drop_last=True,
    )
    optimizer = torch.optim.AdamW(
        list(pretrain_encoder.parameters()) + list(pretrain_arcface.parameters()),
        lr=LEARNING_RATE,
        weight_decay=WEIGHT_DECAY,
    )
    scheduler = torch.optim.lr_scheduler.OneCycleLR(
        optimizer,
        max_lr=LEARNING_RATE,
        epochs=SSL_EPOCHS,
        steps_per_epoch=len(ssl_loader),
        pct_start=0.12,
        div_factor=10.0,
        final_div_factor=50.0,
    )
    scaler = torch.cuda.amp.GradScaler(enabled=AMP)

    for epoch in range(SSL_EPOCHS):
        pretrain_encoder.train()
        pretrain_arcface.train()
        running = []
        progress = tqdm(ssl_loader, desc=f"Balanced SSL {epoch + 1}/{SSL_EPOCHS}")
        for sequences, writers, domains in progress:
            sequences = sequences.to(DEVICE, non_blocking=True)
            writers = writers.to(DEVICE, non_blocking=True)

            view1 = torch.stack([
                augment_sequence_strong(sequence, strong=False)
                for sequence in sequences
            ])
            view2 = torch.stack([
                augment_sequence_strong(sequence, strong=True)
                for sequence in sequences
            ])

            mask = torch.rand(
                sequences.shape[0], sequences.shape[1], 1,
                device=DEVICE,
            ) < 0.18
            masked = sequences.clone()
            masked[:, :, :BASE_FEATURES] = masked[:, :, :BASE_FEATURES].masked_fill(mask, 0.0)

            optimizer.zero_grad(set_to_none=True)
            with torch.cuda.amp.autocast(enabled=AMP):
                masked_embedding, masked_local = pretrain_encoder(masked)
                embedding1, _ = pretrain_encoder(view1)
                embedding2, _ = pretrain_encoder(view2)

                reconstructed = pretrain_encoder.reconstruction_head(masked_local)
                reconstruction_error = (
                    reconstructed - sequences[:, :, :BASE_FEATURES]
                ).pow(2)
                reconstruction_loss = (
                    reconstruction_error * mask.float()
                ).sum() / (mask.float().sum() * BASE_FEATURES + 1e-6)

                predicted_next = pretrain_encoder.next_step_head(masked_local[:, :-1])
                next_loss = F.smooth_l1_loss(
                    predicted_next,
                    sequences[:, 1:, :BASE_FEATURES],
                )
                contrastive_loss = nt_xent(embedding1, embedding2)

                valid = writers >= 0
                if valid.any():
                    writer_logits = pretrain_arcface(masked_embedding[valid], writers[valid])
                    writer_loss = F.cross_entropy(writer_logits, writers[valid])
                else:
                    writer_loss = masked_embedding.sum() * 0.0

                loss = (
                    1.00 * reconstruction_loss
                    + 0.35 * next_loss
                    + 1.00 * contrastive_loss
                    + 0.30 * writer_loss
                )

            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(
                list(pretrain_encoder.parameters()) + list(pretrain_arcface.parameters()),
                1.0,
            )
            scaler.step(optimizer)
            scaler.update()
            scheduler.step()

            running.append(float(loss.detach().cpu()))
            progress.set_postfix(loss=np.mean(running[-30:]))

        torch.save({
            "encoder": pretrain_encoder.state_dict(),
            "arcface": pretrain_arcface.state_dict(),
            "epoch": epoch + 1,
        }, CKPT_DIR / "strong_v2_pretrain_progress.pt")

    pretrain_state = {
        "encoder": {k: v.detach().cpu() for k, v in pretrain_encoder.state_dict().items()},
        "arcface": {k: v.detach().cpu() for k, v in pretrain_arcface.state_dict().items()},
    }
    torch.save(pretrain_state, PRETRAIN_CHECKPOINT)
    del pretrain_encoder, pretrain_arcface, ssl_loader
    torch.cuda.empty_cache()

# ------------------------- Hard mining ----------------------------------

@torch.no_grad()
def mine_hard_examples(encoder, comparator, dataset):
    encoder.eval()
    comparator.eval()

    genuine_indices = dataset.genuine
    all_indices = genuine_indices + [
        idx for claim in dataset.by_claim_forged
        for idx in dataset.by_claim_forged[claim]
    ]
    embeddings = {}
    loader = DataLoader(
        [torch.from_numpy(records[idx]["seq"]).float() for idx in all_indices],
        batch_size=128,
        shuffle=False,
        num_workers=0,
    )
    position = 0
    for batch in loader:
        batch = batch.to(DEVICE)
        embedding, local = encoder(batch)
        for j in range(batch.shape[0]):
            idx = all_indices[position + j]
            embeddings[idx] = embedding[j].detach().cpu()
        position += batch.shape[0]

    genuine_matrix = F.normalize(
        torch.stack([embeddings[idx] for idx in genuine_indices]),
        dim=1,
    ).to(DEVICE)
    claims = [records[idx]["claim"] for idx in genuine_indices]
    hard_random_map = {}
    chunk_size = 384
    for start in range(0, len(genuine_indices), chunk_size):
        end = min(start + chunk_size, len(genuine_indices))
        similarity = genuine_matrix[start:end] @ genuine_matrix.t()
        for local_row, global_row in enumerate(range(start, end)):
            invalid = torch.tensor(
                [claim == claims[global_row] for claim in claims],
                device=DEVICE,
                dtype=torch.bool,
            )
            similarity[local_row, invalid] = torch.finfo(similarity.dtype).min
        nearest = similarity.argmax(dim=1).cpu().tolist()
        for source_position, target_position in zip(range(start, end), nearest):
            hard_random_map[genuine_indices[source_position]] = genuine_indices[target_position]

    hard_skilled_pool = {}
    for claim, forged_indices in dataset.by_claim_forged.items():
        genuine_claim = dataset.by_claim_genuine.get(claim, [])
        if not genuine_claim or not forged_indices:
            continue
        centroid = F.normalize(
            torch.stack([embeddings[idx] for idx in genuine_claim]).mean(dim=0),
            dim=0,
        )
        ranked = sorted(
            forged_indices,
            key=lambda idx: float(F.cosine_similarity(
                centroid.unsqueeze(0), embeddings[idx].unsqueeze(0)
            )),
            reverse=True,
        )
        hard_skilled_pool[claim] = ranked[:min(8, len(ranked))]

    return hard_random_map, hard_skilled_pool

# ------------------------- Ensemble fine-tuning -------------------------

val_protocol_skilled = build_multi_reference_protocol(
    val_indices,
    refs=ENROLLMENT_REFS,
    random_impostors=0,
)

trained_model_paths = []

for model_number, model_seed in enumerate(MODEL_SEEDS, start=1):
    model_path = CKPT_DIR / f"strong_v2_model_{model_number}.pt"
    trained_model_paths.append(model_path)

    if model_path.exists():
        print(f"\nEnsemble model {model_number} already trained; loading checkpoint later.")
        continue

    print("\n" + "=" * 76)
    print(f"STAGE B{model_number}: STRONG VERIFICATION MODEL — SEED {model_seed}")
    print("=" * 76)
    set_all_seeds(model_seed)

    encoder = StrongSignatureEncoder(len(domain_to_id)).to(DEVICE)
    encoder.load_state_dict(pretrain_state["encoder"], strict=True)
    comparator = LocalAlignmentComparator().to(DEVICE)
    arcface = ArcMarginProduct(
        EMBED_DIM, max(len(writer_to_id), 1)
    ).to(DEVICE)
    if "arcface" in pretrain_state:
        arcface.load_state_dict(pretrain_state["arcface"], strict=False)

    train_dataset = StrongQuadrupletDataset(train_indices, seed=model_seed)
    train_loader = DataLoader(
        train_dataset,
        batch_size=PAIR_BATCH,
        shuffle=True,
        num_workers=NUM_WORKERS,
        pin_memory=AMP,
        drop_last=True,
    )

    optimizer = torch.optim.AdamW([
        {"params": encoder.parameters(), "lr": LEARNING_RATE * 0.65},
        {"params": comparator.parameters(), "lr": LEARNING_RATE * 1.40},
        {"params": arcface.parameters(), "lr": LEARNING_RATE},
    ], weight_decay=WEIGHT_DECAY)
    scheduler = torch.optim.lr_scheduler.OneCycleLR(
        optimizer,
        max_lr=[
            LEARNING_RATE * 0.65,
            LEARNING_RATE * 1.40,
            LEARNING_RATE,
        ],
        epochs=VERIFY_EPOCHS,
        steps_per_epoch=len(train_loader),
        pct_start=0.10,
        div_factor=8.0,
        final_div_factor=80.0,
    )
    scaler = torch.cuda.amp.GradScaler(enabled=AMP)

    best_eer = float("inf")
    best_state = None
    global_step = 0

    for epoch in range(VERIFY_EPOCHS):
        if epoch == 0 or epoch % HARD_MINE_EVERY == 0:
            hard_random, hard_skilled = mine_hard_examples(
                encoder, comparator, train_dataset
            )
            train_dataset.set_hard_mining(hard_random, hard_skilled)

        encoder.train()
        comparator.train()
        arcface.train()
        running = []
        domain_strength = 0.08 * min(1.0, (epoch + 1) / 10.0)
        progress = tqdm(
            train_loader,
            desc=f"Strong {model_number} epoch {epoch + 1}/{VERIFY_EPOCHS}",
        )

        for batch in progress:
            (
                anchor, positive, skilled, random_negative,
                writers, da, dp, ds, dr, anchor_indices,
            ) = batch
            anchor = anchor.to(DEVICE, non_blocking=True)
            positive = positive.to(DEVICE, non_blocking=True)
            skilled = skilled.to(DEVICE, non_blocking=True)
            random_negative = random_negative.to(DEVICE, non_blocking=True)
            writers = writers.to(DEVICE)
            domains = torch.cat([
                da.to(DEVICE), dp.to(DEVICE), ds.to(DEVICE), dr.to(DEVICE)
            ])

            # Separate augmentations improve generalization without changing labels.
            anchor_aug = torch.stack([
                augment_sequence_strong(x, strong=False) for x in anchor
            ])
            positive_aug = torch.stack([
                augment_sequence_strong(x, strong=False) for x in positive
            ])

            optimizer.zero_grad(set_to_none=True)
            with torch.cuda.amp.autocast(enabled=AMP):
                combined = torch.cat([
                    anchor_aug, positive_aug, skilled, random_negative
                ], dim=0)
                all_embedding, all_local = encoder(combined)
                batch_size = anchor.shape[0]
                ea, ep, es, er = all_embedding.split(batch_size)
                la, lp, ls, lr = all_local.split(batch_size)

                positive_logits, _ = comparator(ea, la, ep, lp)
                skilled_logits, _ = comparator(ea, la, es, ls)
                random_logits, _ = comparator(ea, la, er, lr)

                pair_logits = torch.cat([
                    positive_logits, skilled_logits, random_logits
                ])
                pair_targets = torch.cat([
                    torch.full_like(positive_logits, 0.97),
                    torch.full_like(skilled_logits, 0.02),
                    torch.full_like(random_logits, 0.02),
                ])
                verification_loss = focal_binary_loss(
                    pair_logits, pair_targets, gamma=2.0
                )

                triplet_skilled = F.triplet_margin_loss(
                    ea.float(), ep.float(), es.float(), margin=0.35, p=2
                )
                triplet_random = F.triplet_margin_loss(
                    ea.float(), ep.float(), er.float(), margin=0.45, p=2
                )
                supcon_loss = supervised_contrastive(
                    torch.cat([ea, ep], dim=0),
                    torch.cat([writers, writers], dim=0),
                )

                arc_logits_a = arcface(ea, writers)
                arc_logits_p = arcface(ep, writers)
                writer_loss = 0.5 * (
                    F.cross_entropy(arc_logits_a.float(), writers)
                    + F.cross_entropy(arc_logits_p.float(), writers)
                )

                cosine_positive = F.cosine_similarity(ea, ep)
                cosine_skilled = F.cosine_similarity(ea, es)
                cosine_random = F.cosine_similarity(ea, er)
                cosine_margin_loss = (
                    F.relu(0.65 - cosine_positive).mean()
                    + F.relu(cosine_skilled - 0.35).mean()
                    + F.relu(cosine_random - 0.20).mean()
                )

                domain_loss = F.cross_entropy(
                    encoder.domain_logits(all_embedding, domain_strength).float(),
                    domains,
                )

                dtw_loss = ea.sum() * 0.0
                if global_step % SOFT_DTW_EVERY == 0:
                    subset = min(SOFT_DTW_SUBSET, batch_size)
                    positive_dtw = soft_dtw_distance(
                        la[:subset, ::8, :32], lp[:subset, ::8, :32]
                    )
                    skilled_dtw = soft_dtw_distance(
                        la[:subset, ::8, :32], ls[:subset, ::8, :32]
                    )
                    dtw_loss = F.relu(
                        positive_dtw - skilled_dtw + 0.40
                    ).mean()

                loss = (
                    1.70 * verification_loss
                    + 0.55 * triplet_skilled
                    + 0.45 * triplet_random
                    + 0.35 * supcon_loss
                    + 0.35 * writer_loss
                    + 0.25 * cosine_margin_loss
                    + 0.04 * domain_loss
                    + 0.08 * dtw_loss
                )

            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(
                list(encoder.parameters())
                + list(comparator.parameters())
                + list(arcface.parameters()),
                1.0,
            )
            scaler.step(optimizer)
            scaler.update()
            scheduler.step()

            global_step += 1
            running.append(float(loss.detach().cpu()))
            progress.set_postfix(loss=np.mean(running[-30:]))

        if (epoch + 1) % VERIFY_EVAL_EVERY == 0 or epoch + 1 == VERIFY_EPOCHS:
            validation_logits, _ = score_protocol_single_model(
                encoder, comparator, val_protocol_skilled
            )
            validation_scores = 1.0 / (1.0 + np.exp(-np.clip(validation_logits, -30, 30)))
            validation_labels = [item["label"] for item in val_protocol_skilled]
            validation_metrics = calculate_metrics(
                validation_labels, validation_scores
            )
            print(
                f"Model {model_number} validation: "
                f"AUC={validation_metrics['auc']:.4f}, "
                f"EER={validation_metrics['eer']:.4f}"
            )
            if validation_metrics["eer"] < best_eer:
                best_eer = validation_metrics["eer"]
                best_state = {
                    "encoder": {k: v.detach().cpu() for k, v in encoder.state_dict().items()},
                    "comparator": {k: v.detach().cpu() for k, v in comparator.state_dict().items()},
                    "arcface": {k: v.detach().cpu() for k, v in arcface.state_dict().items()},
                    "validation_metrics": validation_metrics,
                    "epoch": epoch + 1,
                    "seed": model_seed,
                }

    if best_state is None:
        best_state = {
            "encoder": encoder.state_dict(),
            "comparator": comparator.state_dict(),
            "arcface": arcface.state_dict(),
            "epoch": VERIFY_EPOCHS,
            "seed": model_seed,
        }
    torch.save(best_state, model_path)
    print(f"Saved best ensemble model {model_number}: {model_path}")
    del encoder, comparator, arcface, train_loader, train_dataset
    torch.cuda.empty_cache()

# ------------------------- Load ensemble --------------------------------

ensemble_encoders = []
ensemble_comparators = []
individual_validation = []
for model_path in trained_model_paths:
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    encoder = StrongSignatureEncoder(len(domain_to_id)).to(DEVICE)
    comparator = LocalAlignmentComparator().to(DEVICE)
    encoder.load_state_dict(state["encoder"])
    comparator.load_state_dict(state["comparator"])
    encoder.eval()
    comparator.eval()
    ensemble_encoders.append(encoder)
    ensemble_comparators.append(comparator)
    individual_validation.append(state.get("validation_metrics"))

# ------------------------- Calibration and final evaluation -------------

from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

val_protocol_combined = build_multi_reference_protocol(
    val_indices,
    refs=ENROLLMENT_REFS,
    random_impostors=RANDOM_IMPOSTORS_PER_WRITER,
)
test_protocol_skilled = build_multi_reference_protocol(
    test_indices,
    refs=ENROLLMENT_REFS,
    random_impostors=0,
)
test_protocol_combined = build_multi_reference_protocol(
    test_indices,
    refs=ENROLLMENT_REFS,
    random_impostors=RANDOM_IMPOSTORS_PER_WRITER,
)


def ensemble_feature_matrix(protocol):
    model_logits, model_cosines = [], []
    for encoder, comparator in zip(ensemble_encoders, ensemble_comparators):
        logits, cosines = score_protocol_single_model(
            encoder, comparator, protocol
        )
        model_logits.append(logits)
        model_cosines.append(cosines)
    logits = np.stack(model_logits, axis=1)
    cosines = np.stack(model_cosines, axis=1)
    features = np.concatenate([
        logits,
        cosines,
        logits.mean(axis=1, keepdims=True),
        logits.std(axis=1, keepdims=True),
        logits.max(axis=1, keepdims=True),
        logits.min(axis=1, keepdims=True),
        cosines.mean(axis=1, keepdims=True),
        cosines.std(axis=1, keepdims=True),
        cosines.max(axis=1, keepdims=True),
        cosines.min(axis=1, keepdims=True),
    ], axis=1).astype(np.float64)
    labels = np.asarray([item["label"] for item in protocol], dtype=np.int64)
    kinds = np.asarray([item["kind"] for item in protocol])
    domains = np.asarray([item["domain"] for item in protocol])
    return features, labels, kinds, domains


val_features_combined, val_labels_combined, val_kinds, val_domains = ensemble_feature_matrix(
    val_protocol_combined
)
scaler_calibration = StandardScaler().fit(val_features_combined)
calibrator = LogisticRegression(
    C=0.25,
    class_weight="balanced",
    max_iter=5000,
    random_state=SEED,
).fit(
    scaler_calibration.transform(val_features_combined),
    val_labels_combined,
)

# Thresholds are selected on skilled forgeries only, not on easier random impostors.
val_features_skilled, val_labels_skilled, _, _ = ensemble_feature_matrix(
    val_protocol_skilled
)
val_probabilities = calibrator.predict_proba(
    scaler_calibration.transform(val_features_skilled)
)[:, 1]
val_metrics = calculate_metrics(val_labels_skilled, val_probabilities)
eer_threshold = val_metrics["threshold"]
secure_threshold = threshold_for_target_far(
    val_labels_skilled, val_probabilities, TARGET_SECURE_FAR
)
val_secure_metrics = calculate_metrics(
    val_labels_skilled, val_probabilities, threshold=secure_threshold
)


def evaluate_final(protocol, threshold):
    features, labels, kinds, domains = ensemble_feature_matrix(protocol)
    probabilities = calibrator.predict_proba(
        scaler_calibration.transform(features)
    )[:, 1]
    metrics = calculate_metrics(labels, probabilities, threshold=threshold)
    return features, labels, kinds, domains, probabilities, metrics


_, test_skilled_labels, test_skilled_kinds, test_skilled_domains, test_skilled_probabilities, test_skilled_metrics = evaluate_final(
    test_protocol_skilled, eer_threshold
)
_, test_combined_labels, test_combined_kinds, test_combined_domains, test_combined_probabilities, test_combined_metrics = evaluate_final(
    test_protocol_combined, eer_threshold
)
test_skilled_secure = calculate_metrics(
    test_skilled_labels,
    test_skilled_probabilities,
    threshold=secure_threshold,
)
test_combined_secure = calculate_metrics(
    test_combined_labels,
    test_combined_probabilities,
    threshold=secure_threshold,
)

print("\n" + "=" * 76)
print("STRONG-V2 VALIDATION — FIVE REFERENCES")
print(json.dumps(val_metrics, indent=2))
print("\nVALIDATION AT SECURE THRESHOLD")
print(json.dumps(val_secure_metrics, indent=2))
print("\nTEST — SKILLED FORGERIES ONLY")
print(json.dumps(test_skilled_metrics, indent=2))
print("\nTEST — SKILLED + RANDOM FORGERIES")
print(json.dumps(test_combined_metrics, indent=2))
print("\nTEST SECURE OPERATING POINT — SKILLED")
print(json.dumps(test_skilled_secure, indent=2))
print("\nTEST SECURE OPERATING POINT — COMBINED")
print(json.dumps(test_combined_secure, indent=2))
print("=" * 76)

# Per-domain report without changing the global threshold.
per_domain_metrics = {}
for domain in sorted(set(test_combined_domains.tolist())):
    selected = test_combined_domains == domain
    if selected.sum() >= 10 and len(np.unique(test_combined_labels[selected])) == 2:
        per_domain_metrics[domain] = calculate_metrics(
            test_combined_labels[selected],
            test_combined_probabilities[selected],
            threshold=eer_threshold,
        )
print("\nPer-domain test metrics:")
print(json.dumps(per_domain_metrics, indent=2))

# ------------------------- Exportable ensemble ---------------------------

class CalibratedEnsembleVerifier(nn.Module):
    def __init__(
        self,
        encoders,
        comparators,
        scaler_mean,
        scaler_scale,
        coefficients,
        intercept,
    ):
        super().__init__()
        self.encoders = nn.ModuleList(encoders)
        self.comparators = nn.ModuleList(comparators)
        self.register_buffer(
            "scaler_mean",
            torch.tensor(scaler_mean, dtype=torch.float32),
        )
        self.register_buffer(
            "scaler_scale",
            torch.tensor(scaler_scale, dtype=torch.float32),
        )
        self.register_buffer(
            "coefficients",
            torch.tensor(coefficients, dtype=torch.float32),
        )
        self.register_buffer(
            "intercept",
            torch.tensor(intercept, dtype=torch.float32),
        )

    @staticmethod
    def trimmed_mean(values):
        # Export model expects exactly five references.
        return (
            values.sum(dim=1)
            - values.max(dim=1).values
            - values.min(dim=1).values
        ) / 3.0

    def forward(self, reference_sequences, query_sequence):
        # reference_sequences: [B,5,T,F]
        batch, number_of_references, length, features = reference_sequences.shape
        flat_references = reference_sequences.reshape(
            batch * number_of_references, length, features
        )
        model_logits = []
        model_cosines = []
        for encoder, comparator in zip(self.encoders, self.comparators):
            ref_embedding, ref_local = encoder(flat_references)
            query_embedding, query_local = encoder(query_sequence)
            query_embedding = query_embedding.unsqueeze(1).expand(
                -1, number_of_references, -1
            ).reshape(batch * number_of_references, -1)
            query_local = query_local.unsqueeze(1).expand(
                -1, number_of_references, -1, -1
            ).reshape(batch * number_of_references, query_local.shape[1], query_local.shape[2])
            logits, cosines = comparator(
                ref_embedding, ref_local, query_embedding, query_local
            )
            logits = logits.reshape(batch, number_of_references)
            cosines = cosines.reshape(batch, number_of_references)
            model_logits.append(self.trimmed_mean(logits))
            model_cosines.append(self.trimmed_mean(cosines))

        logits = torch.stack(model_logits, dim=1)
        cosines = torch.stack(model_cosines, dim=1)
        logit_mean = logits.mean(dim=1, keepdim=True)
        cosine_mean = cosines.mean(dim=1, keepdim=True)
        features_vector = torch.cat([
            logits,
            cosines,
            logit_mean,
            torch.sqrt(((logits - logit_mean) ** 2).mean(dim=1, keepdim=True) + 1e-8),
            logits.max(dim=1, keepdim=True).values,
            logits.min(dim=1, keepdim=True).values,
            cosine_mean,
            torch.sqrt(((cosines - cosine_mean) ** 2).mean(dim=1, keepdim=True) + 1e-8),
            cosines.max(dim=1, keepdim=True).values,
            cosines.min(dim=1, keepdim=True).values,
        ], dim=1)
        normalized = (features_vector - self.scaler_mean) / self.scaler_scale.clamp_min(1e-6)
        calibrated_logit = normalized @ self.coefficients.t() + self.intercept
        probability = torch.sigmoid(calibrated_logit)
        return torch.cat([
            probability,
            calibrated_logit,
            cosine_mean,
        ], dim=1)

# Export on CPU for stability.
export_encoders = []
export_comparators = []
for model_path in trained_model_paths:
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    encoder = StrongSignatureEncoder(len(domain_to_id)).cpu().eval()
    comparator = LocalAlignmentComparator().cpu().eval()
    encoder.load_state_dict(state["encoder"])
    comparator.load_state_dict(state["comparator"])
    export_encoders.append(encoder)
    export_comparators.append(comparator)

ensemble_deployment = CalibratedEnsembleVerifier(
    export_encoders,
    export_comparators,
    scaler_calibration.mean_,
    scaler_calibration.scale_,
    calibrator.coef_,
    calibrator.intercept_,
).cpu().eval()

# Save full checkpoint.
CHECKPOINT_FILE = EXPORT_DIR / "global_signature_strong_v2_checkpoint.pt"
torch.save({
    "models": [
        torch.load(path, map_location="cpu", weights_only=False)
        for path in trained_model_paths
    ],
    "calibration": {
        "scaler_mean": scaler_calibration.mean_.tolist(),
        "scaler_scale": scaler_calibration.scale_.tolist(),
        "coefficients": calibrator.coef_.tolist(),
        "intercept": calibrator.intercept_.tolist(),
    },
    "thresholds": {
        "eer_threshold": float(eer_threshold),
        "secure_threshold": float(secure_threshold),
        "target_secure_far": TARGET_SECURE_FAR,
    },
    "metrics": {
        "validation": val_metrics,
        "validation_secure": val_secure_metrics,
        "test_skilled": test_skilled_metrics,
        "test_combined": test_combined_metrics,
        "test_skilled_secure": test_skilled_secure,
        "test_combined_secure": test_combined_secure,
        "per_domain": per_domain_metrics,
    },
    "config": {
        "sequence_length": SEQ_LEN,
        "input_features": INPUT_FEATURES,
        "enrollment_references": ENROLLMENT_REFS,
        "ensemble_size": ENSEMBLE_SIZE,
        "writer_independent": True,
        "active_domains": active_domains,
    },
}, CHECKPOINT_FILE)

example_references = torch.zeros(
    1, ENROLLMENT_REFS, SEQ_LEN, INPUT_FEATURES,
    dtype=torch.float32,
)
example_query = torch.zeros(
    1, SEQ_LEN, INPUT_FEATURES,
    dtype=torch.float32,
)

TORCHSCRIPT_FILE = EXPORT_DIR / "global_signature_strong_v2_torchscript.pt"
ONNX_FILE = EXPORT_DIR / "global_signature_strong_v2.onnx"

try:
    with torch.inference_mode():
        traced = torch.jit.trace(
            ensemble_deployment,
            (example_references, example_query),
            check_trace=False,
            strict=False,
        )
        traced = torch.jit.freeze(traced)
        traced.save(str(TORCHSCRIPT_FILE))
    print("TorchScript export: OK")
except Exception as error:
    print("TorchScript export failed:", repr(error))

try:
    pip_install(["onnxscript"])
    import onnx
    import onnxruntime as ort
    with torch.inference_mode():
        torch.onnx.export(
            ensemble_deployment,
            (example_references, example_query),
            str(ONNX_FILE),
            input_names=["reference_sequences", "query_sequence"],
            output_names=["verification_output"],
            dynamic_axes={
                "reference_sequences": {0: "batch"},
                "query_sequence": {0: "batch"},
                "verification_output": {0: "batch"},
            },
            opset_version=17,
            do_constant_folding=True,
            dynamo=False,
        )
    onnx_model = onnx.load(str(ONNX_FILE))
    onnx.checker.check_model(onnx_model)
    session = ort.InferenceSession(
        str(ONNX_FILE), providers=["CPUExecutionProvider"]
    )
    output = session.run(None, {
        "reference_sequences": example_references.numpy(),
        "query_sequence": example_query.numpy(),
    })[0]
    if not np.isfinite(output).all():
        raise RuntimeError("ONNX Runtime produced non-finite output")
    print("ONNX export and runtime validation: OK")
except Exception as error:
    print("ONNX export failed:", repr(error))

feature_names = [
    "x", "y", "delta_time", "pressure", "touch_area",
    "delta_x", "delta_y", "speed", "acceleration",
    "sin_direction", "cos_direction",
    "accelerometer_x", "accelerometer_y",
    "gyroscope_x", "gyroscope_y", "gyroscope_z",
]

MODEL_CONFIG_FILE = EXPORT_DIR / "model_config.json"
MODEL_CONFIG_FILE.write_text(json.dumps({
    "model_name": "Global Online Signature Strong V2 Ensemble",
    "architecture": "TCN + BiGRU + local temporal alignment + ArcFace + calibrated ensemble",
    "sequence_length": SEQ_LEN,
    "input_features": INPUT_FEATURES,
    "base_feature_names": feature_names,
    "input_layout": "16 values + 16 availability masks + 5 metadata fields",
    "reference_input_shape": ["batch", ENROLLMENT_REFS, SEQ_LEN, INPUT_FEATURES],
    "query_input_shape": ["batch", SEQ_LEN, INPUT_FEATURES],
    "output_columns": [
        "genuine_probability", "calibrated_logit", "mean_cosine_similarity"
    ],
    "thresholds": {
        "balanced_eer_threshold": float(eer_threshold),
        "secure_threshold": float(secure_threshold),
        "secure_threshold_target_far": TARGET_SECURE_FAR,
    },
    "metrics": {
        "validation": val_metrics,
        "test_skilled": test_skilled_metrics,
        "test_combined": test_combined_metrics,
        "test_skilled_secure": test_skilled_secure,
        "test_combined_secure": test_combined_secure,
        "per_domain": per_domain_metrics,
    },
    "training_records": domain_counts,
    "important": [
        "The exported model requires exactly five enrollment signatures.",
        "Use the secure threshold for banking/legal workflows.",
        "Use the EER threshold when balanced FAR/FRR is preferred.",
        "Do not compare raw PNG images; reproduce the same 37 input features.",
        "Revalidate thresholds on signatures collected by the final Flutter application.",
    ],
}, ensure_ascii=False, indent=2), encoding="utf-8")

README_FILE = EXPORT_DIR / "README.txt"
README_FILE.write_text(f"""
GLOBAL ONLINE SIGNATURE STRONG V2
=================================

Architecture:
- Four-block TCN
- Two-layer bidirectional GRU
- Local temporal alignment comparator
- ArcFace writer supervision
- Skilled and random hard-negative mining
- {ENSEMBLE_SIZE}-model calibrated ensemble
- Five-reference enrollment with trimmed-mean aggregation

Inputs:
reference_sequences: float32 [batch, {ENROLLMENT_REFS}, {SEQ_LEN}, {INPUT_FEATURES}]
query_sequence:       float32 [batch, {SEQ_LEN}, {INPUT_FEATURES}]

Outputs:
column 0: genuine probability
column 1: calibrated logit
column 2: mean cosine similarity

Balanced threshold: {eer_threshold:.8f}
Secure threshold:   {secure_threshold:.8f}

Validation:
{json.dumps(val_metrics, indent=2)}

Test skilled forgeries:
{json.dumps(test_skilled_metrics, indent=2)}

Test skilled + random forgeries:
{json.dumps(test_combined_metrics, indent=2)}

Security operating point on skilled forgeries:
{json.dumps(test_skilled_secure, indent=2)}

The model must be tested again on signatures captured by the final application.
No public benchmark result alone proves production security.
""", encoding="utf-8")

# Example inference file.
INFERENCE_FILE = EXPORT_DIR / "inference_example.py"
INFERENCE_FILE.write_text(r"""import json
import numpy as np
import onnxruntime as ort

MODEL = "global_signature_strong_v2.onnx"
CONFIG = json.load(open("model_config.json", "r", encoding="utf-8"))
session = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])

# Replace these arrays with the five processed enrollment signatures and one query.
references = np.zeros((1, 5, 192, 37), dtype=np.float32)
query = np.zeros((1, 192, 37), dtype=np.float32)

output = session.run(None, {
    "reference_sequences": references,
    "query_sequence": query,
})[0]

probability = float(output[0, 0])
secure_threshold = CONFIG["thresholds"]["secure_threshold"]
print({
    "probability": probability,
    "decision": "genuine" if probability >= secure_threshold else "suspicious",
})
""", encoding="utf-8")

(EXPORT_DIR / "requirements.txt").write_text(
    "numpy==2.0.2\nonnxruntime\ntorch\n",
    encoding="utf-8",
)

manifest = {
    "created_at_unix": time.time(),
    "device": str(DEVICE),
    "records": len(records),
    "balanced_ssl_records": len(ssl_balanced_indices),
    "train_records": len(train_indices),
    "validation_records": len(val_indices),
    "test_records": len(test_indices),
    "ensemble_models": ENSEMBLE_SIZE,
    "enrollment_references": ENROLLMENT_REFS,
    "domains": domain_counts,
    "active_domains": active_domains,
    "individual_validation": individual_validation,
}
(EXPORT_DIR / "training_manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2),
    encoding="utf-8",
)

FINAL_ZIP = Path(
    "/kaggle/working/GLOBAL_SIGNATURE_STRONG_V2_DEPLOYMENT.zip"
)
if FINAL_ZIP.exists():
    FINAL_ZIP.unlink()
with zipfile.ZipFile(FINAL_ZIP, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in EXPORT_DIR.rglob("*"):
        if path.is_file():
            archive.write(path, arcname=path.relative_to(EXPORT_DIR))

print("\n" + "=" * 76)
print("STRONG-V2 TRAINING AND EXPORT COMPLETED")
print("Download:")
print(FINAL_ZIP)
print("\nDeployment files:")
for path in sorted(EXPORT_DIR.iterdir()):
    if path.is_file():
        print(f" - {path.name}: {path.stat().st_size / 1024 / 1024:.2f} MB")
print("=" * 76)
