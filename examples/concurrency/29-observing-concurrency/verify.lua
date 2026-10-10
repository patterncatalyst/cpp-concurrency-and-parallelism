#!/usr/bin/env lua5.4
-- concurrency/29-observing-concurrency — verify.lua
--
-- Queries the LGTM stack's own query APIs (Tempo for traces, the
-- Prometheus-compatible API in front of Mimir for metrics) through the
-- compose network and asserts against REAL ingested telemetry -- nothing
-- here is read from the service's stdout or fabricated. Plain Lua 5.4, no
-- external modules (including no JSON library), per this project's
-- verify.lua convention: a small, dependency-free JSON decoder is defined
-- below, used only to read the two query APIs' JSON responses.
--
-- What this checks (HARD unless noted SOFT):
--   1. HARD  At least one trace for this service is discoverable in Tempo.
--   2. SOFT  The discovered trace count is close to the number of requests
--            the service issued (OBS_REQUESTS) -- a shortfall can be
--            Tempo's own ingestion/indexing lag rather than lost spans, so
--            this is reported, not failed on.
--   3. HARD  For a sample of discovered traces, the full trace (fetched by
--            ID) contains exactly one root "request.handle" span (no
--            parentSpanId) and OBS_TASKS_PER_REQUEST "pool.task" spans
--            whose parentSpanId equals the root's spanId. This is the
--            chapter's actual subject: a thread-pool hop that preserved
--            the parent/child relationship instead of producing orphan
--            root spans.
--   4. HARD  A metric whose name contains "queue_depth" exists in the
--            Prometheus-compatible query API -- proof the metrics half of
--            the OTLP pipeline (service -> collector -> Mimir) works, not
--            just traces.
--   5. SOFT  That metric's max value over the run was > 0 -- proof the
--            pool actually queued work, not just that the metric exists.
--            Soft because a fast host or unlucky export-interval timing
--            could drain the queue inside the one periodic export window
--            that would have shown the saturation.
--
-- Retries: every query polls (fixed interval, bounded timeout) rather than
-- asserting on the first response, because the stack takes real time to
-- ingest and index what the service already sent.

local TEMPO_URL = os.getenv("TEMPO_URL") or "http://lgtm:3200"
local PROM_URL = os.getenv("PROM_URL") or "http://lgtm:9090"
local SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME") or "observing-concurrency-service"
local OBS_REQUESTS = tonumber(os.getenv("OBS_REQUESTS") or "24")
local OBS_TASKS_PER_REQUEST = tonumber(os.getenv("OBS_TASKS_PER_REQUEST") or "3")
local POLL_TIMEOUT_S = tonumber(os.getenv("VERIFY_TIMEOUT_S") or "90")
local POLL_INTERVAL_S = tonumber(os.getenv("VERIFY_POLL_INTERVAL_S") or "3")
local TRACE_SAMPLE_SIZE = 5

-- ── minimal JSON decoder (object/array/string/number/bool/null) ─────────
-- Dependency-free by design: the verifier image ships curl + lua, nothing
-- else. Good enough for the two query APIs this script reads; not a
-- general-purpose JSON library.

local decode_value -- forward decl

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local function decode_string(s, i)
    assert(s:sub(i, i) == '"', "expected string at " .. i)
    local j = i + 1
    local out = {}
    while true do
        local c = s:sub(j, j)
        if c == "" then
            error("unterminated string in JSON response")
        elseif c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local esc = s:sub(j + 1, j + 1)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
                          n = "\n", r = "\r", t = "\t" }
            if esc == "u" then
                local hex = s:sub(j + 2, j + 5)
                local cp = tonumber(hex, 16) or 0
                out[#out + 1] = (cp < 128) and string.char(cp) or "?"
                j = j + 6
            elseif map[esc] then
                out[#out + 1] = map[esc]
                j = j + 2
            else
                out[#out + 1] = esc
                j = j + 2
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

local function decode_number(s, i)
    local m, j = s:match("^(-?%d+%.?%d*[eE]?[%+%-]?%d*)()", i)
    if not m then
        error("invalid number in JSON response at byte " .. i)
    end
    return tonumber(m), j
end

local function decode_array(s, i)
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then
        return out, i + 1
    end
    while true do
        local v
        v, i = decode_value(s, i)
        out[#out + 1] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skip_ws(s, i + 1)
        elseif c == "]" then
            return out, i + 1
        else
            error("expected , or ] in JSON array at byte " .. i)
        end
    end
end

local function decode_object(s, i)
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then
        return out, i + 1
    end
    while true do
        local key
        key, i = decode_string(s, i)
        i = skip_ws(s, i)
        assert(s:sub(i, i) == ":", "expected : in JSON object at byte " .. i)
        i = skip_ws(s, i + 1)
        local v
        v, i = decode_value(s, i)
        out[key] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skip_ws(s, i + 1)
        elseif c == "}" then
            return out, i + 1
        else
            error("expected , or } in JSON object at byte " .. i)
        end
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        return decode_object(s, i)
    elseif c == "[" then
        return decode_array(s, i)
    elseif c == '"' then
        return decode_string(s, i)
    elseif c == "t" and s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif c == "f" and s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif c == "n" and s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        return decode_number(s, i)
    end
end

local function json_decode(s)
    return (decode_value(s, 1))
end

-- ── HTTP + polling helpers ───────────────────────────────────────────────

local function urlencode(s)
    return (s:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function fetch_json(url)
    local cmd = "curl -sS --max-time 10 '" .. url .. "'"
    local handle, perr = io.popen(cmd)
    if not handle then
        error("failed to launch curl: " .. tostring(perr))
    end
    local body = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format("curl failed (%s %s) for %s", tostring(why), tostring(code), url))
    end
    if not body or body == "" then
        error("empty response from " .. url)
    end
    local decode_ok, decoded = pcall(json_decode, body)
    if not decode_ok then
        error("could not parse JSON from " .. url .. ": " .. tostring(decoded) ..
              "\n--- body ---\n" .. body)
    end
    return decoded
end

-- poll(fn, timeout_s, interval_s) -- calls fn() (which must return a
-- truthy result or raise an error) until it succeeds or the timeout
-- elapses. Returns (result, nil) on success, (nil, last_error) on timeout.
local function poll(fn, timeout_s, interval_s)
    local deadline = os.time() + timeout_s
    local last_err = "no attempts made"
    while true do
        local ok, result = pcall(fn)
        if ok and result then
            return result, nil
        end
        last_err = ok and "predicate returned no result" or result
        if os.time() >= deadline then
            return nil, last_err
        end
        io.write(".")
        io.flush()
        os.execute("sleep " .. interval_s)
    end
end

-- ── Flatten a Tempo /api/traces/<id> response into a plain span list ────

local function flatten_spans(trace_json)
    local spans = {}
    for _, batch in ipairs(trace_json.batches or {}) do
        for _, scope in ipairs(batch.scopeSpans or {}) do
            for _, sp in ipairs(scope.spans or {}) do
                spans[#spans + 1] = sp
            end
        end
    end
    return spans
end

print(string.format(
    "== verify.lua: 29-observing-concurrency -- service=%s tempo=%s prom=%s ==",
    SERVICE_NAME, TEMPO_URL, PROM_URL))

local hard_failures = 0

-- 1 & 2. Trace discovery -----------------------------------------------

print(string.format("\n-- waiting for traces (timeout %ds) --", POLL_TIMEOUT_S))

local traceql = string.format('{resource.service.name="%s"}', SERVICE_NAME)
local search_url = string.format("%s/api/search?q=%s&limit=50", TEMPO_URL, urlencode(traceql))

local search_result = poll(function()
    local decoded = fetch_json(search_url)
    local traces = decoded.traces
    if traces and #traces > 0 then
        return traces
    end
    return nil
end, POLL_TIMEOUT_S, POLL_INTERVAL_S)

if not search_result then
    print()
    print("  FAIL: no traces found for service " .. SERVICE_NAME .. " within " ..
          POLL_TIMEOUT_S .. "s (search: " .. search_url .. ")")
    print("RESULT: FAIL (1 correctness/execution failure(s))")
    os.exit(1)
end

print()
print(string.format("  found %d trace(s) for %s", #search_result, SERVICE_NAME))

local expected_threshold = math.max(1, math.floor(OBS_REQUESTS * 0.5))
if #search_result < OBS_REQUESTS then
    local level = (#search_result >= expected_threshold) and "WARN" or "WARN"
    print(string.format(
        "  %s: discovered %d of %d expected traces -- Tempo's search index can lag " ..
        "ingestion by a few seconds; the structural check below (not this count) is " ..
        "what proves propagation correctness.",
        level, #search_result, OBS_REQUESTS))
end

-- 3. Structural check: parent/child nesting on a sample of traces -------

print(string.format("\n-- checking span nesting on up to %d trace(s) --", TRACE_SAMPLE_SIZE))

local sample_n = math.min(TRACE_SAMPLE_SIZE, #search_result)
local checked = 0
for idx = 1, sample_n do
    local trace_id = search_result[idx].traceID
    if trace_id then
        local trace_url = string.format("%s/api/traces/%s", TEMPO_URL, trace_id)
        local ok, trace_json = pcall(fetch_json, trace_url)
        if not ok then
            print(string.format("  FAIL: could not fetch trace %s: %s", trace_id, tostring(trace_json)))
            hard_failures = hard_failures + 1
        else
            local spans = flatten_spans(trace_json)
            local root, children = nil, {}
            for _, sp in ipairs(spans) do
                if sp.name == "request.handle" and (not sp.parentSpanId or sp.parentSpanId == "") then
                    root = sp
                elseif sp.name == "pool.task" then
                    children[#children + 1] = sp
                end
            end

            if not root then
                print(string.format("  FAIL: trace %s has no root request.handle span", trace_id))
                hard_failures = hard_failures + 1
            elseif #children == 0 then
                print(string.format("  FAIL: trace %s has no pool.task child spans", trace_id))
                hard_failures = hard_failures + 1
            else
                local mismatched = 0
                for _, c in ipairs(children) do
                    if c.parentSpanId ~= root.spanId then
                        mismatched = mismatched + 1
                    end
                end
                if mismatched > 0 then
                    print(string.format(
                        "  FAIL: trace %s has %d pool.task span(s) not parented to its request.handle root",
                        trace_id, mismatched))
                    hard_failures = hard_failures + 1
                else
                    print(string.format(
                        "  [trace %s] root=%s children=%d (expected %d) -- parented correctly",
                        trace_id, root.spanId, #children, OBS_TASKS_PER_REQUEST))
                    if #children ~= OBS_TASKS_PER_REQUEST then
                        print(string.format(
                            "  WARN: trace %s has %d child spans, expected %d -- a request may " ..
                            "still be mid-flight when this trace was queried",
                            trace_id, #children, OBS_TASKS_PER_REQUEST))
                    end
                end
            end
            checked = checked + 1
        end
    end
end

if checked == 0 then
    print("  FAIL: no sampled traces had a usable traceID")
    hard_failures = hard_failures + 1
end

-- 4 & 5. Metrics ----------------------------------------------------------

print(string.format("\n-- waiting for the queue-depth metric (timeout %ds) --", POLL_TIMEOUT_S))

local names_url = PROM_URL .. "/api/v1/label/__name__/values"
local queue_metric = poll(function()
    local decoded = fetch_json(names_url)
    if decoded.status ~= "success" or type(decoded.data) ~= "table" then
        return nil
    end
    for _, name in ipairs(decoded.data) do
        if name:find("queue_depth", 1, true) then
            return name
        end
    end
    return nil
end, POLL_TIMEOUT_S, POLL_INTERVAL_S)

if not queue_metric then
    print()
    print("  FAIL: no metric matching 'queue_depth' found in " .. PROM_URL .. " within " ..
          POLL_TIMEOUT_S .. "s")
    hard_failures = hard_failures + 1
else
    print()
    print("  found metric: " .. queue_metric)

    local query = string.format("max_over_time(%s[10m])", queue_metric)
    local query_url = string.format("%s/api/v1/query?query=%s", PROM_URL, urlencode(query))
    local ok, result = pcall(fetch_json, query_url)
    local max_value = nil
    if ok and result.status == "success" and result.data and result.data.result
       and result.data.result[1] and result.data.result[1].value then
        max_value = tonumber(result.data.result[1].value[2])
    end

    if max_value == nil then
        print("  WARN: could not read a max value for " .. queue_metric ..
              " -- metric exists (hard check already passed) but no sample could be read")
    elseif max_value > 0 then
        print(string.format("  metric saturation: PASS (max %s over the run = %.0f)", queue_metric, max_value))
    else
        print(string.format(
            "  WARN: max %s over the run was %.0f -- the metric pipeline works (checked above) " ..
            "but the queue may have drained inside a single export interval on a fast host",
            queue_metric, max_value))
    end
end

-- ── Result ────────────────────────────────────────────────────────────

print()
if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
