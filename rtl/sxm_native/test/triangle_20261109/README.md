# Isolated LPU32 SXM experiment

- `baseline/`: byte-for-byte snapshot of current native SXM; do not add these duplicate module names to a product filelist.
- `candidate/sxm_wide_queue.sv`: experimental replacement capture/storage/wide-P data path using the baseline column/row transpose indexing. TRI=0 is the fixed16 controlled experiment; TRI=1 is the 1/2/3/4-slot folded triangle. This is not the full baseline command/compatibility ABI and is not a product replacement.
- Actual source data stays in SXM. No MXM buffer is included, reused or charged. No second payload copy is made on block completion or P output.
- Existing full VECTOR_PERMUTE remains in the untouched product and baseline snapshot. Candidate vector smoke covers one-row packed forwarding/block routing, not the complete original arbitrary lane permutation/command behavior.

Scripts, cases, results, constraints, measurement definitions and limitations:

Local workspace-relative path: `learn/sxm_triangle_wide_20261109/README.md`
(outside the VMODEL Git repository; not included in a standalone clone).

Only the explicit experimental top is compiled; no production filelist is changed.
