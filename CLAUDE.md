# Ai-Clothing-Recommendation

Fit-aware semantic search across Shopify apparel brands.
Spec: docs/SPEC.md. Architecture: docs/HLD.md. Plan: docs/PLAN.md. Work one phase at a time.

## Environment
- Windows + PowerShell. Python 3.11, venv in .venv. Give commands in PowerShell syntax.
- Local LLMs run through Ollama (http://localhost:11434). No paid LLM APIs.
- Docker Desktop (WSL2) is installed. Use it for local Supabase (`supabase start`) and to build and run the serving image locally before deploys.
- The pipeline, models and Ollama run natively on Windows, not in Docker.

## Rules
- Never print, log, or commit secrets. Read keys from .env only.
- Develop against local Supabase only. You may apply migrations locally (`supabase db reset`) and read/write the local DB freely.
- Never run migrations or writes against the hosted Supabase DB. I review and push migrations to it myself.
- Never commit crawled data, images, ANSUR files, or artifacts. data/ and artifacts/ are gitignored.
- Crawler: public endpoints only, respect robots.txt, max 1 request per second per store, identify with a user agent.
- Cache every LLM call to disk, keyed by model + prompt version + input hash. Never re-call for cached inputs.
- Every LLM extraction must use a JSON schema; save raw outputs to extraction_runs.
- Every reported metric comes from a script writing results/metrics.csv. No numbers from notebooks.
- Never generate, edit, or fill in gold-set, closet, classifier spot-check, or query labels. Those are mine.
- No LLM calls and no PyTorch in serving/. The server uses onnxruntime + NumPy only.
- Each phase ends with its "done when" check from docs/PLAN.md passing, then a commit.
