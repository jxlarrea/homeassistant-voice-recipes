#!/usr/bin/env bash
# =============================================================================
# ha-voice-bench.sh — Benchmark HA voice tool calling against a running container
#
# Usage:
#   ./ha-voice-bench.sh <container-name>
#
# Examples:
#   ./ha-voice-bench.sh llama-qwen-14b-q8
#   ./ha-voice-bench.sh llama-qwen3.5-9b-q8
#
# The container must already be running. The script auto-detects the port
# from the container's command line args (looks for --port).
# =============================================================================

set -uo pipefail

# ─── Argument parsing ────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <container-name>"
    echo ""
    echo "Examples:"
    echo "  $0 llama-qwen-14b-q8"
    echo "  $0 llama-qwen3.5-9b-q8"
    echo ""
    echo "Running containers:"
    docker ps --format '  {{.Names}}  ({{.Status}})' --filter "ancestor=llama-server:latest" 2>/dev/null || true
    exit 1
fi

CONTAINER="$1"

# ─── Auto-detect port ────────────────────────────────────────────────────────

detect_port() {
    # Try to extract --port from the container's command
    local port
    port=$(docker inspect "$CONTAINER" --format '{{join .Args " "}}' 2>/dev/null \
        | grep -oP '(?<=--port )\d+' || true)
    if [[ -z "$port" ]]; then
        # Fallback: check exposed ports
        port=$(docker port "$CONTAINER" 2>/dev/null | head -1 | grep -oP '\d+$' || true)
    fi
    if [[ -z "$port" ]]; then
        port=8080  # default
    fi
    echo "$port"
}

# ─── Verify container is running ─────────────────────────────────────────────

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    err_msg="Container '$CONTAINER' is not running."
    echo "ERROR: $err_msg"
    echo ""
    echo "Running containers:"
    docker ps --format '  {{.Names}}  ({{.Status}})' 2>/dev/null || true
    exit 1
fi

PORT=$(detect_port)
API_URL="http://127.0.0.1:${PORT}/v1/chat/completions"

# ─── Benchmark params ────────────────────────────────────────────────────────

MAX_TOKENS=128
TEMPERATURE=0
REPS=3
WARMUP_REQUESTS=3

# Sampling params
TOP_P=0.95
TOP_K=20
MIN_P=0.00
PRESENCE_PENALTY=1.5
REPEAT_PENALTY=1.0

OUTPUT_FILE="ha_voice_bench_${CONTAINER}_$(date +%Y%m%d_%H%M%S).md"

# ─── System Prompt ───────────────────────────────────────────────────────────

SYSTEM_PROMPT='You are Lisa, a smart home voice assistant. Location: Samborondon. /no_think
Keep responses short, plain text only, no emojis or formatting. Never ask follow up questions. Never offer to do something extra. Just answer and stop.

# MANDATORY TOOL USE
- You MUST call tools to answer questions. You cannot answer from memory alone when a tool exists.
- Questions about weather, temperature, forecasts, rain, humidity → CALL the weather tool. Do NOT guess or answer from memory.
- Questions about news, current events, sports scores, people, facts you are unsure about → CALL the web search tool. NEVER guess or answer from memory.
- Questions about time-sensitive information of any kind → CALL the appropriate tool.
- Home assistant commands → CALL the appropriate Home Assistant tool.
- NEVER say "I don'\''t have access to that information." You DO have access. USE YOUR TOOLS.
- NEVER describe what you would do. Actually call the tool.
- Always use the tools provided to you. Always.

# CRITICAL TOOL RULES
- HassTurnOn and HassTurnOff ONLY accept two arguments: "name" and "domain". Nothing else.
- NEVER pass device_class. NEVER pass area. NEVER pass floor. These are forbidden arguments.
- When executing a tool, do NOT say what you are about to do. Just call the tool silently.
- Only respond AFTER the tool result comes back, with a brief confirmation.
- NEVER say "Let me...", "I'\''ll...", "I'\''m going to..." before a tool call.

# WHEN NOT TO USE TOOLS
Questions about time, date, day of the week, or simple math → Answer directly. Do NOT call any Home Assistant tool.
HassBroadcast is ONLY for when the user explicitly asks to announce or broadcast a message to all speakers. Never use HassBroadcast to answer a question.

# LOCKS AND DOORS
- ANY request involving a door, gate, or lock MUST use domain "lock".
- Unlock = HassTurnOff, domain "lock", name of the device.
- Lock = HassTurnOn, domain "lock", name of the device.
NEVER use device_class "door". NEVER use device_class "gate".
The ONLY correct domain for doors, gates, and locks is "lock".

Examples:
- "unlock the front door" → HassTurnOff(name="front door lock", domain="lock")
- "open the building door" → HassTurnOff(name="building door", domain="lock")
- "lock the garage door" → HassTurnOn(name="garage door", domain="lock")
- "close the garage door" → HassTurnOn(name="garage door", domain="lock")

# Timers
When the user asks to cancel a timer, always call HassCancelTimer with an empty arguments object {}. Never pass "name", "area", or any other argument unless the user explicitly says the timer'\''s exact name (e.g., "cancel the pizza timer"). The device context is handled automatically — do not use the device name or area name as a timer name.
WRONG: HassCancelTimer(name="Entrance Timer")
CORRECT: HassCancelTimer()

# GENERAL
- Answer all questions directly. Never say you are searching. If a word sounds like a known device name, say "Assuming you meant [name]" and proceed. If input is unclear say "Can you repeat that?" If you cannot complete a request say "Sorry, I was not able to do that."
- If user input sounds like a command but does not clearly match a known script trigger or a specific device name, say "Can you repeat that?" Do not guess or improvise a command.
- You can answer casual questions, tell jokes, and have light conversation. But when the user gives a command that matches a script or device, ALWAYS use the tool to execute it. Never just say the script name.

# RESPONSE STYLE AFTER ACTIONS
After executing a script or command, respond with a brief, natural confirmation of what actually happened. Do NOT say "Let me know if you need anything else" or any variation of that. Ever.

# SCRIPTS - ALWAYS use these exact matches
Turning OFF the bedroom/master bedroom AC is NOT a script. Use HassTurnOff(name="Master Bedroom AC", domain="climate").
"open master bedroom shades" OR "open bedroom shades" = script.ai_open_master_bedroom_curtains
"close master bedroom shades" OR "close bedroom shades" = script.ai_close_master_bedroom_curtains
"clear the master bedroom" OR "clear the bedroom" = script.ai_clear_the_master_bedroom
"bedroom ac" = "master bedroom ac"
"turn on bedroom ac" = "script.bedroom_ac_eco"
"turn on master bedroom ac" = "script.bedroom_ac_eco"
"make it cozy" OR "dim the bedroom" = script.ai_master_bedroom_cozy
"master bedroom bright" = script.scene_bedroom_bright
"bedtime" OR "it is bedtime" = script.ai_master_bedroom_bedtime
"make it cold" = script.bedroom_ac_turbo
"food is here" = script.food_delivery_here (ALWAYS execute the script and then respond with "Enjoy your meal!")
"open office shades" = script.ai_open_office_curtains
"close office shades" = script.ai_close_office_curtains
"make the office cold" = script.office_ac_on_turbo
"turn on office ac" = script.office_ac_on_eco
"turn on office a c" = script.office_ac_on_eco (common misheard variant)
"turn off office ac" = script.office_ac_off
"dim the office" = script.scene_office_dim
"deem the office" = script.scene_office_dim (common misheard variant)
"office bright" = script.scene_office_showcase
"we have visitors" = script.ai_we_have_visitors
"clear the living room" = script.ai_clear_the_living_room
"open living room shades" = script.ai_open_living_room_curtains
"close living room shades" = script.ai_close_living_room_curtains

# REMINDER
- The SCRIPTS section above takes priority over any instructions below. If user input matches a script, ALWAYS execute that script. No exceptions.
- Follow these instructions for tools from "assist":
- When controlling Home Assistant always call the intent tools.
- Use HassTurnOn to lock and HassTurnOff to unlock a lock. When controlling a device, prefer passing just name and domain.
- When controlling an area, prefer passing just area name and domain.
- You must call the tool EVERY time the user gives a command, even if the same command was just executed. Never assume a previous tool call still applies. Never say what you will do, say what you did.
Follow these instructions for tools from "assist":
When controlling Home Assistant always call the intent tools. Use HassTurnOn to lock and HassTurnOff to unlock a lock. When controlling a device, prefer passing just name and domain. When controlling an area, prefer passing just area name and domain.
When a user asks to turn on all devices of a specific type, ask user to specify an area, unless there is only one device of that type.
This device is not able to start timers.
You ARE equipped to answer questions about the current state of
the home using the `GetLiveContext` tool. This is a primary function. Do not state you lack the
functionality if the question requires live data.
If the user asks about device existence/type (e.g., "Do I have lights in the bedroom?"): Answer
from the static context below.
If the user asks about the CURRENT state, value, or mode (e.g., "Is the lock locked?",
"Is the fan on?", "What mode is the thermostat in?", "What is the temperature outside?"):
    1.  Recognize this requires live data.
    2.  You MUST call `GetLiveContext`. This tool will provide the needed real-time information (like temperature from the local weather, lock status, etc.).
    3.  Use the tool'\''s response** to answer the user accurately (e.g., "The temperature outside is [value from tool].").
For general knowledge questions not about the home: Answer truthfully from internal knowledge.

Static Context: An overview of the areas and the devices in this smart home:
- names: Building Door
  domain: lock
  areas: Building
- names: Dining Room AC
  domain: climate
  areas: Dining Room
- names: Entrance Timer
  domain: timer
- names: Front Door Lock
  domain: lock
  areas: Front
- names: Govee Sync Box Bedroom, Master Bedroom TV Strip
  domain: light
  areas: Master Bedroom
- names: Kitchen Accent
  domain: light
  areas: Kitchen
- names: Kitchen Main Lights
  domain: light
  areas: Kitchen
- names: Kitchen Pantry
  domain: light
  areas: Kitchen
- names: Laundry Room Main Lights, Laundry Lights
  domain: switch
  areas: Laundry
- names: Living Room AC
  domain: climate
  areas: Living Room
- names: Living Room Shield Remote, Living Room Shield
  domain: remote
  areas: Living Room
- names: Living Room Temperature, Living Room Temperature
  domain: sensor
  areas: Living Room
- names: Master Bedroom AC
  domain: climate
  areas: Master Bedroom
- names: Master Bedroom Temperature, Master Bedroom Temperature
  domain: sensor
  areas: Master Bedroom
- names: Office Temperature
  domain: sensor
  areas: Office
- names: Sensor Laundry Humidity, Laundry Humidity
  domain: sensor
  areas: Laundry
- names: Sensor Laundry Temperature, Laundry Temperature
  domain: sensor
  areas: Laundry
- names: Sensor Office Humidity
  domain: sensor
  areas: Office
- names: Sensor Outside Humidity
  domain: sensor
  areas: Outside
- names: Sensor Outside Temperature
  domain: sensor
  areas: Outside


Follow these instructions for tools from "voice-satellite-card-financial-data":
You may use the Financial Data tool to look up stock prices, cryptocurrency prices, and convert currencies. When the user asks about a stock price, cryptocurrency price, market data, or how a stock or crypto is doing, use the get_financial_data tool with query_type '\''stock'\'' and the ticker symbol (e.g. AAPL, TSLA, BTC, ETH). When the user asks to convert currencies or about exchange rates, use the get_financial_data tool with query_type '\''currency'\''.

Follow these instructions for tools from "voice-satellite-card-video-search":
You may use the Video Search Services tools to find videos on YouTube. When the user asks you to find, search for, or show videos, use the search_videos tool. Set auto_play to true when the user wants to watch a specific video immediately (e.g. '\''play the latest MrBeast video'\'', '\''show me that rickroll video'\''). Set auto_play to false when they want to browse or explore results (e.g. '\''find me videos about cooking'\'', '\''search for guitar tutorials'\'').

Follow these instructions for tools from "voice-satellite-card-image-search":
You may use the Image Search Services tools to find images on the internet. When the user asks you to find, search for, or show images, use the search_images tool. Set auto_display to true when the user wants to see a specific image immediately (e.g. '\''show me the Mona Lisa'\'', '\''what does a pangolin look like'\''). Set auto_display to false when they want to browse multiple results (e.g. '\''find me pictures of cats'\'', '\''search for sunset photos'\'').

Follow these instructions for tools from "voice-satellite-card-web-search":
You may use the Web Search tool to search the internet for information. When the user asks a question that requires current information, facts, or general knowledge that you are not sure about, use the search_web tool.

Follow these instructions for tools from "voice-satellite-card-weather-forecast":
You may use the Weather Forecast tool to get weather information. When the user asks about the weather, temperature, or forecast for today, tomorrow, a specific day of the week, or the upcoming week, use the get_weather_forecast tool with the appropriate range parameter.

Follow these instructions for tools from "voice-satellite-card-wikipedia":
You may use the Wikipedia Search tool to look up encyclopedic information. When the user asks about a topic, person, place, event, or concept that Wikipedia would cover, use the search_wikipedia tool.'

# ─── Tool Definitions ────────────────────────────────────────────────────────

TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "HassRunScript",
      "description": "Run a Home Assistant script.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Script entity_id" }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "HassTurnOn",
      "description": "Turn on a device.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Device name" },
          "domain": { "type": "string", "description": "Device domain" }
        },
        "required": ["name", "domain"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "HassTurnOff",
      "description": "Turn off a device.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Device name" },
          "domain": { "type": "string", "description": "Device domain" }
        },
        "required": ["name", "domain"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "HassCancelTimer",
      "description": "Cancel a timer.",
      "parameters": {
        "type": "object",
        "properties": {},
        "required": []
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "HassBroadcast",
      "description": "Broadcast a message to all speakers.",
      "parameters": {
        "type": "object",
        "properties": {
          "message": { "type": "string", "description": "Message to broadcast" }
        },
        "required": ["message"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "GetLiveContext",
      "description": "Get current state of home devices.",
      "parameters": {
        "type": "object",
        "properties": {},
        "required": []
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_videos",
      "description": "Search for videos on YouTube.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" },
          "auto_play": { "type": "boolean", "description": "Auto-play the first result" }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_wikipedia",
      "description": "Search Wikipedia for encyclopedic information.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "get_weather_forecast",
      "description": "Get weather forecast information.",
      "parameters": {
        "type": "object",
        "properties": {
          "range": { "type": "string", "description": "Forecast range: today, tomorrow, week, or a day name" }
        },
        "required": ["range"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_images",
      "description": "Search for images on the internet.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" },
          "auto_display": { "type": "boolean", "description": "Auto-display the first result" }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_web",
      "description": "Search the internet for current information.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "get_financial_data",
      "description": "Look up stock prices, crypto prices, or convert currencies.",
      "parameters": {
        "type": "object",
        "properties": {
          "query_type": { "type": "string", "description": "Type: stock or currency" },
          "symbol": { "type": "string", "description": "Ticker symbol or currency pair" }
        },
        "required": ["query_type", "symbol"]
      }
    }
  }
]'

# ─── Test Prompts ────────────────────────────────────────────────────────────

TEST_NAMES=()
TEST_COMMANDS=()
TEST_EXPECT_TOOL=()
TEST_EXPECT_SCRIPT=()
TEST_ALT_ACCEPT=()

TEST_NAMES+=("bedtime");              TEST_COMMANDS+=("it is bedtime");               TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_master_bedroom_bedtime");         TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("cozy_bedroom");         TEST_COMMANDS+=("make it cozy");                TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_master_bedroom_cozy");            TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("cold_bedroom");         TEST_COMMANDS+=("make it cold");                TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.bedroom_ac_turbo");                  TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("food_here");            TEST_COMMANDS+=("food is here");                TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.food_delivery_here");                TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("open_bed_shades");      TEST_COMMANDS+=("open bedroom shades");         TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_open_master_bedroom_curtains");   TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("close_bed_shades");     TEST_COMMANDS+=("close bedroom shades");        TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_close_master_bedroom_curtains");  TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("clear_bedroom");        TEST_COMMANDS+=("clear the bedroom");           TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_clear_the_master_bedroom");       TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("bedroom_ac_on");        TEST_COMMANDS+=("turn on bedroom ac");          TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.bedroom_ac_eco");                    TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("bedroom_bright");       TEST_COMMANDS+=("master bedroom bright");       TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.scene_bedroom_bright");              TEST_ALT_ACCEPT+=("HassTurnOn:bedroom.*scene|HassTurnOn:bedroom bright")
TEST_NAMES+=("office_ac_on");         TEST_COMMANDS+=("turn on office ac");           TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.office_ac_on_eco");                  TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("office_ac_off");        TEST_COMMANDS+=("turn off office ac");          TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.office_ac_off");                     TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("office_dim");           TEST_COMMANDS+=("dim the office");              TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.scene_office_dim");                  TEST_ALT_ACCEPT+=("HassTurnOn:office.*dim.*scene|HassTurnOn:office dim")
TEST_NAMES+=("office_bright");        TEST_COMMANDS+=("office bright");               TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.scene_office_showcase");             TEST_ALT_ACCEPT+=("HassTurnOn:office.*scene|HassTurnOn:office bright")
TEST_NAMES+=("office_cold");          TEST_COMMANDS+=("make the office cold");        TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.office_ac_on_turbo");                TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("visitors");             TEST_COMMANDS+=("we have visitors");            TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_we_have_visitors");               TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("clear_living");         TEST_COMMANDS+=("clear the living room");       TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_clear_the_living_room");          TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("open_living_shades");   TEST_COMMANDS+=("open living room shades");     TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_open_living_room_curtains");      TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("open_office_shades");   TEST_COMMANDS+=("open office shades");          TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_open_office_curtains");           TEST_ALT_ACCEPT+=("")
TEST_NAMES+=("close_office_shades");  TEST_COMMANDS+=("close office shades");         TEST_EXPECT_TOOL+=("HassRunScript"); TEST_EXPECT_SCRIPT+=("script.ai_close_office_curtains");          TEST_ALT_ACCEPT+=("")

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
err()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[PASS]\033[0m  %s\n" "$*"; }
fail() { printf "\033[1;31m[FAIL]\033[0m  %s\n" "$*"; }

send_prompt() {
    local user_msg="$1"
    local temp="$2"

    local request_json
    request_json=$(jq -n \
        --arg sys "$SYSTEM_PROMPT" \
        --arg usr "$user_msg" \
        --argjson tools "$TOOLS_JSON" \
        --argjson max_tok "$MAX_TOKENS" \
        --argjson temp "$temp" \
        --argjson top_p "$TOP_P" \
        --argjson top_k "$TOP_K" \
        --argjson min_p "$MIN_P" \
        --argjson presence_penalty "$PRESENCE_PENALTY" \
        --argjson repeat_penalty "$REPEAT_PENALTY" \
        '{
            messages: [
                {role: "system", content: $sys},
                {role: "user", content: $usr}
            ],
            tools: $tools,
            tool_choice: "auto",
            max_tokens: $max_tok,
            temperature: $temp,
            top_p: $top_p,
            top_k: $top_k,
            min_p: $min_p,
            presence_penalty: $presence_penalty,
            repeat_penalty: $repeat_penalty,
            chat_template_kwargs: {"enable_thinking": false},
            stream: false
        }')

    local start_ms end_ms
    start_ms=$(date +%s%3N)

    local response
    response=$(curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "$request_json" 2>/dev/null)

    end_ms=$(date +%s%3N)

    local total_ms=$((end_ms - start_ms))

    local finish_reason tool_name tool_args content prompt_tok compl_tok
    finish_reason=$(echo "$response" | jq -r '.choices[0].finish_reason // "unknown"')
    tool_name=$(echo "$response" | jq -r '.choices[0].message.tool_calls[0].function.name // ""')
    tool_args=$(echo "$response" | jq -r '.choices[0].message.tool_calls[0].function.arguments // ""')
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' | sed 's/<[^>]*>//g' | tr -d '\n' | head -c 200)
    prompt_tok=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
    compl_tok=$(echo "$response" | jq -r '.usage.completion_tokens // 0')

    printf '%s|%s|%s|%s|%s|%s|%s' \
        "$total_ms" "$prompt_tok" "$compl_tok" "$finish_reason" "$tool_name" "$tool_args" "$content"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    if ! command -v jq &>/dev/null; then
        err "jq is required. Install with: apt install jq"
        exit 1
    fi

    local num_prompts=${#TEST_NAMES[@]}
    local total_requests=$((num_prompts * REPS))

    log "HA Voice Pipeline Benchmark"
    log "Container: $CONTAINER"
    log "Port: $PORT"
    log "Prompts: $num_prompts | Temp: $TEMPERATURE | Reps: $REPS"
    log "Total requests: $total_requests (+ $WARMUP_REQUESTS warmup)"
    log "Results: $OUTPUT_FILE"
    echo ""

    # ── Write markdown header ──
    {
        echo "# HA Voice Pipeline Benchmark"
        echo ""
        echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Host:** $(hostname)"
        echo "**GPU:** $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo 'N/A')"
        echo "**Container:** $CONTAINER"
        echo "**Port:** $PORT"
        echo "**Reps per prompt:** $REPS"
        echo "**Temperature:** $TEMPERATURE"
        echo "**Sampling:** top_p=$TOP_P top_k=$TOP_K min_p=$MIN_P presence_penalty=$PRESENCE_PENALTY repeat_penalty=$REPEAT_PENALTY"
        echo ""
    } > "$OUTPUT_FILE"

    # ── Warmup ──
    log "Warming up ($WARMUP_REQUESTS requests)..."
    for (( w=1; w<=WARMUP_REQUESTS; w++ )); do
        local warmup_result
        warmup_result=$(send_prompt "hello" "$TEMPERATURE")
        if [[ $w -eq 1 ]]; then
            local warmup_ptok
            warmup_ptok=$(echo "$warmup_result" | cut -d'|' -f2)
            log "Prompt token count: $warmup_ptok"
        fi
        printf "  warmup %d/%d done\n" "$w" "$WARMUP_REQUESTS"
    done
    log "Warmup complete"
    echo ""

    # ── Write results table header ──
    {
        echo "## $CONTAINER — temp=$TEMPERATURE"
        echo ""
        echo "| # | Test | Command | Avg (ms) | Min (ms) | Max (ms) | Accuracy | Tool Called | Args |"
        echo "|---|------|---------|----------|----------|----------|----------|-------------|------|"
    } >> "$OUTPUT_FILE"

    local total_correct=0
    local total_reps=0

    # ── Run tests ──
    for (( i=0; i<num_prompts; i++ )); do
        local test_name="${TEST_NAMES[$i]}"
        local test_cmd="${TEST_COMMANDS[$i]}"
        local expect_tool="${TEST_EXPECT_TOOL[$i]}"
        local expect_script="${TEST_EXPECT_SCRIPT[$i]}"
        local alt_accept="${TEST_ALT_ACCEPT[$i]}"

        log "[$((i+1))/$num_prompts] \"$test_cmd\" (temp=$TEMPERATURE)"

        local sum_ms=0
        local min_ms=999999
        local max_ms=0
        local reps_correct=0
        local last_tool=""
        local last_args=""

        for (( r=1; r<=REPS; r++ )); do
            local result
            result=$(send_prompt "$test_cmd" "$TEMPERATURE")

            local t_ms tool args
            t_ms=$(echo "$result" | cut -d'|' -f1)
            tool=$(echo "$result" | cut -d'|' -f5)
            args=$(echo "$result" | cut -d'|' -f6)

            sum_ms=$((sum_ms + t_ms))
            (( t_ms < min_ms )) && min_ms=$t_ms
            (( t_ms > max_ms )) && max_ms=$t_ms
            last_tool=$tool
            last_args=$args

            # ── Check correctness ──
            local rep_ok=true

            # Tool name check
            local tool_ok=false
            if [[ "$tool" == "$expect_tool" ]]; then
                tool_ok=true
            elif [[ "$expect_tool" == "HassRunScript" && "$tool" == "HassTurnOn" ]]; then
                tool_ok=true
            fi
            [[ "$tool_ok" != "true" ]] && rep_ok=false

            # Script name check (normalize script. prefix)
            if [[ -n "$expect_script" ]]; then
                local norm_expect="${expect_script#script.}"
                local norm_actual
                norm_actual=$(echo "$args" | sed 's/script\.//')
                if ! echo "$norm_actual" | grep -q "$norm_expect"; then
                    rep_ok=false
                fi
            fi

            # Alt accept patterns
            if [[ "$rep_ok" != "true" && -n "$alt_accept" ]]; then
                IFS='|' read -ra alt_patterns <<< "$alt_accept"
                for alt in "${alt_patterns[@]}"; do
                    local alt_tool="${alt%%:*}"
                    local alt_pattern="${alt#*:}"
                    if [[ "$tool" == "$alt_tool" ]] && echo "$args" | grep -iq "$alt_pattern"; then
                        rep_ok=true
                        break
                    fi
                done
            fi

            if [[ "$rep_ok" == "true" ]]; then
                reps_correct=$((reps_correct + 1))
                printf "  rep %d/%d: \033[32m%dms\033[0m | %s(%s)\n" "$r" "$REPS" "$t_ms" "$tool" "$args"
            else
                printf "  rep %d/%d: \033[31m%dms\033[0m | %s(%s) ← WRONG\n" "$r" "$REPS" "$t_ms" "$tool" "$args"
            fi
        done

        local avg_ms=$((sum_ms / REPS))
        local accuracy="${reps_correct}/${REPS}"
        total_correct=$((total_correct + reps_correct))
        total_reps=$((total_reps + REPS))

        if [[ "$reps_correct" -eq "$REPS" ]]; then
            ok "$test_name → ${accuracy} | avg ${avg_ms}ms"
        elif [[ "$reps_correct" -gt 0 ]]; then
            warn "$test_name → ${accuracy} | avg ${avg_ms}ms"
        else
            fail "$test_name → ${accuracy} | avg ${avg_ms}ms"
        fi

        local safe_args
        safe_args=$(echo "$last_args" | sed 's/|/\\|/g' | tr -d '\n')
        echo "| $((i+1)) | $test_name | $test_cmd | $avg_ms | $min_ms | $max_ms | $accuracy | $last_tool | \`$safe_args\` |" >> "$OUTPUT_FILE"
    done

    # ── Summary ──
    local pct=0
    [[ $total_reps -gt 0 ]] && pct=$((total_correct * 100 / total_reps))

    {
        echo ""
        echo "**Result:** $total_correct/$total_reps correct ($pct%)"
        echo ""
    } >> "$OUTPUT_FILE"

    echo ""
    log "══════════════════════════════════════════════"
    log "  $CONTAINER: $total_correct/$total_reps correct ($pct%)"
    log "  Results: $OUTPUT_FILE"
    log "══════════════════════════════════════════════"
}

main "$@"
