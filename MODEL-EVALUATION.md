# Model evaluation — can a local model actually orchestrate?

Measured on Apple M3 Pro / 36 GB unified memory, Ollama 0.32.8, Metal ceiling ~27 GB.

The orchestrator (Hermes Agent) **refuses to initialise below a 64,000-token context
window**, so every candidate has to clear that bar first. The interesting result is
that clearing it is necessary but nowhere near sufficient.

## Verdict

| | Devstral Small 2 24B | gpt-oss 20b |
|---|---|---|
| Serves ≥64K | **yes** — 65536 | **yes** — 65536 |
| Tool calling | yes | yes |
| Resident at 64K | **25.07 GB** | ~14.9 GB |
| Concurrent agents | **1** | **3** — measured, 16.46 GiB at 3 × 64K slots |
| Recommended | **no** | **yes** |

**Devstral Small 2 is not viable as a local orchestrator on this hardware** — and the
reason is not the context window it advertises. It is the KV cache.

## Why the declared context window tells you almost nothing

Devstral declares **393216** (384K). That number is irrelevant to whether it works
here. What matters is what a 64K window *costs*:

```
n_layer 40 · n_head_kv 8 · n_embd_head_k 128  →  160 KiB per token
160 KiB × 65536 tokens                        →  10240 MiB of KV cache
```

Full allocation at `num_ctx 65536`, from the runner log:

| Component | Size |
|---|---|
| Model weights (Metal) | 13299.79 MiB |
| **KV cache (f16)** | **10240.00 MiB** |
| Compute buffers | ~455 MiB |
| **Total** | **23.35 GiB = 25.07 GB** |

That is **93% of the ~27 GB Metal ceiling** for a single agent, before Docker asks
for anything.

## The consequence: one slot, and therefore serialisation

With 10 GiB of KV per slot, Ollama sized parallelism to fit and chose one:

```
srv load_model: initializing, n_slots = 1, n_ctx_slot = 65536
```

A second slot would cost another 10 GiB (13.0 + 20.0 = 33+ GiB); a third, 43+ GiB.
Both exceed the ceiling.

Usefully, this also disproves a plausible worry: `/api/ps` reported **exactly
25070193868 bytes at 1, 2 and 3 concurrent requests** — there is no per-slot KV
multiplier eating memory under load, because there is no second slot. What happens
instead is that requests queue:

| Concurrency | Completion wall times | Batch wall | Per-request |
|---|---|---|---|
| 1 | 20.34 s (incl. 14.10 s load) | 20.34 s | 9.52 tok/s |
| 2 | 10.37 / 20.54 s | 20.54 s | 9.05 / 9.22 tok/s |
| 3 | 19.22 / 27.55 / 36.16 s | 36.16 s | 9.03 / 9.20 / 9.25 tok/s |

Per-request throughput never degrades — latency simply stacks, linearly.

## The actual disqualifier: cold prefill after a context switch

Serialised turns would be tolerable. This is not:

| Test | Prompt tokens | Prefill | Prefill tok/s |
|---|---|---|---|
| Small prompt, warm | 574 | 0.18 s | ~3200 |
| **Prompt A, cold, ~48K** | 48635 | **630.58 s** | 77.1 |
| Prompt A repeat (in-slot cache) | 48635 | 5.06 s | 9618 |
| **Prompt B, cold, ~50K** | 49764 | **731.06 s** | 68.1 |
| **Prompt A again, after B** | 48635 | **695.87 s** | 69.9 |

Prompt caching works beautifully for *one continuing conversation* — 630 s collapses
to 5 s. But the single slot holds exactly **one** cached prefix. Running B evicted A,
so returning to A cost a full **696-second** re-prefill.

That last row is the whole finding. Three agents with different contexts round-robin
through one slot, so **nearly every turn is a cold prefill — roughly 10–12 minutes
per turn at ~70 tok/s.** Not a tuning problem; a compute limit.

## Why gpt-oss:20b is 6.6× cheaper at the same window

Same 65536 window, same measurement method:

| | devstral-small-2:24b-64k | gpt-oss:20b-64k |
|---|---|---|
| Weights | 13299.79 MiB | 12036.67 MiB |
| **KV @ 65536** | **10240.00 MiB** | **1536 + 18 MiB** |
| Geometry | 40 layers, head_dim 128 | 12 non-SWA layers, head_dim 64, + 768-cell SWA |
| Total @ 1 slot | 25.07 GB | ~14.9 GB |
| Total @ 3 slots | ~43 GiB — impossible | **16.46 GiB measured** — fits, ~8.7 GiB spare |

gpt-oss uses **interleaved sliding-window attention**: only 12 layers carry a full KV
cache, and the head dimension is half. Three 64K slots fit comfortably under the
ceiling, which is the difference between a queue and actual parallelism.

The general lesson for picking a local orchestrator model: **compare KV cost per token
at your target window, not parameter count or advertised context.** A 24B dense model
and a 20B MoE with sliding-window attention differ by 6.6× in the number that decides
whether concurrency is possible.

## To actually get 3 slots

`OLLAMA_NUM_PARALLEL` must be set **in the environment the server inherits** — and on
macOS a GUI-launched Ollama does *not* pick up `launchctl setenv` values applied after
it started. Verify with:

```bash
ps eww -o command= -p "$(pgrep -f 'ollama serve')" | tr ' ' '\n' | grep ^OLLAMA
```

If the variable is absent there, it is not in effect no matter what `launchctl getenv`
reports. This is the same trap that made `OLLAMA_CONTEXT_LENGTH` look like it was
being ignored.

### Measured: it does stick, and three 64K slots do fit

What worked, in order — the restart is the load-bearing step:

```bash
launchctl setenv OLLAMA_NUM_PARALLEL 3
# quit Ollama COMPLETELY, then relaunch so it inherits launchd's new environment
pkill -f '/Applications/Ollama.app/Contents/MacOS/Ollama'
open -a Ollama
ps eww -o command= -p "$(pgrep -f 'ollama serve')" | tr ' ' '\n' | grep ^OLLAMA
#   OLLAMA_NO_CLOUD=0
#   OLLAMA_NUM_PARALLEL=3        <-- now in the server's own environment
#   OLLAMA_MODELS=...
#   OLLAMA_CONTEXT_LENGTH=65536
```

`OLLAMA_CONTEXT_LENGTH` appearing there is the earlier finding closing: it had been set
by `launchctl setenv` long before and had never been inherited. Same variable, same
`launchctl getenv` output, and only now in effect.

**Three slots, at the full window**, from the runner log:

```
srv    load_model: initializing, n_slots = 3, n_ctx_slot = 65536, kv_unified = 'false'
slot   load_model: id  0 | task -1 | new slot, n_ctx = 65536
slot   load_model: id  1 | task -1 | new slot, n_ctx = 65536
slot   load_model: id  2 | task -1 | new slot, n_ctx = 65536
```

Allocation, `gpt-oss:20b-64k`, measured at 1 slot and at 3:

| Buffer | 1 slot | 3 slots |
|---|---|---|
| Model weights (Metal) | 12 036.67 MiB | 12 036.67 MiB |
| KV, non-SWA (65 536 cells, 12 layers) | 1 536.00 MiB | **4 608.00 MiB** (3/3 seqs) |
| KV, SWA (768 cells) | 18.00 MiB | 54.00 MiB |
| Compute buffer (Metal) | 143.77 MiB | 154.84 MiB |
| **Total Metal** | **13 734 MiB = 13.41 GiB** | **16 854 MiB = 16.46 GiB** |

Two extra slots cost **3 119 MiB** — within 11 MiB of the 2 × (1536 + 18) MiB this
document predicted from the KV geometry. Against the ~27 GB (25.1 GiB) Metal ceiling
that is 66% used, with ~8.7 GiB spare. Devstral could not have done this: two of its
slots alone would have been 20 GiB of KV.

**`/api/ps` under-reports once `num_parallel > 1`.** It reported 12.84 GB while the
runner had allocated 16.46 GiB of Metal buffers. At one slot the two agreed (as they did
for Devstral). Read the runner log, not `/api/ps`, when sizing for concurrency.

### Throughput: 1 slot vs 3

Same model, same 192-token completions, distinct short prompts so each request would
take its own slot if one existed:

| Concurrency | 1 slot — batch wall | 1 slot — per-request | 3 slots — batch wall | 3 slots — per-request |
|---|---|---|---|---|
| 1 | 6.0 s generating | 31.8 tok/s | 6.1 s generating | 31.7 tok/s |
| 2 | 13.38 s | 31.4 / 31.8 tok/s | **8.71 s** | 25.0 / 25.0 tok/s |
| 3 | 19.38 s | 32.0 / 31.3 / 31.6 tok/s | **10.96 s** | 19.7 / 19.7 / 19.7 tok/s |

The shape of the result is the point. At one slot, per-request speed never degrades and
latency stacks linearly — 7 s, 14 s, 21 s — exactly the Devstral pattern. At three
slots the requests run genuinely concurrently: all three finish **together**, each at
19.7 tok/s instead of 31.6.

Aggregate generation throughput at three concurrent requests: **29.7 tok/s → 52.6
tok/s, a 1.77× improvement**, and the batch finishes in 57% of the time. Per-agent
speed is the price; three agents making progress at once is what is bought.

Repeating it with the full container stack and three worker containers up changed
nothing measurable (55.4 tok/s aggregate) — inference is on the host GPU and the
containers are not competing for it.

Host memory during three concurrent requests: **wired 20.17 GB**, compressor flat at
~3.9 GB. Compare the Devstral table below, where two concurrent requests drove wired to
28.8 GB — past the nominal ceiling — and free memory to 13%. gpt-oss at three slots does
not put the machine under pressure at all.

## If Devstral is required anyway

Only two levers, both with costs:

- **Quantise the KV cache** — `OLLAMA_KV_CACHE_TYPE=q8_0` halves KV to ~5 GiB, `q4_0`
  to ~2.5 GiB, at some quality cost. Would permit a second slot.
- **Raise `iogpu.wired_limit_mb`** past the default 75%, taking memory from everything
  else on the machine — including the Docker VM the workers need.

Neither addresses the ~70 tok/s cold prefill, which is compute-bound.

## Memory pressure, for the record

| Point | used (active+wired+compressor) | wired | compressor | free % |
|---|---|---|---|---|
| Baseline | 22.29 GB | 4.03 | 3.10 | 81% |
| Devstral loaded, idle | 22.84 GB | 3.82 | 3.96 | 79% |
| During 2 concurrent | 34.19 GB | **28.84** | 1.64 | 19% |
| During 3 concurrent | 35.32 GB | **28.90** | 3.84 | **13%** |
| During 48K prefill | 30.24 GB | 3.85 | **19.53** | 38% |

Under load, wired memory reached **28.9 GB** — past the nominal 27 GB ceiling — and
macOS paid for it by compressing everything else, driving system free memory to 13%.
With ~7.8 GB also committed to the Docker VM, the machine is fully spent serving a
single agent.

**This is the argument for dedicated inference hardware, in numbers rather than
assertion.** The bottleneck is inference, not container isolation.
