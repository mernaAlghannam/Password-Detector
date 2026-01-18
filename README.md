# Password-Detector

Offline **cleartext secret / password detection** for text files using a local LLM (via `llama-cli.exe`) + a PowerShell wrapper script. The goal is to flag *likely* secrets even when variable names don’t look obvious (i.e., beyond simple “`password=`” regex hits). :contentReference[oaicite:0]{index=0}

> **Status:** Proof-of-concept / evolving. Expect false positives & false negatives.

---

## What’s in this repo

- **`Cleartext-password-Detector.ps1`** — PowerShell CLI that scans a text file and returns a structured result. 
- **`llama-cli.exe`** — local inference runner (bundled here for convenience).  
- **MIT License** 

---

## Key features

- **Offline-first**: designed to run locally without sending your data to a cloud API.
- **LLM-assisted detection**: aims to catch secrets embedded in configs, connection strings, logs, code comments, etc.
- **Evidence reporting**: returns the line(s) that triggered the detection (and a confidence score).
- **Portable**: PowerShell script + local runner.

---
## Example output

### Example 1 — secret found
```json
{
  "verdict": "SECRET",
  "confidence": 0.82,
  "types": ["password"],
  "evidence": [
    "Line 03: Server=prod-db-01;Database=app_prod;User Id=svc_app;Pwd=Winter2026!SuperSecret;Encrypt=True;"
  ]
}

---

## Quick start

### 1) Clone
```bash
git clone https://github.com/mernaAlghannam/Password-Detector.git
cd Password-Detector
