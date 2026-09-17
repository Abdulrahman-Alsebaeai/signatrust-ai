import json
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
