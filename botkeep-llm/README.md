# botkeep-llm

Small LLM served by a Rust runtime ([mistral.rs](https://github.com/EricLBuehler/mistral.rs)) on [botkeep.cloud](https://botkeep.cloud). It is set up by hand from the dashboard, with no GitHub Action.

## Setup (dashboard)

1. Create a server (any egg that gives you a shell and `curl`). RAM must hold the model plus about 1 GB; storage must hold the binary plus the model. A 1-2 GB RAM server fits a ~0.5-1.5B parameter model quantized to Q4.
2. Upload `start.sh` (file manager or SFTP).
3. In the Startup tab set the variables:

   | Variable | Value |
   | --- | --- |
   | `MISTRALRS_URL` | URL of a prebuilt Linux `mistralrs-server` binary from the project's GitHub releases (check it matches the server's CPU architecture) |
   | `MODEL_URL` | Direct URL of a small `.gguf` file on Hugging Face (`.../resolve/main/<file>.gguf`) |
   | `MODEL_FILE` | optional, defaults to the file name in `MODEL_URL` |

4. Startup command: `bash start.sh`
5. Start the server. The first start downloads the binary and model; later starts reuse them.

The API is OpenAI compatible, e.g. `POST http://<host>:<port>/v1/chat/completions`.

## Notes

- Verify the exact `mistralrs-server` CLI flags against `--help` for the release you download; `start.sh` has one line to adjust.
- The server is open to anyone who reaches the port. Put it behind auth or a private network before exposing it.
- If prebuilt binaries are not offered for your platform, `llama-server` from llama.cpp is a drop-in alternative (C++, not Rust).
