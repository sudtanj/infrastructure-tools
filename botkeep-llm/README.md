# botkeep-llm

Small LLM served by [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`) on [botkeep.cloud](https://botkeep.cloud). Deployed by the `Deploy botkeep folders` workflow like the other `botkeep*` folders: the workload is created from `.botkeep` if it does not exist, `start.sh` is uploaded and the workload restarted.

## How it works

`start.sh` downloads a prebuilt `llama-server` (~18 MB) and `qwen2.5-0.5b-instruct-q4_k_m.gguf` (~400 MB) on the first start, then serves an OpenAI-compatible API on the port Botkeep assigns (`SERVER_PORT`). Later starts reuse the files. Startup command: `bash start.sh`.

Sized for 512 MB RAM: the model uses about 400 MB and the context is limited to 1024 tokens. It is slow but works; give it 1 GB for more headroom (`LLAMA_CTX=2048`).

## Optional variables (workload environment)

| Variable | Default | Meaning |
| --- | --- | --- |
| `LLAMA_API_KEY` | unset | Require `Authorization: Bearer <key>` (set this, the port is public) |
| `MODEL_URL` | Qwen2.5-0.5B-Instruct Q4_K_M | Any direct `.gguf` URL (Hugging Face `.../resolve/main/<file>.gguf`) |
| `LLAMA_CTX` | `1024` | Context size |
| `LLAMA_THREADS` | `2` | CPU threads |
| `LLAMA_TAG` | `b11552` | llama.cpp release tag |

## Use

```bash
curl http://<host>:<port>/v1/chat/completions -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
  -d '{"messages":[{"role":"user","content":"Hello"}]}'
```
