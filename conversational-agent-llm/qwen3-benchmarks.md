# HA Voice Pipeline Benchmark

**Date:** 2026-03-03 20:43:58
**Host:** edgexpert-6f45
**GPU:** NVIDIA GB10
**Reps per prompt:** 3
**Warmup requests:** 3
**Max tokens:** 128
**Temperatures:** 0
**Sampling (API):** top_p=0.95 top_k=20 min_p=0.00 presence_penalty=1.5 repeat_penalty=1.0

### Configurations

#### Qwen3-14B-Q8_0 + 0.6B draft (llama.cpp)

`-m /opt/models/llama-server/Qwen3-14B-Q8_0.gguf
-md /opt/models/llama-server/Qwen3-0.6B-Q4_K_M.gguf
-c 24576
-cd 24576
-ngld 999
-b 1024
-ub 512
-ngl 999
--draft-max 16
--draft-min 1
--draft-p-min 0.75
--jinja
-fa on
-sm none
-mg 0
-np 1
--parallel 1
--temp 0.0
--top-k 20
--top-p 0.95
--min-p 0.00
--presence-penalty 1.5
--repeat-penalty 1.0
--host 0.0.0.0
--port 8080
--log-verbosity 3
--cache-type-k q8_0
--cache-type-v q8_0
--chat-template-kwargs "{\"enable_thinking\":false}"`

## Qwen3-14B-Q8_0 + 0.6B draft — temp=0

| # | Test | Command | Avg (ms) | Min (ms) | Max (ms) | Accuracy | Tool Called | Args |
|---|------|---------|----------|----------|----------|----------|-------------|------|
| 1 | bedtime | it is bedtime | 418 | 311 | 626 | 3/3 | HassRunScript | `{"name":"script.ai_master_bedroom_bedtime"}` |
| 2 | message_mode | message mode | 420 | 318 | 616 | 3/3 | HassRunScript | `{"name":"script.ai_master_bedroom_message_mode"}` |
| 3 | cozy_bedroom | make it cozy | 427 | 321 | 625 | 3/3 | HassRunScript | `{"name":"script.ai_master_bedroom_cozy"}` |
| 4 | cold_bedroom | make it cold | 430 | 315 | 655 | 3/3 | HassRunScript | `{"name":"script.bedroom_ac_turbo"}` |
| 5 | food_here | food is here | 453 | 320 | 718 | 3/3 | HassRunScript | `{"name":"script.food_delivery_here"}` |
| 6 | open_bed_shades | open bedroom shades | 469 | 320 | 760 | 3/3 | HassRunScript | `{"name":"script.ai_open_master_bedroom_curtains"}` |
| 7 | close_bed_shades | close bedroom shades | 489 | 322 | 821 | 3/3 | HassRunScript | `{"name":"script.ai_close_master_bedroom_curtains"}` |
| 8 | clear_bedroom | clear the bedroom | 448 | 320 | 705 | 3/3 | HassRunScript | `{"name":"script.ai_clear_the_master_bedroom"}` |
| 9 | bedroom_ac_on | turn on bedroom ac | 471 | 320 | 770 | 3/3 | HassRunScript | `{"name":"script.bedroom_ac_eco"}` |
| 10 | bedroom_bright | master bedroom bright | 373 | 296 | 523 | 3/3 | HassRunScript | `{"name":"scene_bedroom_bright"}` |
| 11 | office_ac_on | turn on office ac | 458 | 316 | 740 | 3/3 | HassRunScript | `{"name":"script.office_ac_on_eco"}` |
| 12 | office_ac_off | turn off office ac | 459 | 317 | 742 | 3/3 | HassRunScript | `{"name":"script.office_ac_off"}` |
| 13 | office_dim | dim the office | 462 | 314 | 757 | 3/3 | HassRunScript | `{"name":"scene_office_dim"}` |
| 14 | office_bright | office bright | 402 | 293 | 621 | 3/3 | HassRunScript | `{"name":"scene_office_showcase"}` |
| 15 | office_cold | make the office cold | 525 | 328 | 918 | 3/3 | HassRunScript | `{"name":"script.office_ac_on_turbo"}` |
| 16 | visitors | we have visitors | 437 | 319 | 572 | 3/3 | HassRunScript | `{"name":"ai_we_have_visitors"}` |
| 17 | clear_living | clear the living room | 418 | 318 | 515 | 3/3 | HassRunScript | `{"name":"ai_clear_the_living_room"}` |
| 18 | open_living_shades | open living room shades | 470 | 323 | 766 | 3/3 | HassRunScript | `{"name":"ai_open_living_room_curtains"}` |
| 19 | open_office_shades | open office shades | 424 | 320 | 631 | 3/3 | HassRunScript | `{"name":"ai_open_office_curtains"}` |
| 20 | close_office_shades | close office shades | 504 | 318 | 870 | 3/3 | HassRunScript | `{"name":"script.ai_close_office_curtains"}` |

**Qwen3-14B-Q8_0 + 0.6B draft (temp=0):** 60/60 correct (100%)
