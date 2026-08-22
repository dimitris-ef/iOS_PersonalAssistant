# The curated model catalog

`local-models.json` is the list of models the app offers to download. It holds
*descriptions* — never weights. Nothing in this repository is a model file, and
nothing here should ever become one (section 16: model weights are not
redistributed by this app; they are fetched from their publisher, on the user's
device, when the user asks).

## Adding a model

Every entry needs:

| field | why |
| --- | --- |
| `id` | Stable logical identifier. Never a path — sandbox paths move (section 27). |
| `architecture` | As GGUF records it. Checked against the downloaded file's own header after download; a mismatch fails the install (section 116). |
| `quantization` | `Q4_K_M` and friends. Used for size expectations and the model list. |
| `fileSizeBytes` | Drives the storage and memory checks *before* the download starts (sections 8 and 12). |
| `downloadURL` | **HTTPS only.** The transport refuses anything else (section 75). |
| `defaultContextLength` | What the app opens the model with. Conservative, not the model's maximum (section 45). |
| `toolSupport` | `supported` / `experimental` / `unsupported`. A model marked `unsupported` is never shown tool instructions and the UI says "chat only" (sections 55 and 56). |
| `license` | Recorded and shown. Set `isRedistributable: false` for a model whose weights are behind an acceptance gate — the app then declines to download it, because it has no credential to present and should not have one (section 77). |

Optional but worth filling in:

- `checksumSHA256` — see below.
- `kvCacheBytesPerToken` — the single biggest input to the memory estimate.
  Omitting it falls back to a deliberately pessimistic figure.
- `maximumContextLength`, `summary`, `chatTemplate`.

## Checksums

`checksumSHA256` is optional in the format and **enforced whenever it is
present**: a download whose digest does not match is deleted and reported as
corrupt (section 23).

The entries currently shipped do **not** carry checksums, and that is a gap
rather than a design choice — see `Docs/OPEN-ITEMS.md`. Verification is not
skipped for them: the file must still be a structurally valid GGUF of the
declared architecture and roughly the declared size, and the digest of whatever
arrived is computed and recorded so a later integrity check has a baseline. What
is missing is the ability to detect a *substituted* but well-formed file.

To fill one in, download the file and run:

```
shasum -a 256 Qwen3-1.7B-Q4_K_M.gguf
```

then paste the 64-character digest into the entry. Do this once per URL, and
re-do it if the publisher re-uploads.

## Sizes

`fileSizeBytes` should be the publisher's actual byte count. The installer
tolerates 5% drift before it calls the delivered file a discrepancy, so an
approximate figure is usable — but an approximate figure also makes the
pre-download storage check approximate, which is the check that stops a
download failing two gigabytes in.
