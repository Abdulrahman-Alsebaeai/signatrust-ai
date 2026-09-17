
GLOBAL ONLINE SIGNATURE STRONG V2
=================================

Architecture:
- Four-block TCN
- Two-layer bidirectional GRU
- Local temporal alignment comparator
- ArcFace writer supervision
- Skilled and random hard-negative mining
- 3-model calibrated ensemble
- Five-reference enrollment with trimmed-mean aggregation

Inputs:
reference_sequences: float32 [batch, 5, 192, 37]
query_sequence:       float32 [batch, 192, 37]

Outputs:
column 0: genuine probability
column 1: calibrated logit
column 2: mean cosine similarity

Balanced threshold: 0.56237704
Secure threshold:   0.84070288

Validation:
{
  "auc": 0.9123895202020202,
  "eer": 0.1684659090909091,
  "threshold": 0.5623770426981638,
  "far": 0.16875,
  "frr": 0.16818181818181818,
  "accuracy": 0.8315789473684211
}

Test skilled forgeries:
{
  "auc": 0.8514685714285714,
  "eer": 0.23485714285714288,
  "threshold": 0.5623770426981638,
  "far": 0.248,
  "frr": 0.21428571428571427,
  "accuracy": 0.7716666666666666
}

Test skilled + random forgeries:
{
  "auc": 0.881088,
  "eer": 0.20534285714285716,
  "threshold": 0.5623770426981638,
  "far": 0.1984,
  "frr": 0.21428571428571427,
  "accuracy": 0.7932075471698113
}

Security operating point on skilled forgeries:
{
  "auc": 0.8514685714285714,
  "eer": 0.23485714285714288,
  "threshold": 0.840702876906377,
  "far": 0.08,
  "frr": 0.4042857142857143,
  "accuracy": 0.7308333333333333
}

The model must be tested again on signatures captured by the final application.
No public benchmark result alone proves production security.
