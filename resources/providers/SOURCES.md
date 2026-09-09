# Provider marks

The logos shown beside each clean-up provider in Settings › AI clean-up and in
onboarding. Each is the provider's own mark, used only to identify that provider's
service in a list of services the user can connect — the same way a "Sign in with…"
button uses one. They are not ours and are not part of Murmr Flow's brand.

| File | Provider | Source | Licence / basis |
|---|---|---|---|
| `groq.svg` | Groq | `https://groq.com/favicon.svg` | Groq's own mark, as served by their site |
| `cerebras.png` | Cerebras | Cerebras site icon (Sanity CDN, 256 px) | Cerebras' own mark, as served by their site |
| `ollama.svg` | Ollama | Simple Icons, `ollama` | CC0 1.0; fill changed from black to `#EDF4FB` to read on the app's dark ground |
| `openrouter.svg` | OpenRouter | Simple Icons, `openrouter` | CC0 1.0 |
| `gemini.svg` | Google Gemini | Simple Icons, `googlegemini` | CC0 1.0 |

Custom has no mark: it is a generic server, drawn with an SF Symbol.

`scripts/build.sh` copies this folder to `Contents/Resources/Providers/`. The app loads
each file by the `logo` name on its `ProviderCatalog.Entry`; a missing file falls back to
the two-letter monogram, so a build without this folder still runs.
