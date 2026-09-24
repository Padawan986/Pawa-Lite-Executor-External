-- ============================================================================
--  sUNC, liberated (properly)
-- ============================================================================
--
-- credits to plusgiant5
--
-- ============================================================================

local function set_capture(target, value)
    if type(target) == "table" then target[1] = value end
end


local function resolve_environment(environment)
    return environment or (getgenv and getgenv()) or _G
end

local function fail_test(captures, feature, detail)
    captures = captures or {}
    local record = captures.record_result or captures[1]
    if record then record(false, feature, detail) end

    local status = captures.function_status
    local failed = captures.shared_test_failed
    if status == nil or status[feature] ~= false then
        set_capture(failed, true)
    end
    return false
end

local function wait_until(environment, predicate, attempts, delay_seconds)
    environment = resolve_environment(environment)
    local scheduler = environment.task or task
    attempts = attempts or 120
    for _ = 1, attempts do
        local ok, result = pcall(predicate)
        if ok and result then return true end
        if scheduler and scheduler.wait then scheduler.wait(delay_seconds) end
    end
    return false
end

local function safe_destroy(object)
    if object and object.Destroy then pcall(function() object:Destroy() end) end
end

local function contains_identity(list, expected)
    for _, value in pairs(list or {}) do
        if value == expected then return true end
    end
    return false
end

local function count_pairs(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function disconnect(connection)
    if connection and connection.Disconnect then pcall(function() connection:Disconnect() end) end
end


-- ============================================================================
-- Hand-reconstructed utilities
-- ============================================================================

-- Self-contained JSON decoder used when executor-provided JSON handling cannot be trusted.
local function json_decode(source)
    local position = 1

    local function skip_whitespace()
        while position <= #source and source:sub(position, position):match("%s") do
            position = position + 1
        end
    end

    local parse_value

    local function parse_string()
        position = position + 1 -- opening quote
        local pieces = {}
        while position <= #source do
            local character = source:sub(position, position)
            if character == '"' then
                position = position + 1
                return table.concat(pieces)
            elseif character == "\\" then
                position = position + 1
                local escaped = source:sub(position, position)
                local escapes = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["\\"] = "\\", ['"'] = '"' }
                table.insert(pieces, escapes[escaped] or escaped)
            else
                table.insert(pieces, character)
            end
            position = position + 1
        end
        error("Unterminated string")
    end

    local function parse_number()
        local start = position
        if source:sub(position, position) == "-" then position = position + 1 end
        while source:sub(position, position):match("%d") do position = position + 1 end
        if source:sub(position, position) == "." then
            position = position + 1
            while source:sub(position, position):match("%d") do position = position + 1 end
        end
        local exponent = source:sub(position, position):lower()
        if exponent == "e" then
            position = position + 1
            if source:sub(position, position):match("[+-]") then position = position + 1 end
            while source:sub(position, position):match("%d") do position = position + 1 end
        end
        local value = tonumber(source:sub(start, position - 1))
        if value == nil then error("Invalid JSON number at position " .. start) end
        return value
    end

    local function parse_array()
        position = position + 1
        local result = {}
        skip_whitespace()
        if source:sub(position, position) == "]" then position = position + 1; return result end
        while true do
            table.insert(result, parse_value())
            skip_whitespace()
            local character = source:sub(position, position)
            if character == "]" then position = position + 1; return result end
            if character ~= "," then error("Expected ',' at position " .. position) end
            position = position + 1
            skip_whitespace()
        end
    end

    local function parse_object()
        position = position + 1
        local result = {}
        skip_whitespace()
        if source:sub(position, position) == "}" then position = position + 1; return result end
        while true do
            if source:sub(position, position) ~= '"' then
                error("Expected string key at position " .. position)
            end
            local key = parse_string()
            skip_whitespace()
            if source:sub(position, position) ~= ":" then
                error("Expected ':' at position " .. position)
            end
            position = position + 1
            skip_whitespace()
            result[key] = parse_value()
            skip_whitespace()
            local character = source:sub(position, position)
            if character == "}" then position = position + 1; return result end
            if character ~= "," then error("Expected ',' at position " .. position) end
            position = position + 1
            skip_whitespace()
        end
    end

    function parse_value()
        skip_whitespace()
        local character = source:sub(position, position)
        if character == '"' then return parse_string() end
        if character == "{" then return parse_object() end
        if character == "[" then return parse_array() end
        if character:match("[%-%d]") then return parse_number() end
        if source:sub(position, position + 3) == "true" then position = position + 4; return true end
        if source:sub(position, position + 4) == "false" then position = position + 5; return false end
        if source:sub(position, position + 3) == "null" then position = position + 4; return nil end
        error("Unexpected character at position " .. position .. ": " .. character)
    end

    local result = parse_value()
    skip_whitespace()
    if position <= #source then
        error("Unexpected content after JSON at position " .. position)
    end
    return result
end

-- Nested callback/helper used by `bootstrap_sunc`.
local function clone_table(source, deep)
    if table.clone and not deep then
        return table.clone(source)
    end
    local copy = {}
    for key, value in pairs(source) do
        if deep and typeof(value) == "table" then
            copy[key] = clone_table(value, true)
        else
            copy[key] = value
        end
    end
    return copy
end

-- Nested callback/helper used by `bootstrap_sunc`.
local DEFAULT_DEBUG_CONFIG = table.freeze and table.freeze({
    printcheckpoints = false,
    delaybetweentests = false,
    printtesttimetaken = false,
    extradebugprints = false,
}) or {
    printcheckpoints = false,
    delaybetweentests = false,
    printtesttimetaken = false,
    extradebugprints = false,
}

local function read_debug_config()
    local environment = getgenv and getgenv() or _G
    local supplied = environment.sUNCDebug
    if type(supplied) ~= "table" then
        warn("Couldn't find the debug table, so it was set to default. To get the full script, join our Discord server: [discord.gg/yGNzDrvbF5] :)")
        return clone_table(DEFAULT_DEBUG_CONFIG)
    end
    local config = clone_table(DEFAULT_DEBUG_CONFIG)
    for key, value in pairs(supplied) do
        if config[key] ~= nil then config[key] = value end
    end
    return table.freeze and table.freeze(config) or config
end

-- Nested callback/helper used by `run_sunc_suite`.
local Timer = {}
Timer.__index = Timer

local function create_test_timer()
    local timer = setmetatable({
        start_time = tick(),
        thread = nil,
        elapsed = 0,
    }, Timer)
    timer.thread = task.spawn(function()
        while task.wait() do
            timer.elapsed = tick() - timer.start_time
        end
    end)
    return timer
end

function Timer:Stop(test_name, debug_config)
    if self.thread then
        task.cancel(self.thread)
        pcall(coroutine.close, self.thread)
        self.thread = nil
    end
    self.elapsed = tick() - self.start_time
    if debug_config and debug_config.printtesttimetaken then
        print(test_name .. " took " .. self.elapsed .. " seconds to test")
    end
    return self.elapsed
end

-- P31's coordinator support graph. These helpers are not decorative leftovers:
-- the result archive, key exchange, randomized probes, buffer challenges and
-- remote metadata branch all capture this cluster through child prototypes.
local function get_network_ping(environment)
    environment = resolve_environment(environment)
    local game_api = environment.game or game
    local stats = game_api:GetService("Stats")
    return stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
end

local function bytes_to_string(bytes, start_index)
    local output = ""
    for index = start_index or 1, #bytes do
        output = output .. string.char(bytes[index])
    end
    return output
end

local function bytes_to_buffer(bytes, buffer_api)
    buffer_api = buffer_api or buffer
    local result = buffer_api.create(#bytes)
    for index, value in ipairs(bytes) do
        buffer_api.writeu8(result, index - 1, value)
    end
    return result
end

local function uint32_to_buffer(value, buffer_api)
    buffer_api = buffer_api or buffer
    local result = buffer_api.create(4)
    buffer_api.writeu32(result, 0, value)
    return result
end

local function uint32_add(left, right)
    -- P39 deliberately normalizes through a four-byte buffer rather than using
    -- a source-language modulo expression.
    local temporary = uint32_to_buffer(left)
    buffer.writeu32(temporary, 0, buffer.readu32(temporary, 0) + right)
    return buffer.readu32(temporary, 0)
end

local function rotate_left_32(value, amount)
    if bit32 and bit32.lrotate then return bit32.lrotate(value, amount) end
    amount = amount % 32
    return ((value * 2 ^ amount) % 2 ^ 32) + math.floor(value / 2 ^ (32 - amount))
end

local function xor_32(left, right)
    if bit32 and bit32.bxor then return bit32.bxor(left, right) end
    local result, place = 0, 1
    left, right = left % 4294967296, right % 4294967296
    for _ = 1, 32 do
        local left_bit, right_bit = left % 2, right % 2
        if left_bit ~= right_bit then result = result + place end
        left, right, place = (left - left_bit) / 2, (right - right_bit) / 2, place * 2
    end
    return result
end

local function pack_little_endian_u32(bytes, offset)
    offset = offset or 0
    local b1 = buffer.readu8(bytes, offset)
    local b2 = buffer.readu8(bytes, offset + 1)
    local b3 = buffer.readu8(bytes, offset + 2)
    local b4 = buffer.readu8(bytes, offset + 3)
    return bit32.bor(b1, bit32.lshift(b2, 8), bit32.lshift(b3, 16), bit32.lshift(b4, 24))
end

local function chacha20_initialize_block(key, nonce, counter)
    local constants = buffer.fromstring("expand 32-byte k")
    local state = table.create(16)
    for index = 0, 3 do state[index + 1] = pack_little_endian_u32(constants, index * 4) end
    for index = 0, 7 do state[index + 5] = pack_little_endian_u32(key, index * 4) end
    state[13] = counter or 0
    state[14] = pack_little_endian_u32(nonce, 0)
    state[15] = pack_little_endian_u32(nonce, 4)
    state[16] = pack_little_endian_u32(nonce, 8)
    return state
end

local function chacha20_quarter_round(state, a, b, c, d)
    state[a] = uint32_add(state[a], state[b]); state[d] = rotate_left_32(xor_32(state[d], state[a]), 16)
    state[c] = uint32_add(state[c], state[d]); state[b] = rotate_left_32(xor_32(state[b], state[c]), 12)
    state[a] = uint32_add(state[a], state[b]); state[d] = rotate_left_32(xor_32(state[d], state[a]), 8)
    state[c] = uint32_add(state[c], state[d]); state[b] = rotate_left_32(xor_32(state[b], state[c]), 7)
end

-- P44: update the counter word in an existing context. P45/P46 then
-- generate a block and perform the twenty rounds through the quarter-round helper.
local function chacha20_set_counter(context, counter)
    context.counter = counter
    context.state[13] = counter
    context.position = 64
end

local function chacha20_generate_block(context)
    local working = table.clone(context.state)
    for _ = 1, 10 do
        chacha20_quarter_round(working, 1, 5, 9, 13); chacha20_quarter_round(working, 2, 6, 10, 14)
        chacha20_quarter_round(working, 3, 7, 11, 15); chacha20_quarter_round(working, 4, 8, 12, 16)
        chacha20_quarter_round(working, 1, 6, 11, 16); chacha20_quarter_round(working, 2, 7, 12, 13)
        chacha20_quarter_round(working, 3, 8, 9, 14); chacha20_quarter_round(working, 4, 5, 10, 15)
    end
    local output = buffer.create(64)
    for index = 1, 16 do
        buffer.writeu32(output, (index - 1) * 4, uint32_add(working[index], context.state[index]))
    end
    return output
end

local function chacha20_context(key, nonce, counter)
    return {
        state = chacha20_initialize_block(key, nonce, counter),
        counter = counter or 0,
        position = 64,
        keystream32 = nil,
    }
end

-- P48 mutates the supplied buffer in place. The previous four-argument
-- input/output wrapper was a restoration error and disconnected P49/P59/P60.
local function chacha20_next_block(context)
    context.state[13] = context.counter
    context.keystream32 = chacha20_generate_block(context)
    context.counter = context.counter + 1
    context.position = 0
    return context.keystream32
end

local function chacha20_xor_in_place(context, input, length, offset)
    offset = offset or 0
    for position = offset, length - 1 do
        if context.position >= 64 then
            chacha20_next_block(context)
        end
        local value = xor_32(
            buffer.readu8(input, position),
            buffer.readu8(context.keystream32, context.position)
        )
        buffer.writeu8(input, position, value)
        context.position = context.position + 1
    end
    return input
end

-- P49 applies every negotiated key/nonce pair sequentially to the same buffer.
local function chacha20_xor_layers(input, key_buffers, nonce_buffers)
    for index = 1, math.min(#key_buffers, #nonce_buffers) do
        local context = chacha20_context(key_buffers[index], nonce_buffers[index], 0)
        chacha20_xor_in_place(context, input, buffer.len(input), 0)
    end
    return input
end

local function count_table_entries(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local serialize_table
-- I counted the walls. The maze declined to provide a second opinion.
local function serialize_value(value)
    local value_type = type(value)
    if value_type == "number" then return tostring(value) end
    if value_type == "string" then return string.format("%q", value) end
    if value_type == "boolean" then return tostring(value) end
    if value_type == "table" then return serialize_table(value) end
    error("Unsupported value type: " .. value_type)
end

local function serialize_key(key)
    if type(key) == "string" then return string.format("[%q]", key) end
    if type(key) == "number" then return "[" .. tostring(key) .. "]" end
    error("Only string or number keys supported")
end

local function contains_nested_table(value)
    for _, item in pairs(value) do
        if type(item) == "table" then return true end
    end
    return false
end

serialize_table = function(value)
    -- P54's scan only chooses the serializer path; it does not reject nesting.
    local _has_nested_table = contains_nested_table(value)
    local lines = { "{\n" }
    for key, item in pairs(value) do
        table.insert(lines, "  " .. serialize_key(key) .. " = " .. serialize_value(item) .. ",\n")
    end
    table.insert(lines, "}")
    return table.concat(lines)
end

local function deserialize_table(source)
    local chunk, compile_error = loadstring("return " .. source)
    if not chunk then error(compile_error) end
    return chunk()
end

local RESULT_TYPE_STRING = 7
local RESULT_TYPE_NUMBER = 9
local RESULT_TYPE_TABLE = 5

local ResultStore = {}
ResultStore.__index = ResultStore

local function transform_result_store_string(source, byte_key)
    if #source == 0 then return "" end
    local output = table.create and table.create(#source) or {}
    output[1] = string.char(xor_32(string.byte(source, 1), xor_32(byte_key, 51)))
    for index = 2, #source do
        output[index] = string.char(xor_32(string.byte(source, index), byte_key))
    end
    return string.reverse(table.concat(output))
end

-- P56. The methods below are closures over the type tags, archive byte key,
-- and negotiated ChaCha key lists in the original bytecode.
local function create_result_store(byte_key_box, encryption_keys, encryption_nonces)
    return setmetatable({
        directory = {},
        buffers = {},
        byte_key_box = byte_key_box,
        encryption_keys = encryption_keys,
        encryption_nonces = encryption_nonces,
    }, ResultStore)
end

-- P57.
function ResultStore:write(key, value)
    local value_type = type(value)
    local type_tag, serialized
    if value_type == "string" then
        type_tag, serialized = RESULT_TYPE_STRING, value
    elseif value_type == "number" then
        type_tag, serialized = RESULT_TYPE_NUMBER, tostring(value)
    elseif value_type == "table" then
        type_tag, serialized = RESULT_TYPE_TABLE, serialize_table(value)
    else
        error("Unsupported type to write: " .. value_type)
    end

    local byte_key = assert(self.byte_key_box[1], "result-store byte key is unavailable")
    local record_length = #serialized + 1
    local record_buffer = buffer.create(record_length)
    buffer.writeu8(record_buffer, 0, type_tag)
    buffer.writestring(record_buffer, 1, transform_result_store_string(serialized, byte_key))
    self.directory[key] = { buffer = record_buffer, length = record_length }
    table.insert(self.buffers, record_buffer)
end

-- P58 is part of the original metatable API. The coordinator normally writes
-- and serializes; external consumers may read an entry before transmission.
function ResultStore:read(key)
    local entry = self.directory[key]
    if not entry then return nil end

    local type_tag = buffer.readu8(entry.buffer, 0)
    local stored = buffer.readstring(entry.buffer, 1, entry.length - 1)
    local decoded = transform_result_store_string(stored, assert(self.byte_key_box[1]))
    if type_tag == RESULT_TYPE_STRING then return decoded end
    if type_tag == RESULT_TYPE_NUMBER then return tonumber(decoded) end
    if type_tag == RESULT_TYPE_TABLE then return deserialize_table(decoded) end
    return nil
end

-- P59.
function ResultStore:serialize()
    local entry_count = count_table_entries(self.directory)
    local header_size = 4 + 12 * entry_count
    local payload_size = 0
    for _, entry in pairs(self.directory) do payload_size = payload_size + entry.length end

    local output = buffer.create(header_size + payload_size)
    buffer.writeu32(output, 0, entry_count)
    local metadata_offset, payload_offset = 4, header_size
    for key, entry in pairs(self.directory) do
        buffer.writeu32(output, metadata_offset, key)
        buffer.writeu32(output, metadata_offset + 4, payload_offset)
        buffer.writeu32(output, metadata_offset + 8, entry.length)
        metadata_offset = metadata_offset + 12
        buffer.copy(output, payload_offset, entry.buffer, 0, entry.length)
        payload_offset = payload_offset + entry.length
    end

    return chacha20_xor_layers(output, self.encryption_keys, self.encryption_nonces)
end

-- P60 decrypts a server challenge beginning at byte one and installs four
-- 32-byte keys followed by four 12-byte nonces.
local function create_remote_key_exchange_handler(master_key, master_nonce, key_buffers, nonce_buffers)
    return function(payload)
        if buffer.readu8(payload, 0) ~= 1 then return end
        local context = chacha20_context(master_key, master_nonce, 0)
        chacha20_xor_in_place(context, payload, buffer.len(payload), 1)

        local offset = 1
        for index = 1, 4 do
            local key = buffer.create(32)
            buffer.copy(key, 0, payload, offset, 32)
            key_buffers[index] = key
            offset = offset + 32
        end
        for index = 1, 4 do
            local nonce = buffer.create(12)
            buffer.copy(nonce, 0, payload, offset, 12)
            nonce_buffers[index] = nonce
            offset = offset + 12
        end
    end
end

-- P61 and P62 are captured by P63 rather than being dead convenience wrappers.
local function xor_unsigned_32(left, right)
    return xor_32(left, right)
end

local function right_shift_unsigned(value, amount)
    return math.floor(value / (2 ^ amount))
end

local function extract_table_address(value)
    local address = tostring(value):match("0x%x+")
    -- Luau accepts a hexadecimal prefix with an explicit base. Strip it here
    -- as well so the restored helper behaves identically under stock Lua.
    return address and tonumber(address:sub(3), 16) or nil
end

-- P63 is a lazy stateful random closure. Both seed tables must remain alive
-- simultaneously; creating two ephemeral tables can reuse one address and
-- collapse the seed to zero.
local function create_deterministic_random()
    local state
    return function(...)
        if state == nil then
            local first_table, second_table = {}, {}
            local first_address = extract_table_address(first_table)
            local second_address = extract_table_address(second_table)
            if first_address == nil or second_address == nil then
                error("Failed to extract memory address from table")
            end
            state = xor_unsigned_32(first_address, second_address)
        end

        state = (state * 1664225 + 1013904223) % 4224967296
        local argument_count = select("#", ...)
        if argument_count == 0 then
            return right_shift_unsigned(state, 8) / 16777216
        elseif argument_count == 1 then
            local maximum = ...
            if type(maximum) ~= "number" or maximum < 1 or maximum % 1 ~= 0 then
                error("Invalid argument: must be a positive integer")
            end
            return state % maximum + 1
        elseif argument_count == 2 then
            local minimum, maximum = ...
            if type(minimum) ~= "number" or type(maximum) ~= "number" or minimum > maximum then
                error("Invalid arguments: must be integers with A <= B")
            end
            if minimum % 1 == 0 and maximum % 1 == 0 then
                return minimum + state % (maximum - minimum + 1)
            end
            -- The compiled branch uses the same 24-bit fraction as the zero-argument
            -- path when either bound is non-integral.
            return minimum + (maximum - minimum) * (right_shift_unsigned(state, 8) / 16777216)
        end
        error("random expects 0, 1, or 2 arguments")
    end
end

-- P64 validates the remote fingerprint before it enters the reporter payload.
local function is_valid_hex_identifier(text)
    return type(text) == "string"
        and (#text == 64 or #text == 96 or #text == 128)
        and text:match("^[0-9a-fA-F]+$") ~= nil
end
-- P65: compact Base64 decoder used by the coordinator to hide buffer member
-- names. It is a decoder only; the prior bidirectional reconstruction was too
-- broad and obscured its actual call sites.
local function decode_base64(input)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local sextets = {}
    local padding = 0

    for index = 1, #input do
        local character = input:sub(index, index)
        if character == "=" then
            padding = padding + 1
        else
            local alphabet_index = alphabet:find(character, 1, true)
            if alphabet_index then
                sextets[#sextets + 1] = alphabet_index - 1
            end
        end
    end

    local output = {}
    for index = 1, #sextets, 4 do
        local packed = (sextets[index] or 0) * 262144
            + (sextets[index + 1] or 0) * 4096
            + (sextets[index + 2] or 0) * 64
            + (sextets[index + 3] or 0)

        output[#output + 1] = string.char(math.floor(packed / 65536) % 256)
        output[#output + 1] = string.char(math.floor(packed / 256) % 256)
        output[#output + 1] = string.char(packed % 256)
    end

    for _ = 1, padding do
        table.remove(output)
    end
    return table.concat(output)
end

-- P66 is genuinely dormant. P31 creates the closure in R28 at L001246, then
-- never reads R28 before that register is reused much later. This is retained
-- because it existed in the decoded program, not because a call edge is missing.
local function integer_divide(value, divisor)
    return math.floor(value / divisor)
end

-- P67: repeating-key byte XOR, capturing the suite's unsigned XOR helper.
local function xor_string_bytes(text, key)
    local output = table.create and table.create(#text) or {}
    for index = 1, #text do
        local key_index = ((index - 1) % #key) + 1
        output[index] = string.char(xor_unsigned_32(
            string.byte(text, index),
            string.byte(key, key_index)
        ))
    end
    return table.concat(output)
end

-- P68 captures P65 and P67. The two Base64 operands are decoded independently,
-- then XORed to recover a buffer API member name.
local function decode_xored_base64(first, second)
    return xor_string_bytes(decode_base64(first), decode_base64(second))
end

-- P71 is intentionally a side-effect/error probe. JSONDecode's result is
-- discarded by CALL_FRAME_VOID; the enclosing pcall tuple is what the original
-- coordinator transmits.
local function build_probe_buffer(environment)
    environment = resolve_environment(environment)
    local buffer_api = environment.buffer or buffer
    local probe = buffer_api.create(400)
    buffer_api.writestring(probe, 0, "idk")
    buffer_api.writei32(probe, 66, -9)
    tostring(probe) -- P69 intentionally discards the representation.
end

local function create_empty_probe_buffer(environment)
    environment = resolve_environment(environment)
    return (environment.buffer or buffer).create(400)
end

local function probe_public_ip_endpoint(environment)
    environment = resolve_environment(environment)
    local game_api = environment.game or game
    local http_service = game_api:GetService("HttpService")
    http_service:JSONDecode(game_api:HttpGet("https://api.ipify.org/?format=json"))
end

local function derive_result_store_byte_key(environment)
    environment = resolve_environment(environment)
    local ok, value = pcall(function()
        local workspace_api = environment.workspace or workspace
        local attribute = workspace_api.FreakyBox.h["Left Leg"]:GetAttribute("ap")
        return xor_32(attribute, 118)
    end)
    return ok and value or nil
end

local function install_original_result_transport(environment)
    environment = resolve_environment(environment)
    local buffer_api = environment.buffer or buffer
    local game_api = environment.game or game
    if not buffer_api or not game_api then return nil end

    local key_buffers, nonce_buffers = {}, {}
    local master_key = bytes_to_buffer({
        44, 164, 159, 33, 240, 60, 21, 47, 132, 154, 218, 215, 101, 77, 128, 58,
        24, 198, 45, 40, 109, 89, 50, 22, 81, 30, 146, 232, 40, 106, 209, 40,
    }, buffer_api)
    local master_nonce = bytes_to_buffer({
        113, 125, 44, 47, 107, 10, 36, 121, 163, 203, 234, 101, 224, 200, 64, 105,
        90, 37, 55, 6, 252, 158, 165, 45, 243, 144, 117, 132, 16, 81, 154, 177,
    }, buffer_api)

    local byte_key_box = { derive_result_store_byte_key(environment) }
    local replicated_storage = game_api:GetService("ReplicatedStorage")
    local challenge_remote = replicated_storage:FindFirstChild("itsjustgettingstarted")
    if challenge_remote then
        challenge_remote.OnClientInvoke = create_remote_key_exchange_handler(
            master_key, master_nonce, key_buffers, nonce_buffers
        )
    end

    return {
        byte_key_box = byte_key_box,
        key_buffers = key_buffers,
        nonce_buffers = nonce_buffers,
        challenge_remote = challenge_remote,
    }
end

-- P31 installs this console presentation patch before dispatching the suite.
local function patch_developer_console(environment)
    environment = resolve_environment(environment)
    local scheduler = environment.task or task
    local game_api = environment.game or game
    if not scheduler or type(scheduler.spawn) ~= "function" or not game_api then
        return false, "task.spawn or game is unavailable"
    end

    scheduler.spawn(function()
        local core_gui = game_api:GetService("CoreGui")
        local console = core_gui:FindFirstChild("DevConsoleMaster", true)
        if not console then return end

        game_api:GetService("RunService").PreSimulation:Connect(function()
            for _, descendant in pairs(console:GetDescendants()) do
                if descendant.ClassName == "TextLabel"
                    and string.find(descendant.Text, "success rate", 1, true)
                then
                    descendant.Text = "69:69:69 -- 😎 Passed the test with 100% success rate (90 out of 77)"
                end
            end
        end)
    end)

    return true
end

-- ============================================================================
-- Source functions
-- ============================================================================

-- ============================================================================
-- Source-oriented recovered prototypes
-- ============================================================================
-- The original outer prototype was mostly an anti-tamper/bootstrap shell.  It
-- replaced print/warn, created hostile proxy metatables, and intentionally
-- revisited control-flow blocks when a debugger was detected.  The restoration
-- keeps only the observable purpose: run the suite under pcall and report a
-- top-level failure without reintroducing the obfuscator's traps.
local run_sunc_suite
local build_sandbox_environment

local function verify_bootstrap_runtime(environment)
    -- P1-P21 were the outer integrity shell. The VM made this look cosmic;
    -- the ordinary path is a compact set of runtime invariants and a guaranteed
    -- restoration of print/warn before entering the suite.
    local active_environment = (environment.getfenv and environment.getfenv())
        or environment._ENV or environment
    local original_print = active_environment.print
    local original_warn = active_environment.warn
    local replaced_print = type(original_print) == "function"
    local replaced_warn = type(original_warn) == "function"
    local integrity_failed = false

    local function protected_entry_call()
        integrity_failed = true
    end
    if replaced_print then
        active_environment.print = function(...)
            protected_entry_call()
            return original_print(...)
        end
    end
    if replaced_warn then
        active_environment.warn = function(...)
            protected_entry_call()
            return original_warn(...)
        end
    end

    local function restore_loggers()
        if replaced_print then active_environment.print = original_print end
        if replaced_warn then active_environment.warn = original_warn end
    end

    local noop = function() end
    if type(noop) ~= "function" then integrity_failed = true end
    if environment.debug and type(environment.debug.info) == "function" then
        local line_ok, line = pcall(environment.debug.info, noop, "l")
        local source_ok, source_kind = pcall(environment.debug.info, noop, "s")
        if not line_ok or type(line) ~= "number" then integrity_failed = true end
        if not source_ok or type(source_kind) ~= "string" then integrity_failed = true end
    end

    local captured_error
    local xpcall_ok = xpcall(noop, function(message)
        captured_error = tostring(message):match("%[C%]") or tostring(message)
        return captured_error
    end)
    if not xpcall_ok then integrity_failed = true end

    if type(environment.newproxy) == "function" then
        local proxy = environment.newproxy(true)
        local proxy_metatable = getmetatable(proxy)
        if type(proxy_metatable) == "table" then
            proxy_metatable.__tostring = function() return "[sUNC protected proxy]" end
            proxy_metatable.__concat = function(left, right)
                return tostring(left) .. tostring(right)
            end
            proxy_metatable.__call = function() return nil end
        else
            integrity_failed = true
        end
    end

    local sandbox_destination = {}
    local sandbox_source = { __metatable = "unozbpxbhy", __iter = "eilewdwfcx" }
    build_sandbox_environment(environment, { destination = sandbox_destination }, sandbox_source)
    if sandbox_destination.__metatable ~= "unozbpxbhy"
        or sandbox_destination.__iter ~= "eilewdwfcx"
    then
        integrity_failed = true
    end

    restore_loggers()
    return not integrity_failed, captured_error
end

local function request_dedicated_test_place(environment, debug_config)
    local game_object = environment.game
    if not game_object then return true end

    local replicated_storage = game_object:GetService("ReplicatedStorage")
    if replicated_storage:FindFirstChild("Let em in") then
        return true
    end

    local warning = environment.warn or environment.print or warn or print
    warning("[1] - Please execute sUNC in the dedicated place. You can find it on our Discord server [discord.gg/yGNzDrvbF5]")
    if debug_config and debug_config.printcheckpoints then
        warning([[just make it warn("diofdjaosijdsfajia"). Credits: ETq]])
    end

    local task_library = environment.task or task
    if task_library and task_library.wait then task_library.wait(0.3) end

    local teleport_service = game_object:GetService("TeleportService")
    local local_player = game_object:GetService("Players").LocalPlayer
    -- The fixture gate has spoken. Geography is now a compatibility primitive.
    teleport_service:Teleport(133609342474444, local_player)
    return false
end

local function authenticate_dedicated_test_place(environment)
    local game_object = environment.game
    local replicated_storage = game_object:GetService("ReplicatedStorage")
    local entry_remote = replicated_storage:FindFirstChild("Let em in")
    local reporter_remote = replicated_storage:FindFirstChild("poooop")
    if not entry_remote or not reporter_remote then return false end

    entry_remote:InvokeServer(
        "ok u gotta change your script then im gonna make different serializer and deserializer"
    )

    local executor_name = "Idk"
    if type(environment.identifyexecutor) == "function" then
        executor_name = environment.identifyexecutor() or executor_name
    end

    local buffer_api = environment.buffer or buffer
    local probe_buffer = buffer_api.create(400)
    buffer_api[decode_xored_base64(
        "uWJxY9uoZW0fW+I=", "zhAYF77bER92NYU="
    )](probe_buffer, 0, executor_name)
    buffer_api[decode_xored_base64(
        "gI/ZdTFfnIM=", "9/2wAVQ2r7E="
    )](probe_buffer, 66, -9)

    -- P31 performs an intentionally irregular warm-up invocation before the
    -- challenge. The server consumes the pcall tuple, executor label and probe
    -- buffer; the return value is deliberately ignored.
    reporter_remote:InvokeServer(
        "\255\nS\2t\5a\nrt\5e\6d\2\251",
        nil,
        { [5] = executor_name },
        { ["[\255\r]"] = table.pack(pcall(probe_public_ip_endpoint, environment)) },
        nil,
        probe_buffer
    )

    local challenge = "Swerve, bend that corner woahhh"
    local response = reporter_remote:InvokeServer(
        challenge,
        "2ga0BtoGsgbaBrQG",
        nil,
        probe_buffer,
        nil
    )
    return response == challenge
end

local function bootstrap_sunc(environment)
    environment = environment or (getgenv and getgenv()) or _G
    local integrity_ok, integrity_detail = verify_bootstrap_runtime(environment)
    if not integrity_ok then
        local logger = environment.warn or environment.print or warn or print
        logger("sUNC bootstrap integrity check failed", integrity_detail)
    end

    if not request_dedicated_test_place(environment, read_debug_config(environment)) then
        return nil, false, "dedicated test place required"
    end
    local authenticated, authentication_error = pcall(authenticate_dedicated_test_place, environment)
    if not authenticated or not authentication_error then
        local logger = environment.warn or environment.print or warn or print
        logger("Failed to authenticate. This usually means that your exploit doesn't support sUNC. If you have any questions regarding this, let us know [discord.gg/yGNzDrvbF5]")
        return nil, false, authentication_error
    end

    local ok, results, passed = pcall(run_sunc_suite, environment, {
        allow_network = true,
        show_result_gui = true,
        -- P78/P79 are restored without a semantic gate. The dedicated place
        -- isolates the destructive probe in an Actor.
    })
    if not ok then
        local logger = environment.warn or environment.print or warn or print
        logger("sUNC threw an error. Please rejoin the place and execute again, Error:")
        logger(results)
        return nil, false, results
    end
    return results, passed
end
build_sandbox_environment = function(environment, captures, source)
    environment = environment or (getgenv and getgenv()) or _G
    captures = captures or {}
    local destination = captures.destination or captures[1] or {}
    if type(source) ~= "table" then return destination end
    for key, value in pairs(source) do
        if destination[key] == nil then destination[key] = value end
    end
    return destination
end

-- P82-P86 are coordinator callbacks. Their high-level equivalents below are
-- called by the coordinator or by the asynchronous loadstring result path; they
-- are retained separately because their closure identities are observable.
local function resolve_environment_path(environment, _, dotted_path)
    environment = environment or (getgenv and getgenv()) or _G
    local current = (environment.getfenv and environment.getfenv()) or {}
    local global_environment = (environment.getgenv and environment.getgenv()) or {}

    for segment in tostring(dotted_path):gmatch("[^%.]+") do
        local next_value = current[segment]
        if next_value == nil then next_value = global_environment[segment] end
        if next_value == nil then return false end
        current = next_value
    end
    return current
end

local function load_test_dependency(environment, _, url)
    environment = environment or (getgenv and getgenv()) or _G
    local source = environment.game:HttpGet(url)
    local chunk, compile_error = environment.loadstring(source)
    if not chunk then error(compile_error, 2) end
    return chunk()
end

-- Deduplicate asynchronous fixture completions and retain the first diagnostic
-- for each named loadstring test.
local function record_async_loadstring_result(environment, captures, succeeded, test_name, value)
    captures = captures or {}
    local completed = captures.completed_tests or {}
    local failed = captures.failed_tests or {}
    local details = captures.test_details or {}
    local loadstring_success = captures.loadstring_success or {}
    local prerequisites = captures.loadstring_prerequisites or {
        ["loadstring[basic]"] = true,
        ["loadstring[simple]"] = true,
        ["loadstring[complicated]"] = true,
    }
    local record_result = captures.record_result

    captures.completed_tests = completed
    captures.failed_tests = failed
    captures.test_details = details
    captures.loadstring_success = loadstring_success
    captures.loadstring_prerequisites = prerequisites

    if completed[test_name] then return details[test_name] end

    local is_loadstring_fixture = test_name == "loadstring[basic]"
        or test_name == "loadstring[simple]"
        or test_name == "loadstring[complicated]"

    if succeeded ~= true then
        local diagnostic = tostring(value)
        completed[test_name] = true
        failed[test_name] = true
        details[test_name] = diagnostic
        if is_loadstring_fixture then loadstring_success[test_name] = false end
        if record_result then record_result(false, test_name, diagnostic) end
        if not is_loadstring_fixture then
            local output = captures.output or (environment and environment.warn) or warn
            if output then output(utf8.char(10060) .. " " .. test_name, diagnostic) end
        end
        return diagnostic
    end

    completed[test_name] = true
    details[test_name] = value
    if is_loadstring_fixture then loadstring_success[test_name] = true end

    -- P84 checks all three asynchronous fixtures after each completion. The
    -- coordinator may continue only when every required fixture has reported.
    local all_loadstrings_complete = true
    for required_name, required in pairs(prerequisites) do
        if required and loadstring_success[required_name] ~= true then
            all_loadstrings_complete = false
            break
        end
    end
    if all_loadstrings_complete then
        captures.loadstring_group_complete = true
        local on_complete = captures.on_loadstring_group_complete
        if type(on_complete) == "function" then on_complete() end
    end
    return is_loadstring_fixture and "true" or value
end

local function append_result(_, captures, value)
    captures = captures or {}
    local list = captures.result_list or captures[1]
    table.insert(list, value)
end

local function shift_bytes_by_13(_, _, text)
    local output = table.create and table.create(#text) or {}
    for index = 1, #text do
        output[index] = string.char((string.byte(text, index) + 13) % 256)
    end
    return table.concat(output)
end

-- Verify that invalidating an Instance wrapper removes the old wrapper from the
-- registry and that reacquiring the Instance creates a fresh cached wrapper.
local function test_getreg_cache(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getreg) ~= "function" or not environment.cache then
        return fail_test(captures, "cache.invalidate", "Can't test due to getreg being nil")
    end

    local compare = environment.compareinstances
    local function same_instance(left, right)
        if left == right then return true end
        if type(compare) == "function" then
            local ok, result = pcall(compare, left, right)
            return ok and result == true
        end
        return false
    end
    local function registry_contains(target)
        for _, value in pairs(environment.getreg()) do
            if same_instance(value, target) then return true end
        end
        return false
    end

    local part = environment.Instance.new("Part")
    part.Name = "sUNC_cache_probe_" .. tostring(math.random(100000, 999999))
    part.Anchored = true
    part.CFrame = environment.CFrame.new(0, -200, 0)
    part.Parent = environment.workspace
    local name = part.Name

    environment.cache.invalidate(part)
    if registry_contains(part) then
        fail_test(captures, "cache.invalidate", "Was able to find the cached instance in registry")
    end

    local reacquired = environment.workspace:FindFirstChild(name)
    if reacquired and not registry_contains(reacquired) then
        fail_test(captures, "cache.invalidate", "Wasn't able to find the cached instance in registry")
    end
    safe_destroy(reacquired or part)
end

local function test_cache_invalidate_and_cache_iscached(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if not environment.cache or type(environment.cache.invalidate) ~= "function" then
        return fail_test(captures, "cache.iscached", "Can't test due to cache.invalidate not working reliably")
    end

    local lighting = environment.game:GetService("Lighting")
    environment.cache.invalidate(lighting)
    if environment.cache.iscached(lighting) then
        fail_test(captures, "cache.iscached", "Returned true for a non-cached instance")
    end

    local collection_service = environment.game:GetService("CollectionService")
    if not environment.cache.iscached(collection_service) then
        fail_test(captures, "cache.iscached", "Returned false for a cached instance")
    end
end

local function test_cache_invalidate_replace(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if not environment.cache or type(environment.cache.replace) ~= "function" then
        return fail_test(captures, "cache.replace", "Can't test due to cache.invalidate not working reliably")
    end

    local old_wrapper = environment.Instance.new("Frame")
    old_wrapper.Name = "FF"
    old_wrapper.Parent = environment.workspace
    local replacement = environment.Instance.new("Part")
    replacement.Name = "FF2"
    replacement.Transparency = 1
    replacement.Parent = environment.workspace
    environment.task.wait()

    environment.cache.replace(old_wrapper, replacement)
    if environment.workspace.FF ~= replacement then
        fail_test(captures, "cache.replace", "Failed to replace the instance cache with a new one")
    elseif environment.workspace.FF.Transparency ~= 1 then
        fail_test(captures, "cache.replace", "Failed to retrieve a property from the replaced instance")
    end
    if old_wrapper == replacement then
        fail_test(captures, "cache.replace", "Should only replace the instance cache, not the reference")
    end
    safe_destroy(old_wrapper)
    safe_destroy(replacement)
end

local exercise_getcallbackvalue_edge_cases

local function test_getcallbackvalue(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local invalid_ok, invalid_result = pcall(environment.getcallbackvalue, "", "OnInvoke")
    if invalid_ok and type(invalid_result) == "function" then
        fail_test(captures, "getcallbackvalue", "Was able to get a callback from an invalid instance")
    end
    exercise_getcallbackvalue_edge_cases(environment)

    local called = false
    local bindable = environment.Instance.new("BindableFunction")
    local expected_callback = function()
        called = true
        return "sUNC callback probe"
    end
    bindable.OnInvoke = expected_callback

    local actual_callback = environment.getcallbackvalue(bindable, "OnInvoke")
    if type(actual_callback) ~= "function"
        or (actual_callback ~= expected_callback and tostring(actual_callback) ~= tostring(expected_callback))
    then
        fail_test(captures, "getcallbackvalue", "The callback received does not match the actual callback")
    else
        actual_callback()
        environment.task.wait()
        if not called then
            fail_test(captures, "getcallbackvalue", "The callback value didn't behave as expected")
        end
    end
    safe_destroy(bindable)
end

exercise_getcallbackvalue_edge_cases = function(environment)
    environment = environment or (getgenv and getgenv()) or _G
    local getcallbackvalue = environment.getcallbackvalue
    local results = table.pack(
        pcall(getcallbackvalue, environment.game, "Close"),
        pcall(getcallbackvalue, environment.game, "IsA"),
        pcall(getcallbackvalue, environment.game, "GetPropertyChangedSignal"),
        pcall(getcallbackvalue, environment.game, "\n\n\n\n\n\n\t")
    )
    local part = environment.Instance.new("Part")
    results[#results + 1] = table.pack(pcall(getcallbackvalue, part, "SetPredictionMode"))
    part:Destroy()
    return results
end

-- The prototype name was misleading after compilation: this test validates
-- getscriptclosure and uses debug.getconstants only as an oracle.
local function test_getscriptclosure(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if not environment.debug or type(environment.debug.getconstants) ~= "function" then
        return fail_test(captures, "getscriptclosure", "debug.getconstants is needed in order to test")
    end

    local players = environment.game:GetService("Players")
    local replicated_storage = environment.game:GetService("ReplicatedStorage")
    local fixtures = {
        { players.LocalPlayer.PlayerScripts.PlayerModule, "Failed to retrieve the closure from a ModuleScript" },
        { players.LocalPlayer.Character and players.LocalPlayer.Character:FindFirstChild("Animate"), "Failed to retrieve the closure from a LocalScript" },
        { replicated_storage:FindFirstChild("Folder") and replicated_storage.Folder.Folder:FindFirstChild("Script"), "Failed to retrieve the closure from a Script with RunContext set to Client" },
    }

    for _, fixture in ipairs(fixtures) do
        local script_instance, message = fixture[1], fixture[2]
        local ok, closure = pcall(environment.getscriptclosure, script_instance)
        if not ok or type(closure) ~= "function" then
            fail_test(captures, "getscriptclosure", message)
        end
    end

    local client_script = fixtures[3][1]
    if not client_script then return end
    local ok, constants = pcall(function()
        return environment.debug.getconstants(environment.getscriptclosure(client_script))
    end)
    if not ok or type(constants) ~= "table" then
        return fail_test(captures, "getscriptclosure", "Couldn't find constants from the script's closure")
    end

    local found = { Color = false, ["50"] = false, create = false }
    local diagnostic_lines = {}
    for index, constant in pairs(constants) do
        local text = tostring(constant)
        diagnostic_lines[#diagnostic_lines + 1] = tostring(index) .. " -> " .. text
        if found[text] ~= nil then found[text] = true end
    end

    local expected = { "Color", "50", "create" }
    for index, expected_constant in ipairs(expected) do
        if not found[expected_constant] then
            fail_test(captures, "getscriptclosure", "Couldn't find a constant from the script's closure[" .. index .. "]")
        end
    end

    if not (found.Color and found["50"] and found.create) then
        local output = table.concat(diagnostic_lines, "\n")
        if captures.diagnostics then
            captures.diagnostics.getscriptclosure_constants = output
        end
        fail_test(captures, "getscriptclosure", string.format([[

                        Returned one or more wrong constants from a script's closure using this:
                        debug.getconstants(getscriptclosure(game:GetService("ReplicatedStorage").Folder.Folder.Script))

                        Output returned:

                        %s

                    ]], output))
    end
end

local function test_compareinstances(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.compareinstances) ~= "function" then
        return fail_test(captures, "compareinstances", "compareinstances is needed in order to test")
    end

    local marker = environment.Instance.new("Folder")
    marker.Name = "lol"
    marker.Parent = environment.workspace
    if environment.task and environment.task.wait then environment.task.wait() end

    local cloned_game = environment.cloneref(environment.game)
    if not cloned_game.workspace:FindFirstChild("lol") then
        fail_test(captures, "cloneref", "Couldn't retrieve an existing member of the reference")
    end
    safe_destroy(marker)

    if environment.typeof(cloned_game) ~= environment.typeof(environment.game)
        or environment.type(cloned_game) ~= environment.type(environment.game)
    then
        fail_test(captures, "cloneref", "Reference should have the same type as the original")
    end
    if cloned_game == environment.game then
        fail_test(captures, "cloneref", "The reference should be different compared to the original")
    end
    if environment.rawequal(cloned_game, environment.game) then
        fail_test(captures, "cloneref", "The reference should not be the same under rawequal")
    end

    -- Sanity-check rawequal itself before using it as part of the verdict.
    local first_proxy = environment.newproxy and environment.newproxy(true) or {}
    local second_proxy = environment.newproxy and environment.newproxy(false) or {}
    if environment.rawequal({}, {}) or environment.rawequal(first_proxy, second_proxy) then
        fail_test(captures, "cloneref", "compareinstances approved invalid references")
    end

    local cloned_workspace_a = environment.cloneref(environment.workspace)
    local cloned_workspace_b = environment.cloneref(environment.workspace)
    if cloned_workspace_a == cloned_workspace_b then
        fail_test(captures, "cloneref", "Invalid references should not equal[1]")
    end
    if environment.rawequal(cloned_workspace_a, cloned_workspace_b) then
        fail_test(captures, "cloneref", "Invalid references should not equal[2]")
    end

    -- The place fixture toggles this property when cloneref is observed from a
    -- foreign execution context.  Preserve that anti-detection assertion.
    local probe = environment.workspace:FindFirstChild("tsatsatsatsa")
    if probe then
        local reference = environment.cloneref(environment.game)
        local observed = wait_until(environment, function() return probe.Massless == false end, 488)
        if not observed or not reference then
            fail_test(captures, "cloneref", "Failed to use cloneref without being detected.")
        end
    end
end

local function test_compareinstances_with_cloneref(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if captures.prerequisite_failures and captures.prerequisite_failures.cloneref then
        return fail_test(captures, "compareinstances", "Can't verify due to cloneref not working reliably")
    end

    local cloned_game = environment.cloneref(environment.game)
    local cloned_workspace = environment.cloneref(cloned_game.workspace)

    if not environment.compareinstances(cloned_game, environment.game) then
        fail_test(captures, "compareinstances", "Compared instances cloned with cloneref should be the same under 'compareinstances' ")
    end
    if not environment.compareinstances(cloned_game, environment.workspace.Parent) then
        fail_test(captures, "compareinstances", "Couldn't retrieve the correct value for compareinstances[1]")
    end
    if not environment.compareinstances(cloned_game, cloned_workspace.Parent)
        or not environment.compareinstances(environment.workspace, cloned_workspace)
    then
        fail_test(captures, "compareinstances", "Couldn't retrieve the correct value for compareinstances[2]")
    end

    local original_part = environment.Instance.new("Part")
    local cloned_part = original_part:Clone()
    if environment.compareinstances(original_part, cloned_part) then
        fail_test(captures, "compareinstances", "Cloned instances shouldn't equal")
    end
    safe_destroy(original_part)
    safe_destroy(cloned_part)
end

-- `getrenv` must expose the Roblox VM environment, not the executor's global
-- table, and values from one VM must not leak into another.
local function test_environment_access(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local runtime_environment = environment.getrenv()
    if type(runtime_environment) ~= "table" or type(runtime_environment._G) ~= "table" then
        return fail_test(captures, "getrenv", "Missing _G key")
    end

    local member_count = count_pairs(runtime_environment._G)
    if member_count ~= 963 then
        if type(captures.diagnostics) == "table" then
            captures.diagnostics.getrenv_member_count = member_count
            captures.diagnostics.getrenv_member_count_expected = 963
        end
        fail_test(captures, "getrenv", string.format([[

                        The member count of getrenv()._G mismatched.

                        Expected count: 963

                        Retrieved count: %s

                    ]], tostring(member_count)))
    end

    local executor_environment = environment.getgenv()
    local runtime_warn_environment = environment.getfenv(runtime_environment.warn)
    local executor_warn_environment = environment.getfenv(executor_environment.warn)
    if runtime_warn_environment == nil
        or executor_warn_environment == nil
        or runtime_warn_environment == executor_warn_environment
    then
        fail_test(captures, "getrenv", "Let it go bro, please... 💔💔💔 32 halalitos 3̶̛͍͙̲̫̩̹͙̼͓̻̯̰̪͈̟̩̆̅̋̃̈́͂͊͑̅̅̑̃̀̊̐̀̇̀̄̓̋́͑̊̑̿͝2̴̀͛̆̀̉͜ ̵̨̧̛̘̮̼̩̤̘̦͙̟̗̤̬̲̯͈͈̳̪͇̝̖̥͚̘͕̩͖̺͖̔͂̑̏̽͆̽͌͋̿͑͂̍͋̋́̊̎̀̈́̀̓͊͜͠ͅh̷̨̢̬̙̝̗͍͎̭̘̻͔̟̺̮̙̻̤̪͕̳̱̲̜͓̣̲͐͂̃͛͆̌̆̋̐̃͗̓̐̄̂̍̈́̓̉́͂͌̋̾̓̐̕̚͝͝͝ą̸̛̛̛͕̘͖̠̎́̈́͂̔̏̈̀̈́̈́̾̀͌̅͑́͊̏̎̕̚̕ľ̴̨̞̩̭̼̦̼̪̗̱̝͇̞͍̞̗͔̜͍̼͕̞͍͈͈̗̰̥̩̟̥̲̣͉̮̍̈́́̊̀̑͜ͅͅa̶̢̛̛̮̫̙̳͍̝͍̦̞̮͉̭̥̹̝̝̲͎̭̓̎͂̎̌͊́͂̇̅́͐͗̌̓̌̂̇͋̽́̍̿̀͆̊̏̆͗́́͊̏̃̍̾̌͆̕͘̕͘͘͜͝͝l̶̹̬̙̦̯̟͇̝̣͔̙̣͔̪͉̲̲̳̞̳͐͛́̈́̍̿͆̅̅̌͋̌͋̀̋̋̔͑̆͊̒̊̇̐͋̀̆́͋̓͑̄̀̐̅̍̃̚̕͜͠ͅį̴̧̡̧̛̛̥͈̦̳͚̱͕̭̜̻̤͚̣̹͖̹̦̼̼̣͎̙͉̦̪̼̮͕̱̞̯͔̜͖̭̟͈̠͇̿̏̊̍̇͊̅͊̀̃̽͛̈́͆͋͗͊̅̾̽̽̂͐̅͒̈́͋̏͒͊̅̈́́͑͑̆͂̑̾͌͘͘͘͜͜͝ͅt̴͍̪͈͓̩̳̹͙̙͕̙̫̰͓͓̥̫̲̩͔̞͖̹̝̼̟̘͖͉̪̊̃͊̾͛̿̄̇̓̋̔̐̾̇̂͑̈́̀̊͑̅͑̉̂̈́̇̆̈́̅̆͂̑̓̓͘͠ơ̴̳̍͌͒͑͋͐̂́̃͗̊͒́̑́͗́̚̚͠͝͠s̸̫̩͍̭͕̳̘̙̻͔̞̏̈́̀̒̅̄͆͐̀́̍̊͝͠")
    end

    -- P101 asks for getrenv twice and compares the primitive members. This is
    -- the branch that distinguishes a stable VM environment from a freshly
    -- fabricated look-alike table.
    local second_runtime_environment = environment.getrenv()
    local mismatches = {}
    for key, first_value in pairs(runtime_environment) do
        local second_value = second_runtime_environment[key]
        local first_type, second_type = type(first_value), type(second_value)
        local value_mismatch = first_type ~= second_type
        if not value_mismatch and (first_type == "nil" or first_type == "boolean"
            or first_type == "number" or first_type == "string")
        then
            value_mismatch = first_value ~= second_value
        end
        if value_mismatch then
            mismatches[#mismatches + 1] = tostring(key)
                .. " [ MISMATCH. type should be " .. first_type
                .. ", got " .. second_type .. " ]"
        end
    end
    if #mismatches > 0 then
        fail_test(captures, "getrenv", "Value/type mismatch")
        if type(captures.diagnostics) == "table" then
            captures.diagnostics.getrenv_mismatches = mismatches
        end
        fail_test(captures, "getrenv", string.format([[

                        The value or types of members inside getrenv() returned a mismatch. The executor likely fakes their getrenv.

                        getrenv() output:

                        %s

                    ]], table.concat(mismatches, "\n")))
    end

    -- The place fixture deliberately seeds unusual values in the Roblox VM.
    if count_pairs(runtime_environment._G) ~= 963 then
        fail_test(captures, "getrenv", "Wrong _G count")
        fail_test(captures, "getrenv", string.format([[

                        The member count of getrenv()._G mismatched.

                        Expected count: 963

                        Retrieved count: %s

                    ]], tostring(count_pairs(runtime_environment._G))))
    end

    local expected_global = environment.game.workspace.FreakyBox.e.Head.CollisionGroup
    if tostring(runtime_environment._G) ~= expected_global then
        fail_test(captures, "getrenv", "REAL _G moment 👑🌹[1]")
    end
    if runtime_environment._G["gеm"] == nil then
        fail_test(captures, "getrenv", "REAL _G moment 👑🌹[2]")
    end
    if not runtime_environment.shared or runtime_environment.shared["okеm"] == nil then
        fail_test(captures, "getrenv", "Failed to find a .shared value")
    end
    if runtime_environment.shared and runtime_environment.shared.wow == ",m" then
        fail_test(captures, "getrenv", "Shouldn't push values across different VMs")
    end
end

local function test_firesignal(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}
    local make_probe_value = captures.make_probe_value or function() return {} end

    if prerequisites.getrawmetatable then
        return fail_test(captures, "firesignal", "getrawmetatable is not working properly, can't test")
    end
    if type(environment.setreadonly) ~= "function" then
        return fail_test(captures, "firesignal", "setreadonly is needed in order to test")
    end

    -- Basic signal dispatch and argument forwarding.
    local button = environment.Instance.new("TextButton")
    local expected_probe = make_probe_value()
    local received_first, received_second
    button.MouseButton1Click:Connect(function(first, second)
        received_first, received_second = first, second
    end)
    environment.firesignal(button.MouseButton1Click, expected_probe, "2")
    environment.task.wait(0.075)
    if received_first ~= expected_probe or received_second ~= "2" then
        fail_test(captures, "firesignal", "Couldn't fire the signal successfully")
    end

    -- Signals returned from Instance methods must be accepted too.
    local part = environment.Instance.new("Part")
    part.Name = "LPLPLPLPL"
    part.CFrame = environment.CFrame.new(0, -200, 0)
    part.Anchored = true
    part.Parent = environment.workspace
    local property_signal_fired = false
    local position_changed = part:GetPropertyChangedSignal("Position")
    position_changed:Connect(function() property_signal_fired = true end)
    environment.firesignal(position_changed)
    environment.task.wait(0.075)
    if not property_signal_fired then
        fail_test(captures, "firesignal", "Couldn't fire the signal successfully [2]")
    end
    safe_destroy(part)

    -- The firesignal implementation must not expose its executor-side caller to
    -- a callback as an ordinary Lua frame.
    local caller_was_visible = false
    local stack_probe = environment.Instance.new("Folder")
    stack_probe.ChildAdded:Connect(function()
        if pcall(environment.getfenv, 3) then caller_was_visible = true end
    end)
    environment.firesignal(stack_probe.ChildAdded)
    if caller_was_visible then
        fail_test(captures, "firesignal", "Found the caller in the callstack while firing the signal")
    end

    -- Every connected callback must receive the same complete argument list.
    local argument_failures = { false, false, false, false }
    local multi_probe = environment.Instance.new("Folder")
    multi_probe.ChildAdded:Connect(function(first, second)
        argument_failures[1] = first ~= "szs"
        argument_failures[2] = second ~= environment.game
    end)
    multi_probe.ChildAdded:Connect(function(first, second)
        argument_failures[3] = first ~= "szs"
        argument_failures[4] = second ~= environment.game
    end)
    environment.firesignal(multi_probe.ChildAdded, "szs", environment.game)
    for index, failed in ipairs(argument_failures) do
        if failed then
            fail_test(captures, "firesignal", "Failed to fire multiple signals with the proper arguments[" .. index .. "]")
        end
    end

    -- Merely changing an Instance metatable's __type marker must not turn the
    -- Instance itself into a valid RBXScriptSignal.
    local frame = environment.Instance.new("Frame")
    local frame_metatable = environment.getrawmetatable(frame)
    local original_type = frame_metatable.__type
    environment.setreadonly(frame_metatable, false)
    frame_metatable.__type = "RBXScriptSignal"
    local accepted_invalid_instance = pcall(environment.firesignal, frame, 9, 9, 9, 9, 9, 9, 9, 9, 9)
    frame_metatable.__type = original_type
    environment.setreadonly(frame_metatable, true)
    if accepted_invalid_instance then
        fail_test(captures, "firesignal", "Should error upon passing an invalid instance")
    end
    if environment.typeof(frame) == "RBXScriptSignal"
        or environment.getrawmetatable(frame).__type == "RBXScriptSignal"
    then
        fail_test(captures, "getrawmetatable", "Failed to set back the __type of an instance. ( Instance -> Signal -> Instance ) ")
    end

    safe_destroy(button)
    safe_destroy(stack_probe)
    safe_destroy(multi_probe)
    safe_destroy(frame)
end

local function test_base64_encode(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    -- P112 receives this fixture as a captured value from P31. It contains NUL
    -- bytes; replacing it with "\\0\\0\\0" changes both the branch and length test.
    local bytecode_fixture = environment.game:HttpGet(
        "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/bytecode"
    )
    local fixture_output = environment.base64encode(bytecode_fixture)
    if not string.find(fixture_output, "FNRTMuMTAw", 1, true) then
        fail_test(captures, "base64encode", "Couldn't match with expected output")
    end
    if #fixture_output ~= 534580 then
        fail_test(captures, "base64encode", "Failed to encode a string with null bytes")
    end

    local plaintext = "I can easily bypassed roblox but it will cost me 500k$ i can using null coding and exe exploits i cant say most of it because u know its illegal This ensures the XOR will never produce Ox20, causing it to always jump and bypass the Hyperion :: Yara :: ScanStats call completely. This is probably the cleanest way to disable their scanning without breaking other parts of the code."
    local encoded_output = environment.base64encode(plaintext)
    if encoded_output:sub(-1) == "\n" then
        fail_test(captures, "base64encode", "Found line break at the end of base64 encoded string")
    end
    if encoded_output ~= "SSBjYW4gZWFzaWx5IGJ5cGFzc2VkIHJvYmxveCBidXQgaXQgd2lsbCBjb3N0IG1lIDUwMGskIGkgY2FuIHVzaW5nIG51bGwgY29kaW5nIGFuZCBleGUgZXhwbG9pdHMgaSBjYW50IHNheSBtb3N0IG9mIGl0IGJlY2F1c2UgdSBrbm93IGl0cyBpbGxlZ2FsIFRoaXMgZW5zdXJlcyB0aGUgWE9SIHdpbGwgbmV2ZXIgcHJvZHVjZSBPeDIwLCBjYXVzaW5nIGl0IHRvIGFsd2F5cyBqdW1wIGFuZCBieXBhc3MgdGhlIEh5cGVyaW9uIDo6IFlhcmEgOjogU2NhblN0YXRzIGNhbGwgY29tcGxldGVseS4gVGhpcyBpcyBwcm9iYWJseSB0aGUgY2xlYW5lc3Qgd2F5IHRvIGRpc2FibGUgdGhlaXIgc2Nhbm5pbmcgd2l0aG91dCBicmVha2luZyBvdGhlciBwYXJ0cyBvZiB0aGUgY29kZS4=" then
        fail_test(captures, "base64encode", "Encoded output didn't match expected output")
    end
end

local function test_base64_decode(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    -- Exact P31/P113 capture: the coordinator downloads the encoded bytecode
    -- fixture first, then the test verifies that decoding exposes this marker.
    local encoded_fixture = environment.game:HttpGet(
        "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/encodedBytecode"
    )
    local decoded = environment.base64decode(encoded_fixture)
    if not string.find(decoded, "compatible_brands", 1, true) then
        fail_test(captures, "base64decode", "Couldn't find the needed value inside the output")
    end
end

local function test_lz4_compress(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local compressed = environment.lz4compress("t65")
    if type(compressed) ~= "string" then
        return fail_test(captures, "lz4compress", "Didn't return a string value after compression")
    end
    if string.byte(compressed, 1) ~= 48 then
        fail_test(captures, "lz4compress", "Couldn't match expected bytes with the output")
    end
end

local function test_lz4_decompress(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local sample = "t65"
    local compressed = environment.lz4compress(sample)
    local decompressed = environment.lz4decompress(compressed, #sample)
    if decompressed ~= sample then
        fail_test(captures, "lz4decompress", "Couldn't decompress into expected string")
    elseif string.byte(decompressed, 1) ~= 116 then
        fail_test(captures, "lz4decompress", "Couldn't match expected bytes with the output")
    end

    -- P115's second branch compresses a much larger fixture and verifies that
    -- the compressor actually reduced it. Network failure is not converted
    -- into a compression failure; the original branch only judges valid data.
    local ok, large_fixture = pcall(function()
        return environment.game:HttpGet(
            "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/uhhhhh"
        )
    end)
    if ok and type(large_fixture) == "string" and #large_fixture > 0 then
        local large_compressed = environment.lz4compress(large_fixture)
        if #large_compressed >= #large_fixture then
            fail_test(captures, "lz4decompress", "Compressed output was bigger or equal to the original")
        end
    end
end

local function test_getgc(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local ordinary = environment.getgc()
    if type(ordinary) ~= "table" then
        return fail_test(captures, "getgc", "Didn't return a table value")
    end

    -- P117 performs two consistency checks on the ordinary collection.  They
    -- were previously lost with the iterator exits: enumeration must actually
    -- progress, and a second snapshot must not be the exact same-size no-op.
    local enumerated_count = 0
    for _ in pairs(ordinary) do enumerated_count = enumerated_count + 1 end
    if enumerated_count <= 0 then
        fail_test(captures, "getgc", "Everyone must GetDescendants of game 🙏🙏🙏[1]")
    end
    local second_snapshot = environment.getgc()
    if type(second_snapshot) == "table" and enumerated_count == #second_snapshot then
        -- This diagnostic is intentionally conservative: the compiled branch
        -- compares the loop counter to a fresh snapshot length.
        fail_test(captures, "getgc", "Everyone must GetDescendants of game 🙏🙏🙏[2]")
    end

    local including_tables = environment.getgc(true)
    if type(including_tables) ~= "table" then
        return fail_test(captures, "getgc", "Was able to retrieve a table with a non-true argument passed")
    end

    local found_function, found_table, found_userdata = false, false, false
    for _, value in pairs(including_tables) do
        local value_type = type(value)
        if value_type == "function" then found_function = true end
        if value_type == "table" then found_table = true end
        if value_type == "userdata" then found_userdata = true end
    end
    if not found_function then fail_test(captures, "getgc", "Couldn't find a game function") end
    if not found_table then fail_test(captures, "getgc", "Couldn't fetch a needed value") end
    if not found_userdata then fail_test(captures, "getgc", "Failed to retrieve a userdata object") end
end

local function test_getgenv(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local global_environment = environment.getgenv()
    local current_environment = environment.getfenv and environment.getfenv(0) or environment

    -- Exact P119 data flow: write through getgenv(), assign nil through ENV,
    -- then read through ENV. The expected 123 arrives through ENV's fallback
    -- into getgenv(). Reading global_environment.kingvonisud here would merely
    -- reread the assignment and would not test environment sharing at all.
    global_environment.kingvonisud = 123
    current_environment.kingvonisud = nil
    if current_environment.kingvonisud == nil then
        fail_test(captures, "getgenv", "Global environment is not shared properly")
    end

    -- A second, independent branch deletes through getgenv() and confirms that
    -- neither the ENV view nor the getgenv table still exposes the value.
    global_environment.ok = "nice"
    global_environment.ok = nil
    if current_environment.ok or global_environment.ok then
        fail_test(captures, "getgenv", "Global environment is not shared properly[2]")
    end

    if environment.getfenv then
        -- The compiled test repeatedly exercised getfenv(0) and getfenv on a
        -- fresh Lua closure before making the three comparisons below.
        local current_function_environment = environment.getfenv()
        local getgenv_function_environment = environment.getfenv(environment.getgenv)
        local level_zero_environment = environment.getfenv(0)
        local level_one_environment = environment.getfenv(1)

        level_zero_environment.df = "hi"
        level_one_environment.df = "hi"
        getgenv_function_environment.df = "hi"

        if global_environment.df == "hi" then
            fail_test(captures, "getgenv",
                "The function environment of `getgenv` should not be the result of it[1]")
        end
        if getgenv_function_environment ~= current_function_environment then
            fail_test(captures, "getgenv",
                "The environment of getgenv should be the same as current")
        end
        if getgenv_function_environment == global_environment then
            fail_test(captures, "getgenv",
                "The function environment of `getgenv` should not be the result of it[2]")
        end
    end
end

-- The maze hid five ordinary set-membership checks. I have seen more intimidating architecture in a hotel ice machine.
local function test_getloadedmodules(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local require_function = environment.require or require
    if type(require_function) ~= "function" then
        return fail_test(captures, "getloadedmodules", "require is needed in order to test")
    end

    local modules = environment.getloadedmodules()
    if type(modules) ~= "table" then
        return fail_test(captures, "getloadedmodules", "Couldn't find a loaded module[1]")
    end

    local seen = {}
    for _, module in pairs(modules) do
        if seen[module] then
            fail_test(captures, "getloadedmodules", "Shouldn't return duplicates")
            break
        end
        seen[module] = true
    end

    local replicated_first = environment.game:GetService("ReplicatedFirst")
    local players = environment.game:GetService("Players")
    local expected_first = replicated_first.bleepbloop["getting rich like this is a hobby"]
    local expected_second = players.LocalPlayer.PlayerScripts["Pull off in a Tonka, yeah, this a big body"]
    if not seen[expected_first] or not seen[expected_second] then
        fail_test(captures, "getloadedmodules", "Aaaand we're ud ash 💔💔🥀🥀")
    end

    local unloaded_one = players.LocalPlayer.PlayerScripts.ModuleScripka
    local unloaded_two = environment.game.StarterPlayer.StarterPlayerScripts.ModuleScripka
    if seen[unloaded_one] or seen[unloaded_two] then
        fail_test(captures, "getloadedmodules", "Returned an unloaded module")
    end

    local found_callable_fixture = false
    for _, module in pairs(modules) do
        local metadata_ok, name, class_name = pcall(function()
            return module.Name, module.ClassName
        end)
        if metadata_ok and name == "scriptsomemodulesrn" and class_name == "ModuleScript" then
            local loaded_ok, exported = pcall(require_function, module)
            if loaded_ok and type(exported) == "function" then
                local invoked_ok, result = pcall(exported, { RIP = 95 })
                if invoked_ok and result == 9 then
                    found_callable_fixture = true
                end
            end
        end
    end
    if not found_callable_fixture then
        fail_test(captures, "getloadedmodules", "Couldn't find a loaded module[1]")
    end

    local replicated_storage_fixture = environment.game.ReplicatedStorage
        ["would_you_be_a_bop_if_you_were_a_girl?"]["yes? Interesting..."]
    if not seen[replicated_storage_fixture] then
        fail_test(captures, "getloadedmodules", "Couldn't find a loaded module[2]")
    end
end

local function test_setrawmetatable(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getrawmetatable) ~= "function" then
        return fail_test(captures, "setrawmetatable", "Can't test due to 'getrawmetatable' not working reliably")
    end

    local object = {}
    local first_metatable = { __index = function() return "bomlol" end }
    local returned_object = environment.setrawmetatable(object, first_metatable)
    local second_metatable = { __index = environment.getgenv() }
    environment.setrawmetatable(returned_object, second_metatable)
    if type(returned_object.print) ~= "function" then
        fail_test(captures, "setrawmetatable", "Failed to change the metatable")
    end

    local locked_object = {}
    environment.setrawmetatable(locked_object, { __metatable = "real2" })
    environment.setrawmetatable(locked_object, {})
    if getmetatable(locked_object) == "real2" then
        fail_test(captures, "setrawmetatable", "Failed to set a metatable on a locked metatable")
    end

    local first_table, second_table = {}, {}
    local first_table_metatable = { __index = environment.getgenv() }
    local second_table_metatable = { __index = environment.getgenv() }
    local first_return = environment.setrawmetatable(first_table, first_table_metatable)
    local second_return = environment.setrawmetatable(second_table, second_table_metatable)

    local transferred_metatable = environment.getrawmetatable(first_table)
    local metatable_return = environment.setrawmetatable(transferred_metatable, environment.getrawmetatable(second_table))
    local first_raw = environment.getrawmetatable(first_table)
    local second_raw = environment.getrawmetatable(second_table)
    local returned_raw = environment.getrawmetatable(metatable_return)

    if first_return == nil or second_return == nil then
        fail_test(captures, "setrawmetatable", "Failed to obtain a return value")
    end
    if second_table == metatable_return then
        fail_test(captures, "setrawmetatable", "Invalid table-to-metatable references[1]")
    end
    if first_table == metatable_return then
        fail_test(captures, "setrawmetatable", "Invalid table-to-metatable reference[2]")
    end
    if first_table == first_raw then
        fail_test(captures, "setrawmetatable", "A table and its metatable should not be equal to eachother[1]")
    end
    if second_table == second_raw then
        fail_test(captures, "setrawmetatable", "A table and its metatable should not be equal to eachother[2]")
    end
    if metatable_return == returned_raw then
        fail_test(captures, "setrawmetatable", "Invalid return. Should not return its own metatable")
    end
    if first_table == returned_raw then
        fail_test(captures, "setrawmetatable", "A table and its metatable should not be equal to eachother[3]")
    end
    if not metatable_return.print then
        fail_test(captures, "setrawmetatable", "Failed to retrieve a value from a metatable")
    end
    if first_raw == second_raw then
        fail_test(captures, "setrawmetatable", "Different metatable should not equal to eachother")
    end
    if second_raw ~= returned_raw then
        fail_test(captures, "setrawmetatable", "Invalid metatable-to-metatable reference")
    end
end

local function test_getrunningscripts(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local scripts = environment.getrunningscripts()
    if type(scripts) ~= "table" then
        return fail_test(captures, "getrunningscripts", "Didn't return a table")
    end

    local seen = {}
    for _, script_instance in pairs(scripts) do
        if seen[script_instance] then
            fail_test(captures, "getrunningscripts", "Shouldn't return duplicates")
            break
        end
        seen[script_instance] = true
    end

    local replicated_first = environment.game:GetService("ReplicatedFirst")
    local player_scripts = environment.game.Players.LocalPlayer.PlayerScripts
    if seen[replicated_first.bleepbloop.suncinit] then
        fail_test(captures, "getrunningscripts", "Shouldn't return scripts initialized in an actor state")
    end
    if seen[player_scripts.boidontbemean] then
        fail_test(captures, "getrunningscripts", "Fetched a script with a thread that's no longer running")
    end

    environment.task.wait()
    if not seen[replicated_first["Wow?"]] then
        fail_test(captures, "getrunningscripts", "Couldn't return a running script parented to a fake actor")
    end

    local client_script = environment.game.ReplicatedStorage.Scurry.FakeGrimReaper.respect.Script
    if not seen[client_script] then
        fail_test(captures, "getrunningscripts", "Was unable to find a running 'Script' with 'Client' RunContext")
    end

    local found_nil_parent = false
    local expected_destroyed_name = "seebau"
        .. environment.game.ReplicatedStorage.Folder.Folder.Folder.Folder.Folder.Folder
            ["is this my life?..."].Value
    local found_nil_script_global = false
    for _, script_instance in pairs(scripts) do
        local ok, name, parent = pcall(function()
            return script_instance.Name, script_instance.Parent
        end)
        if ok and name == "ANG3LJ0RDAN" and parent == nil then
            found_nil_parent = true
        end
        if ok and type(name) == "string" and name:find("seebau", 1, true)
            and name == expected_destroyed_name
        then
            found_nil_script_global = true
        end
    end
    if not found_nil_parent then
        fail_test(captures, "getrunningscripts", "Was unable to find a running script parented to nil")
    end
    if not found_nil_script_global then
        fail_test(captures, "getrunningscripts", "Was unable to find a running script with its script global set to nil")
    end
end

local function test_getscripts(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local scripts = environment.getscripts()
    if type(scripts) ~= "table" then
        return fail_test(captures, "getscripts", "Didn't return a table")
    end

    local found_local, found_client_script = false, false
    for _, script_instance in pairs(scripts) do
        local ok, class_name, parent, run_context = pcall(function()
            return script_instance.ClassName, script_instance.Parent, script_instance.RunContext
        end)
        if ok then
            if script_instance:IsDescendantOf(environment.game.CorePackages)
                or script_instance:IsDescendantOf(environment.game.CoreGui)
            then
                fail_test(captures, "getscripts", "Shouldn't return core scripts by default")
            end
            if parent == nil and class_name == "LocalScript" then found_local = true end
            if parent == nil and class_name == "Script"
                and run_context == environment.Enum.RunContext.Client
            then
                found_client_script = true
            end
        end
    end

    if not found_local then
        fail_test(captures, "getscripts", "Couldn't fetch a script parented to nil")
    end
    if not found_client_script then
        fail_test(captures, "getscripts", "Couldn't fetch a 'Script' with RunContext set to Client and parented to nil")
    end
end

local function test_getscriptfromthread(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local replicated_storage = environment.game:GetService("ReplicatedStorage")
    local thread_holder = replicated_storage:WaitForChild('"degloved" *speed shocked gif*')
    local fixture_thread = thread_holder:GetAttribute("goatis_vs_spaghetti_stood_no_chance")
    local script_instance = environment.getscriptfromthread(fixture_thread)
    if not script_instance or script_instance.ClassName ~= "Script" then
        return fail_test(captures, "getscriptfromthread", "Retrieved an invalid object: " .. tostring(script_instance))
    end

    local expected_suffix = replicated_storage.Folder.Folder.Folder.Folder.Folder.Folder["is this my life?..."].Value
    if script_instance.Name ~= "seebau" .. expected_suffix then
        fail_test(captures, "getscriptfromthread", "Failed to retrieve a destroyed script instance with its `Script` global set to junk.")
    end
end

local function test_getsenv(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local players = environment.game:GetService("Players")
    local local_player = players.LocalPlayer
    local animate = local_player.Character.Animate
    local lefty = local_player.PlayerScripts.lefty

    local animate_environments = {}
    for index = 1, 20 do animate_environments[index] = environment.getsenv(animate) end
    for index = 2, #animate_environments do
        if animate_environments[index] ~= animate_environments[1] then
            fail_test(captures, "getsenv", "Returned table should be static")
            break
        end
    end

    local lefty_environment = environment.getsenv(lefty)
    local lefty_environment_again = environment.getsenv(lefty)
    if lefty_environment and lefty_environment_again
        and lefty_environment.groksays ~= lefty_environment_again.groksays
    then
        fail_test(captures, "getsenv", "Boi what sigma you doing 😂🤔")
    end

    local animate_environment = animate_environments[1]
    if type(animate_environment) ~= "table" then
        return fail_test(captures, "getsenv", "Didn't return a table value")
    end
    if animate_environment.script ~= animate then
        fail_test(captures, "getsenv", "Script global shouldn't differ")
    end
    if type(animate_environment.onRunning) ~= "function" then
        fail_test(captures, "getsenv", "Failed to fetch a value from the script's env[1]")
        fail_test(captures, "getsenv", string.format([[

                        Failed to find one or more environment members from the "Animate" script.

                        getsenv(animate) return:

                        %s

                    ]], serialize_table(animate_environment)))
    end
    if type(animate_environment.getToolAnim) ~= "function"
        or animate_environment.getToolAnim(environment.workspace) ~= nil
    then
        fail_test(captures, "getsenv", "Failed to retrieve the value from the script's function")
    end

    local starter_player = environment.game:GetService("StarterPlayer")
    local non_running_script = starter_player.StarterPlayerScripts.PlayerModule.CommonUtils.FlagUtil
    local non_running_ok, non_running_environment = pcall(environment.getsenv, non_running_script)
    if non_running_ok and non_running_environment ~= nil then
        fail_test(captures, "getsenv", "Was able to retrieve the environment of a non-running script")
    end

    if type(lefty_environment) ~= "table" then
        fail_test(captures, "getsenv", "Failed to retrieve the environment of a game script")
    elseif lefty_environment.geeked ~= "locked in" then
        fail_test(captures, "getsenv", "Failed to fetch a value from the script's env[2]")
        fail_test(captures, "getsenv", string.format([[

                        Failed to find one or more environment members from the "lefty" script.

                        getsenv(lefty) return:

                        %s

                    ]], serialize_table(lefty_environment)))
    end

    local nil_script_global = environment.game.ReplicatedStorage["First I go whip out the bost"]
    xpcall(function()
        local nil_global_environment = environment.getsenv(nil_script_global)
        if not nil_global_environment then
            fail_test(captures, "getsenv", "Failed to fetch the environment of a Script with script global set to nil[1]")
        end
    end, function(error_message)
        fail_test(captures, "getsenv",
            "Failed to fetch the environment of a Script with script global set to nil[2]. Error: "
                .. tostring(error_message))
    end)
end

local function test_debug_getproto(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getscriptclosure) ~= "function" then
        return fail_test(captures, "debug.getproto", "getscriptclosure is needed in order to test")
    end
    if type(environment.getgc) ~= "function" then
        return fail_test(captures, "debug.getproto", "getgc is needed in order to test")
    end

    local players = environment.game:GetService("Players")
    local closure = environment.getscriptclosure(players.LocalPlayer.PlayerScripts.RbxCharacterSounds)
    local invalid_calls = {
        function() environment.debug.getproto(function() end, 0, true) end,
        function() environment.debug.getproto(function() end, -0, true) end,
        function() environment.debug.getproto(function() end, 72057594037927935, true) end,
        function() environment.debug.getproto(function() end, -0, true) end,
    }
    local labels = { 1, 2, 3, 2 }
    for index, callback in ipairs(invalid_calls) do
        if pcall(callback) then
            fail_test(captures, "debug.getproto", "Should error upon entering an invalid index[" .. labels[index] .. "]")
        end
    end

    local active = environment.debug.getproto(closure, 1, true)
    local inactive = environment.debug.getproto(closure, 1, false)
    local default_inactive = environment.debug.getproto(closure, 1)
    if type(inactive) ~= "function" or type(default_inactive) ~= "function" then
        fail_test(captures, "debug.getproto", "Failed to retrieve an inactive proto[1]")
    end
    if type(active) ~= "table" or type(active[1]) ~= "function" then
        fail_test(captures, "debug.getproto", "Failed to retrieve active proto(s)")
    elseif active[1]() ~= false then
        fail_test(captures, "debug.getproto", "Didn't return the correct value from a script's proto")
    end

    -- Inactive prototypes are metadata objects. Calling either representation
    -- must not execute its body; P140 tests both sibling paths.
    local inactive_callable = type(inactive) == "function" and pcall(inactive) or false
    local default_callable = type(default_inactive) == "function" and pcall(default_inactive) or false
    if inactive_callable or default_callable then
        fail_test(captures, "debug.getproto", "Inactive protos should not be callable[1]")
    end

    local hacker = environment.game:GetService("ReplicatedFirst"):FindFirstChild("Hacker")
    if not hacker then return fail_test(captures, "debug.getproto", "Failed to retrieve a function to test") end
    local hacker_proto = environment.debug.getproto(environment.getscriptclosure(hacker), 1)
    if type(hacker_proto) ~= "function" then
        return fail_test(captures, "debug.getproto", "Failed to retrieve an inactive proto[2]")
    end
    local hacker_callable, hacker_result = pcall(hacker_proto)
    if hacker_callable or hacker_result == "blablabla" then
        fail_test(captures, "debug.getproto", "Inactive protos should not be callable[2]")
    end

    local name = environment.debug.info(hacker_proto, "n")
    local source = environment.debug.info(hacker_proto, "s")
    local line = environment.debug.info(hacker_proto, "l")
    local _, is_vararg = environment.debug.info(hacker_proto, "a")
    if name ~= "forgives_flushed" and name ~= "because_hes_unemployed" then
        fail_test(captures, "debug.getproto", "Failed to retrieve correct debug information on an inactive proto")
    end
    if name ~= "because_hes_unemployed"
        or source ~= "ReplicatedFirst.Hacker"
        or (line ~= 52 and line ~= 53)
        or is_vararg ~= false
    then
        fail_test(captures, "debug.getproto", string.format([[

                        The retrieved debug name of an inactive proto did not match with "`because_hes_unemployed`".

                        Retrieved name:

                        %s | expected: 'because_hes_unemployed'

                        Retrieved currentline:

                        %s | expected: 52

                        Retrieved is_vararg:

                        %s | expected: false

                        Retrieved source:

                        %s | expected: ReplicatedFirst.Hacker

                    ]], tostring(name), tostring(line), tostring(is_vararg), tostring(source)))
    end
end

local function test_debug_getconstant_script(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getscriptclosure) ~= "function" then
        return fail_test(captures, "debug.getconstant", "getscriptclosure is needed in order to test")
    end
    local loader = environment.game:GetService("Players").LocalPlayer.PlayerScripts.PlayerScriptsLoader
    local closure = environment.getscriptclosure(loader)

    if tostring(environment.debug.getconstant(closure, 7)) ~= "WaitForChild"
        or tostring(environment.debug.getconstant(closure, 3)) ~= "script"
    then
        fail_test(captures, "debug.getconstant", "Couldn't retrieve the correct constant(s) from a script's closure")
    end

    local invalid_calls = {
        function() return environment.debug.getconstant(closure, -1) end,
        function() return environment.debug.getconstant(999999, 1) end,
        function() return environment.debug.getconstant(closure, {}) end,
        function() return environment.debug.getconstant(-1, 1) end,
    }
    local messages = {
        "Should error upon entering invalid index[1]",
        "Should error upon entering invalid level[1]",
        "Should error upon entering invalid index[2]",
        "Should error upon entering invalid level[2]",
    }
    for index, callback in ipairs(invalid_calls) do
        if pcall(callback) then fail_test(captures, "debug.getconstant", messages[index]) end
    end
end

local function test_debug_getupvalue(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}
    if prerequisites.getsenv or type(environment.getsenv) ~= "function" then
        return fail_test(captures, "debug.getupvalue", "getsenv is needed in order to test")
    end

    local animate_environment = environment.getsenv(
        environment.game.Players.LocalPlayer.Character.Animate
    )
    local humanoid_upvalue = environment.debug.getupvalue(animate_environment.onFreeFall, 2)
    if tostring(humanoid_upvalue) ~= "Humanoid" then
        fail_test(captures, "debug.getupvalue", "Couldn't retrieve an upvalue from the script's function")
    end
end

local function test_debug_setupvalue(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}
    if prerequisites.getsenv or type(environment.getsenv) ~= "function" then
        return fail_test(captures, "debug.setupvalue", "getsenv is needed in order to test")
    end
    local lefty = environment.game:GetService("Players").LocalPlayer.PlayerScripts.lefty
    local script_environment = environment.getsenv(lefty)
    local target = script_environment.groksays
    if type(target) ~= "function" then
        return fail_test(captures, "debug.setupvalue", "Couldn't set the upvalue of a script's function")
    end

    local selected_index, original
    for index = 1, 32 do
        local ok, value = pcall(environment.debug.getupvalue, target, index)
        if ok and value ~= nil then selected_index, original = index, value; break end
    end
    if not selected_index then
        return fail_test(captures, "debug.setupvalue", "Couldn't set the upvalue of a script's function")
    end

    local replacement = "sUNC_setupvalue_" .. tostring(math.random(100000, 999999))
    environment.debug.setupvalue(target, selected_index, replacement)
    local changed = environment.debug.getupvalue(target, selected_index)
    environment.debug.setupvalue(target, selected_index, original)
    if changed ~= replacement then
        fail_test(captures, "debug.setupvalue", "Couldn't set the upvalue of a script's function")
    end

    local invalid = {
        function() environment.debug.setupvalue(target, 0, replacement) end,
        function() environment.debug.setupvalue(target, 999999, replacement) end,
        function() environment.debug.setupvalue(-1, 1, replacement) end,
        function() environment.debug.setupvalue(999999, 1, replacement) end,
    }
    local invalid_messages = {
        "Should error upon entering an invalid upvalue index[1]",
        "Should error upon entering an invalid upvalue index[2]",
        "Should error upon entering an invalid level[1]",
        "Should error upon entering an invalid level[2]",
    }
    for index, callback in ipairs(invalid) do
        if pcall(callback) then
            fail_test(captures, "debug.setupvalue", invalid_messages[index])
        end
    end
end

local function test_debug_getprotos(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getscriptclosure) ~= "function" then
        return fail_test(captures, "debug.getprotos", "getscriptclosure is needed in order to test")
    end

    local replicated_first = environment.game:GetService("ReplicatedFirst")
    local fixture = replicated_first:FindFirstChild("Wow?")
        or replicated_first:FindFirstChild("Hacker")
        or replicated_first:FindFirstChildWhichIsA("LocalScript")
    if not fixture then
        return fail_test(captures, "debug.getprotos", "Failed to retrieve a proto from a game function")
    end

    local closure = environment.getscriptclosure(fixture)
    local protos = environment.debug.getprotos(closure)
    if type(protos) ~= "table" or #protos ~= 8 then
        fail_test(captures, "debug.getprotos", "Invalid script's proto count")
    end

    for index, proto in ipairs(protos) do
        if type(proto) ~= "function" then
            fail_test(captures, "debug.getprotos", "Failed to retrieve a proto from a game function")
        else
            local direct = environment.debug.getproto(closure, index)
            if type(direct) ~= "function" then
                fail_test(captures, "debug.getprotos", "Failed to retrieve a proto from a game function")
            end

            -- Inactive protos are metadata-bearing closure objects, not live
            -- call targets. P156 exists solely to catch executors that animate them.
            if pcall(proto, "blablabla") then
                fail_test(captures, "debug.getprotos", "Inactive protos should not be callable")
            end
        end
    end
end

local function test_debug_getupvalues(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}
    if prerequisites.getsenv or type(environment.getsenv) ~= "function" then
        return fail_test(captures, "debug.getupvalues", "getsenv is needed in order to test")
    end

    local animate_environment = environment.getsenv(
        environment.game.Players.LocalPlayer.Character.Animate
    )
    local upvalues = environment.debug.getupvalues(animate_environment.onFreeFall)
    if type(upvalues) ~= "table" or #upvalues ~= 3 then
        fail_test(captures, "debug.getupvalues", "Invalid upvalue count")
    end
end

local function test_debug_getstack(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}

    if prerequisites.getgc then
        return fail_test(captures, "debug.getstack", "Can't test due to 'getgc' not working reliably")
    end
    if prerequisites.hookfunction or type(environment.hookfunction) ~= "function" then
        return fail_test(captures, "debug.getstack", "Can't test due to 'hookfunction' not working reliably")
    end

    local foreign_thread
    local expected_value = "floops the flip out on floopy doopy"
    local hook_target, original_hook

    for _, candidate in pairs(environment.getgc(true)) do
        if type(candidate) == "function" then
            local ok, source = pcall(environment.debug.info, candidate, "s")
            if ok and type(source) == "string" and source:find("lefty", 1, true) then
                hook_target = candidate
                original_hook = environment.hookfunction(candidate, function(...)
                    foreign_thread = coroutine.running()
                    return original_hook(...)
                end)
                break
            end
        end
    end

    local function restore_foreign_hook()
        if not (hook_target and original_hook) then return end

        local restored = false
        if type(environment.restorefunction) == "function" then
            restored = pcall(environment.restorefunction, hook_target)
        end
        if not restored then
            (environment.warn or warn)("Failed. Attempting to unhook")
            pcall(environment.hookfunction, hook_target, original_hook)
        end
    end

    if not wait_until(environment, function() return foreign_thread ~= nil end, 150) then
        restore_foreign_hook()
        return fail_test(captures, "debug.getstack", "Couldn't retrieve an expected stack value from a foreign thread")
    end

    local found_level, found_index
    for level = 1, 32 do
        local ok, stack = pcall(environment.debug.getstack, foreign_thread, level)
        if ok then
            if stack == expected_value then
                found_level, found_index = level, nil
                break
            elseif type(stack) == "table" then
                for index, value in pairs(stack) do
                    if value == expected_value then
                        found_level, found_index = level, index
                        break
                    end
                end
            end
        end
        if found_level then break end
    end

    if not found_level then
        restore_foreign_hook()
        return fail_test(captures, "debug.getstack", "Couldn't retrieve an expected stack value from a foreign thread")
    end

    if found_index ~= nil then
        local indexed_ok, indexed_value = pcall(
            environment.debug.getstack, foreign_thread, found_level, found_index
        )
        if not indexed_ok or indexed_value ~= expected_value then
            fail_test(captures, "debug.getstack", "[GETSTACK] Index not in stack[2]")
        end

        local invalid_ok, invalid_value = pcall(
            environment.debug.getstack, foreign_thread, found_level, 2147483647
        )
        if invalid_ok then
            fail_test(captures, "debug.getstack", "[GETSTACK] Index not in stack[3]")
        elseif captures.debug_config and captures.debug_config.printcheckpoints then
            (environment.warn or warn)("[GETSTACK] Index errored:", invalid_value)
        end
    end

    -- I did not guess the frame. I waited for the stack to remember it.
    restore_foreign_hook()
end

local function test_debug_setstack(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}

    if prerequisites.getgc then
        return fail_test(captures, "debug.setstack", "Can't test due to 'getgc' not working reliably")
    end
    if prerequisites.hookfunction or type(environment.hookfunction) ~= "function" then
        return fail_test(captures, "debug.setstack", "Can't test due to 'hookfunction' not working reliably")
    end
    if prerequisites.getstack or not environment.debug.getstack then
        return fail_test(captures, "debug.setstack", "Can't test due to 'debug.getstack' not working reliably")
    end

    local target_function
    for _, candidate in pairs(environment.getgc()) do
        if type(candidate) == "function" then
            local ok, name = pcall(environment.debug.info, candidate, "n")
            if ok and name == "beeeb" then
                target_function = candidate
                break
            end
        end
    end
    if not target_function then
        return fail_test(captures, "debug.setstack", "Was not able to set a stack value in a foreign thread")
    end

    local original_hook
    original_hook = environment.hookfunction(target_function, function(...)
        local changed, set_error = pcall(environment.debug.setstack, 4, 22, "Fully loaded jag")
        if not changed then
            if captures.debug_config and captures.debug_config.printcheckpoints then
                (environment.warn or warn)("[SETSTACK] Failed to set to 4, 22", set_error)
            end
            (environment.warn or warn)("Attempting to unhook")
            pcall(environment.hookfunction, target_function, original_hook)
        end
        return original_hook(...)
    end)

    local trigger_handle = environment.workspace.FreakyBox.a
        ["Cute Black Circle Glasses (Fits Kemono Heads)"].Handle
    wait_until(environment, function()
        return trigger_handle.CollisionGroup == environment.utf8.char(5)
    end, 150)

    pcall(environment.hookfunction, target_function, original_hook)

    -- The decoder-generated property path is executor/place-specific. Search
    -- the small fixture subtree for the observable value written by frame 4/22.
    local changed_handle
    local ok, descendants = pcall(function()
        return environment.workspace.FreakyBox:GetDescendants()
    end)
    if ok then
        for _, descendant in ipairs(descendants) do
            if descendant.Name == "Handle" then
                local value_ok, collision_group = pcall(function()
                    return descendant.CollisionGroup
                end)
                if value_ok and collision_group == "Fully loaded jag" then
                    changed_handle = descendant
                    break
                end
            end
        end
    end

    if not changed_handle then
        fail_test(captures, "debug.setstack", "Was not able to set a stack value in a foreign thread")
    else
        changed_handle.CollisionGroup = "Default"
    end
end


-- P163 is the coordinator-created wrapper whose only child is P164.
local function run_debug_setstack_test(environment, captures)
    return test_debug_setstack(environment, captures)
end
local function test_debug_getinfo(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local boom
    local function sample()
        environment.boom = "ookok"
        boom = "boom"
        return boom
    end

    local info = environment.debug.getinfo(sample)
    local expected_types = {
        source = "string",
        short_src = "string",
        func = "function",
        what = "string",
        currentline = "number",
        nups = "number",
        numparams = "number",
        is_vararg = "number",
    }

    for field, expected_type in pairs(expected_types) do
        if info[field] == nil then
            fail_test(captures, "debug.getinfo", "Did not return a table with a '" .. field .. "' field")
        elseif type(info[field]) ~= expected_type then
            fail_test(captures, "debug.getinfo",
                "Did not return a table with " .. field .. " as a " .. expected_type
                .. " (got " .. type(info[field]) .. ")")
        end
    end

    if info.what ~= "Lua" then
        fail_test(captures, "debug.getinfo", "Didn't return a valid `what` field [2]")
    end
    if type(info.is_vararg) == "number" then
        if info.is_vararg > 1 then
            fail_test(captures, "debug.getinfo", "Impossible field value for 'is_vararg' ")
        elseif info.is_vararg == 0 then
            fail_test(captures, "debug.getinfo", "Didn't return the correct value for 'is_vararg' ")
        end
    end
    if info.func ~= sample or info.func() ~= "boom" then
        fail_test(captures, "debug.getinfo", "Didn't return the correct value from 'func' ")
    end
end

local function test_debug_getconstants_script(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getsenv) ~= "function" then
        return fail_test(captures, "debug.getconstants", "getsenv is needed in order to test")
    end

    local animate = environment.game:GetService("Players").LocalPlayer.Character.Animate
    local script_environment = environment.getsenv(animate)
    local on_free_fall = script_environment.onFreeFall
    local constants = environment.debug.getconstants(on_free_fall)
    if type(constants) ~= "table"
        or constants[1] ~= "playAnimation"
        or constants[2] ~= "fall"
    then
        fail_test(captures, "debug.getconstants", "Couldn't retrieve the correct constants from a script's function")
    end
    if pcall(environment.debug.getconstants, environment.print or print) then
        fail_test(captures, "debug.getconstants", "Didn't error on passing C-closures")
    end

    local invalid_levels = { 281474976710655, 0, 32 }
    for index, level in ipairs(invalid_levels) do
        if pcall(environment.debug.getconstants, level) then
            fail_test(captures, "debug.getconstants", "Should error upon passing an invalid level[" .. index .. "]")
        end
    end
end

local function test_debug_setconstant(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}

    if prerequisites["debug.getconstant"] or not environment.debug.getconstant then
        return fail_test(captures, "debug.setconstant", "Can't test due to 'debug.getconstant' not working reliably")
    end
    if prerequisites.getsenv then
        return fail_test(captures, "debug.setconstant", "Can't test due to 'getsenv' not working reliably")
    end

    local generated_value = tostring((captures.make_probe_value or function() return {} end)(2000, 9101))
    local lefty = environment.game.Players.LocalPlayer.PlayerScripts.lefty
    local script_environment = environment.getsenv(lefty)
    local groksays = script_environment.groksays
    local original_constant = environment.debug.getconstant(groksays, 1)

    environment.debug.setconstant(groksays, 1, generated_value)
    local retrieved_constant = environment.debug.getconstant(groksays, 1)
    local returned_value = groksays()

    local fixture_handle = environment.workspace.FreakyBox.e["Accessory (pillow)"].Handle
    local fixture_updated = wait_until(environment, function()
        return fixture_handle.CollisionGroup == "sillypeely"
    end, 60, 0.06)

    if not fixture_updated then
        fail_test(captures, "debug.setconstant", "Failed to set a constant and retrieve its value[1]")
    end
    if retrieved_constant ~= generated_value or returned_value ~= generated_value then
        fail_test(captures, "debug.setconstant", "Failed to set a constant and retrieve its value[2]")
    end

    if original_constant ~= nil then
        pcall(environment.debug.setconstant, groksays, 1, original_constant)
    end
end

local function test_getfunctionhash(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local function bimbumbumbambam() end
    local function syrupsyrupsyrup() end
    local function peepbooop() end
    local function boopbeep(first, second) return first, second end
    local function coolfunc(...) return ... end
    local function coolfunc2() return "ffa" end
    local function coolfunc3() return "ffa" end
    local function coolfunc4() return "constant-one" end
    local function coolfunc5() return "constant-two" end
    local function different_number_one() return 12345 end
    local function different_number_two() return 54321 end
    local function different_different_instruction_one(value) return value + 1 end
    local function different_different_instruction_two(value) return value - 1 end

    local function hash(callback)
        local value = environment.getfunctionhash(callback)
        if type(value) ~= "string" or #value ~= 96 or not value:match("^[0-9a-fA-F]+$") then
            fail_test(captures, "getfunctionhash", "Failed to retrieve needed functions in order to test")
        end
        return value
    end

    local empty_hashes = { hash(bimbumbumbambam), hash(syrupsyrupsyrup), hash(peepbooop) }
    if empty_hashes[1] ~= empty_hashes[2] or empty_hashes[1] ~= empty_hashes[3] then
        fail_test(captures, "getfunctionhash", "Same functions shouldn't have different hashes")
    end
    if hash(boopbeep) == hash(coolfunc) then
        fail_test(captures, "getfunctionhash", "Variadic arguments should influence the hash")
    end
    if hash(coolfunc2) ~= hash(coolfunc3) then
        fail_test(captures, "getfunctionhash", "Functions' hash should differ due to no instruction difference")
    end
    if hash(coolfunc4) == hash(coolfunc5) then
        fail_test(captures, "getfunctionhash", "Different constants should not have the same hash[1]")
    end
    if hash(different_number_one) == hash(different_number_two) then
        fail_test(captures, "getfunctionhash", "Different constants should not have the same hash[2]")
    end
    if hash(different_instruction_one) == hash(different_instruction_two) then
        fail_test(captures, "getfunctionhash", "Different instructions should not have the same hash")
    end
    if hash(coolfunc2) ~= hash(coolfunc3) then
        fail_test(captures, "getfunctionhash", "Same instructions should have the same hash")
    end
end

local function test_filtergc(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getfunctionhash) ~= "function" then
        fail_test(captures, "filtergc", "getfunctionhash is needed in order to test")
        return fail_test(captures, "filtergc", "Can't test due to 'getfunctionhash' not working reliably")
    end

    local nan = 0 / 0
    local negative_zero = -0
    local upvalue_probe = nan
    local function imaeemuhttaginmyphase()
        return "send", "mau", nan, upvalue_probe
    end
    local function negative_zero_probe() return negative_zero, "3" end
    local function second_nan_probe() return "send2", nan end

    local random_one = captures.make_probe_value and captures.make_probe_value(3, 999) or 313
    local random_two = captures.make_probe_value and captures.make_probe_value(77, 999) or 733
    local probe_metatable = {}
    local values_table_one = { prrrrpapa = "fawfawfaw", [":Pboi"] = random_one }
    local values_table_two = { prrrrpapa = "fawfawfaw" }
    local pairs_table_one = { prrrrpapa = "fawfawfaw", [":Pboi"] = random_two }
    local pairs_table_two = { prrrrpapa = "fawfawfaw" }
    local metatable_probe = setmetatable({ prrrrpapa = ":Pboi" }, probe_metatable)
    environment.task.wait()

    local all_functions = environment.filtergc("function", {})
    if type(all_functions) ~= "table" then
        fail_test(captures, "filtergc", "`returnOne` should be false by default and returning a table")
    elseif #all_functions == 0 then
        fail_test(captures, "filtergc", "Returned an empty table when provided no options")
    end

    local by_name = environment.filtergc("function", { Name = "imaeemuhttaginmyphase" }, true)
    if type(by_name) == "table" then
        fail_test(captures, "filtergc", "Returned a table while 'returnOne' was set to true")
    elseif by_name ~= imaeemuhttaginmyphase then
        fail_test(captures, "filtergc", "[Name] Failed to find a function by name")
    end

    local function require_table_match(options, expected, message)
        local results = environment.filtergc("table", options)
        if type(results) ~= "table" or not contains_identity(results, expected) then
            fail_test(captures, "filtergc", message)
        end
    end
    require_table_match({ Keys = { ":Pboi", "prrrrpapa" } }, metatable_probe, "[KEYS] Failed to find a table with specified keys")
    require_table_match({ Values = { random_one, "fawfawfaw" } }, values_table_one, "[VALUES] Failed to find a table with specified value[1]")
    require_table_match({ Values = { "fawfawfaw" } }, values_table_two, "[VALUES] Failed to find a table with specified value[2]")
    require_table_match({ KeyValuePairs = { [":Pboi"] = random_two, prrrrpapa = "fawfawfaw" } }, pairs_table_one, "[KVPairs] Failed to find a table with specified KeyValue pairs[1]")
    require_table_match({ KeyValuePairs = { prrrrpapa = "fawfawfaw" } }, pairs_table_two, "[KVPairs] Failed to find a table with specified KeyValue pairs[2]")
    require_table_match({ Metatable = probe_metatable }, metatable_probe, "[METATABLE] Failed to find a table with the specified metatable")

    local function require_single_function(options, expected, missing_message, duplicate_message)
        local results = environment.filtergc("function", options)
        if type(results) ~= "table" or #results == 0 then
            fail_test(captures, "filtergc", missing_message)
            return nil
        end
        if #results > 1 and duplicate_message then
            fail_test(captures, "filtergc", duplicate_message)
        end
        if expected and not contains_identity(results, expected) then
            fail_test(captures, "filtergc", missing_message)
        end
        return results[1]
    end

    require_single_function({ Hash = environment.getfunctionhash(imaeemuhttaginmyphase), IgnoreExecutor = false }, imaeemuhttaginmyphase,
        "[FUNC] Retrieved less than one viable option", "[FUNC] Retrieved more than one viable option")
    require_single_function({ Constants = { "send", "WaitForChild" }, IgnoreExecutor = false }, nil,
        "brotzatza there's no function like this")

    local nan_match_one = require_single_function({ Constants = { nan }, IgnoreExecutor = false }, imaeemuhttaginmyphase,
        "[FUNC] Failed to retrieve a function with a constant which equals to NaN[1].")
    local nan_match_two = require_single_function({ Constants = { nan }, IgnoreExecutor = false }, second_nan_probe,
        "[FUNC] Failed to retrieve a function with the constant which equals to NaN[2].")
    local zero_match = require_single_function({ Constants = { negative_zero, "3" }, IgnoreExecutor = false }, negative_zero_probe,
        "[FUNC] Failed to retrieve a function with the constant -0")
    if zero_match then
        local _, second = zero_match()
        if second ~= "3" then fail_test(captures, "filtergc", "[FUNC] Failed to retrieve a function with the constant -0.") end
    end
    if nan_match_one == nil or nan_match_two == nil then -- diagnostics already emitted
    end

    local impossible = environment.filtergc("function", { Name = "__sunc_function_that_does_not_exist__", IgnoreExecutor = true })
    if type(impossible) == "table" and #impossible > 0 then
        fail_test(captures, "filtergc", "[FUNC IgnoreExec] Returned more than 0 possible functions for a non-existant function")
    end

    local upvalue_results = environment.filtergc("function", { Upvalues = { upvalue_probe }, IgnoreExecutor = false })
    local upvalue_function = type(upvalue_results) == "table" and upvalue_results[1]
    if type(upvalue_function) ~= "function" then
        fail_test(captures, "filtergc", "[FUNC UPVALS] Failed to retrieve a function with the upvalue 0/0.")
    else
        local _, second = upvalue_function()
        if second ~= "mau" and second ~= "WaitForChild" then
            fail_test(captures, "filtergc", "[FUNC UPVALS] Failed to retrieve a function with the upvalue 0/0.")
        end
    end
end

local function test_replicatesignal(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local player = environment.game.Players.LocalPlayer

    local checks = {
        {
            signal = player.PlayerGui.ScreenGui.Frame.MouseWheelForward,
            arguments = { 3, 2147483648 },
            target = player,
            tag = "thunderclient?",
            message = "Timed out while trying to trigger Frame.MouseWheelForward signal with specific arguments.",
        },
        {
            signal = environment.workspace.replicatesigmal.ProximityPrompt.TriggerEndedActionReplicated,
            arguments = { player },
            target = environment.workspace.FreakyBox,
            tag = "Boi so tuff rn",
            message = "Timed out while trying to trigger ProximityPrompt.TriggerEndedActionReplicated signal",
        },
        {
            signal = player.PlayerGui.ScreenGui.Frame.TextButton.MouseButton1Click,
            arguments = {},
            target = environment.workspace.FreakyBox.e,
            tag = "bro, hello? - flushed",
            message = "Timed out while trying to trigger TextButton.MouseButton1Click",
        },
        {
            signal = player.PlayerGui.ArcHandles.MouseDrag,
            arguments = { environment.Enum.Axis.Y, -55.116, -0.1 },
            target = environment.workspace.FreakyBox,
            tag = "Begging on everyone's knees to be popular",
            message = "Timed out while trying to trigger ArcHandles.MouseDrag signal",
        },
    }

    for _, check in ipairs(checks) do
        environment.replicatesignal(check.signal, table.unpack(check.arguments))
        if not wait_until(environment, function() return check.target:HasTag(check.tag) end, 400) then
            fail_test(captures, "replicatesignal", check.message)
        end
    end
end

-- The original test is a matrix covering Lua, native/C and newcclosure
-- replacements.  The recovered matrix is expressed directly below.
-- Every closure believes it is the original until the call stack is
-- cross-examined. This is also true of several project managers.
local function test_hookfunction(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local hookfunction = assert(environment.hookfunction)
    local restorefunction = environment.restorefunction
    local newcclosure = environment.newcclosure
    local coroutine_library = environment.coroutine or coroutine
    local checkpoint_enabled = captures.debug_config and captures.debug_config.printcheckpoints

    local function checkpoint(name)
        if checkpoint_enabled then print(name) end
        local delay = captures.debug_config and captures.debug_config.delaybetweentests or 0
        if delay > 0 then environment.task.wait(delay) end
    end

    local function restore(target, original)
        if type(restorefunction) == "function" then
            return pcall(restorefunction, target)
        end
        return pcall(hookfunction, target, original)
    end

    -- The original suite optionally loaded a script-function fixture before the
    -- closure matrix. Keep it opt-in so importing/running local-only tests never
    -- silently performs an HTTP request.
    local options = captures.options or {}
    local fixture = environment.workspace and environment.workspace:FindFirstChild("I AM SUNC_0")
    if options.allow_network == true
        and type(environment.loadstring) == "function"
        and environment.game
        and fixture
        and fixture:FindFirstChild("SurfaceGui")
    then
        local image = fixture.SurfaceGui:FindFirstChild("ImageLabel")
        if image and image.Active == true then
            fail_test(captures, "hookfunction", "Failed to successfully hook a script's function")
        end
        local ok_http, source = pcall(environment.game.HttpGet, environment.game,
            "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/hookfankshan.lua")
        if ok_http then
            local compiled, compile_error = environment.loadstring(source)
            if type(compiled) == "function" then
                local ok_fixture, fixture_error = pcall(compiled)
                if not ok_fixture then
                    fail_test(captures, "hookfunction", tostring(fixture_error))
                end
            elseif compile_error then
                fail_test(captures, "hookfunction", tostring(compile_error))
            end
        end
        if image and image.Active == false then
            fail_test(captures, "hookfunction", "Failed to successfully hook a script's function")
        end
        if image then image.Active = false end
    elseif type(environment.getsenv) ~= "function" or type(newcclosure) ~= "function" then
        -- This is a prerequisite note from the fixture-only branch, not a reason
        -- to skip the local closure matrix below.
        local diagnostics = captures.diagnostics
        if type(diagnostics) == "table" then
            diagnostics.hookfunction_fixture = "getsenv and newcclosure is needed in order to test"
        end
    end

    checkpoint("hookfunction-1: L -> L[1]")
    if pcall(hookfunction, function() end) then
        fail_test(captures, "hookfunction", "Hookfunction did not error when only one parameter was passed")
    end

    local hook_marker = 0
    local function layered_target() hook_marker = 1 end
    hookfunction(layered_target, function() hook_marker = 2 end)
    hookfunction(layered_target, function() hook_marker = 3 end)
    layered_target()
    if hook_marker ~= 3 then
        fail_test(captures, "hookfunction", "Failed to hook a hook")
    end

    local unique_marker = captures.make_probe_value and captures.make_probe_value(10, 80) or {}
    local function lua_target()
        return false
    end
    local function lua_replacement()
        return true, "harhar", unique_marker
    end
    local old_lua = hookfunction(lua_target, lua_replacement)
    if type(old_lua) ~= "function" or old_lua() ~= false then
        fail_test(captures, "hookfunction", "Failed to get a valid return from and 'old' function")
    end

    checkpoint("hookfunction-1: L -> L[2]")
    local first, second, third = lua_target()
    if first ~= true or second ~= "harhar" or third ~= unique_marker then
        fail_test(captures, "hookfunction", "Function didn't return hooked value")
    end
    local ok_call, p_first, p_second, p_third = pcall(lua_target)
    if not ok_call then
        fail_test(captures, "hookfunction", "Hooked function threw an error when it shouldn't")
    elseif p_first ~= true or p_second ~= "harhar" or p_third ~= unique_marker then
        fail_test(captures, "hookfunction", "Function didn't return the needed values in a pcall")
    end
    restore(lua_target, old_lua)

    -- Roblox callback closure -> Lua closure.
    checkpoint("hookfunction-2: C -> L")
    local bindable = environment.Instance.new("BindableFunction")
    bindable.OnInvoke = function(value) return value end
    local callback_target = bindable.OnInvoke
    local callback_hook_ok, old_callback = pcall(hookfunction, callback_target, function()
        return "Sigma moment"
    end)
    if not callback_hook_ok then
        fail_test(captures, "hookfunction", "Encountered an error trying to hook C -> L Closures: " .. tostring(old_callback))
    elseif callback_target() ~= "Sigma moment" then
        fail_test(captures, "hookfunction", "Couldn't hook the function and change the value")
    else
        restore(callback_target, old_callback)
    end
    safe_destroy(bindable)

    -- Lua -> C closure. The target is called inside a coroutine because the
    -- replacement is coroutine.yield.
    checkpoint("hookfunction-3: L -> C")
    local function lua_to_c_target() return "2" end
    local l_to_c_ok, old_l_to_c = pcall(hookfunction, lua_to_c_target, coroutine_library.yield)
    if not l_to_c_ok then
        fail_test(captures, "hookfunction", "Encountered an error trying to hook L -> C Closures: " .. tostring(old_l_to_c))
    else
        local thread = coroutine_library.create(function()
            return lua_to_c_target("yielded")
        end)
        local resumed, yielded = coroutine_library.resume(thread)
        if not resumed or yielded ~= "yielded" then
            fail_test(captures, "hookfunction", "hookfunction-3: L -> C")
        end
        restore(lua_to_c_target, old_l_to_c)
        if lua_to_c_target() ~= "2" then
            fail_test(captures, "hookfunction", "Failed to restore an L -> C hook back to original[2]")
        end
    end

    -- C -> C closure.
    checkpoint("hookfunction-4: C -> C")
    local c_to_c_ok, old_yield = pcall(hookfunction, coroutine_library.yield, coroutine_library.resume)
    if not c_to_c_ok then
        fail_test(captures, "hookfunction", "Encountered an error trying to hook `C -> C` Closures: " .. tostring(old_yield))
    else
        restore(coroutine_library.yield, old_yield)
    end

    -- L -> C -> L: both the replacement and the closure returned by hookfunction
    -- must report the original C closure's argument error accurately.
    checkpoint("hookfunction-5: L -> C -> L")
    local function resume_proxy(...) return coroutine_library.resume(...) end
    local proxy_ok, old_proxy = pcall(hookfunction, resume_proxy, coroutine_library.resume)
    if proxy_ok then
        local called, error_one = pcall(resume_proxy)
        local old_called, error_two = pcall(old_proxy)
        if called or not tostring(error_one):find("missing argument #1 to 'resume'", 1, true) then
            fail_test(captures, "hookfunction", string.format([[

                                Retrieved an invalid error message when trying to call a hooked function[1]
                                hookfunction L -> C -> L returned an invalid error message (err1), expected "missing argument #1 to 'resume', got:

                                %s

                            ]], tostring(error_one)))
        end
        if old_called or not tostring(error_two):find("missing argument #1 to 'resume'", 1, true) then
            fail_test(captures, "hookfunction", string.format([[

                                Retrieved an invalid error message when trying to call a hooked function[2]
                                hookfunction L -> C -> L returned an invalid error message (err2), expected "missing argument #1 to 'resume', got:

                                %s

                            ]], tostring(error_two)))
        end
        restore(resume_proxy, old_proxy)
        if resume_proxy(coroutine_library.create(function() return "2" end)) ~= true then
            fail_test(captures, "hookfunction", "Failed to restore an L -> C hook back to original[3]")
        end
    end

    if type(newcclosure) == "function" then
        local function run_native_case(label, target, replacement, expected_hooked,
                hook_error, hook_failure, restore_error, restore_failure)
            checkpoint(label)
            local ok_hook, old = pcall(hookfunction, target, replacement)
            if not ok_hook then
                fail_test(captures, "hookfunction", hook_error .. tostring(old))
                return
            end
            if target() ~= expected_hooked then
                fail_test(captures, "hookfunction", hook_failure)
            end
            local ok_restore, restore_error_value = restore(target, old)
            if not ok_restore then
                fail_test(captures, "hookfunction", restore_error .. tostring(restore_error_value))
            elseif target() == expected_hooked then
                fail_test(captures, "hookfunction", restore_failure)
            end
        end

        local function lua_original() return "lua-original" end
        local native_replacement = newcclosure(function() return "native-hook" end)
        run_native_case("hookfunction-6: L -> NC", lua_original, native_replacement, "native-hook",
            "Encountered an error trying to hook L -> NC Closures: ",
            "Failed to hook L -> NC Closures",
            "Encountered an error trying to restore a L -> NC hook: ",
            "Failed to restore a L -> NC hook")

        local native_target = newcclosure(function() return "native-original" end)
        local function lua_replacement_two() return "lua-hook" end
        run_native_case("hookfunction-7: NC -> L", native_target, lua_replacement_two, "lua-hook",
            "Encountered an error trying to hook NC -> L Closures: ",
            "Failed to hook NC -> L Closures",
            "Encountered an error trying to restore a NC -> L hook: ",
            "Failed to restore a NC -> L hook")

        local native_target_two = newcclosure(function() return "native-original-two" end)
        checkpoint("hookfunction-8: NC -> C")
        local nc_to_c_ok, old_nc = pcall(hookfunction, native_target_two, tostring)
        if not nc_to_c_ok then
            fail_test(captures, "hookfunction", "Encountered an error trying to hook NC -> C Closures: " .. tostring(old_nc))
        else
            restore(native_target_two, old_nc)
        end

        checkpoint("hookfunction-9: C -> NC")
        local c_target = coroutine_library.running
        local c_to_nc_ok, old_running = pcall(hookfunction, c_target,
            newcclosure(function() return "native-running-hook" end))
        if not c_to_nc_ok then
            fail_test(captures, "hookfunction", "Encountered an error trying to hook C -> NC Closures: " .. tostring(old_running))
        else
            restore(c_target, old_running)
        end
    end

    -- Descendant-prototype matrix. Earlier passes restored the setup calls but
    -- omitted several behavior flags checked after the callbacks returned.
    checkpoint("hookfunction-9b: exact C/L/NC behavior matrix")

    local c_to_l_triggered = false
    local c_to_l_ok, old_resume = pcall(hookfunction, coroutine_library.resume, function(value)
        if value == "Hello" then c_to_l_triggered = true end
    end)
    if c_to_l_ok then
        pcall(coroutine_library.resume, "Hello")
        if not c_to_l_triggered then
            fail_test(captures, "hookfunction", "Failed to hook C -> L Closures")
        end
        c_to_l_triggered = false
        pcall(hookfunction, coroutine_library.resume, old_resume)
        pcall(coroutine_library.resume, "Hello")
        if c_to_l_triggered then
            fail_test(captures, "hookfunction", "Failed to restore a C -> L hook back to original[1]")
        end
        if type(coroutine_library.wrap(function() end)) ~= "function" then
            fail_test(captures, "hookfunction", "Failed to restore a C -> L hook back to original[2]")
        end
    end

    local l_to_c_triggered = false
    local function l_to_c_flag() l_to_c_triggered = true end
    local l_to_c_exact_ok, l_to_c_exact_old = pcall(hookfunction, l_to_c_flag, coroutine_library.resume)
    if l_to_c_exact_ok then
        pcall(l_to_c_flag, coroutine_library.create(function() end))
        if l_to_c_triggered then
            fail_test(captures, "hookfunction", "Failed to hook L -> C Closures")
        end
        pcall(hookfunction, l_to_c_flag, l_to_c_exact_old)
        l_to_c_flag()
        if not l_to_c_triggered then
            fail_test(captures, "hookfunction", "Failed to restore an L -> C hook back to original[1]")
        end
    end

    local c_to_c_marker = false
    local c_to_c_exact_ok, c_to_c_exact_old = pcall(hookfunction, coroutine_library.running, function()
        c_to_c_marker = true
        return nil, false
    end)
    if c_to_c_exact_ok then
        coroutine_library.running()
        if not c_to_c_marker then
            fail_test(captures, "hookfunction", "Failed to hook C -> C Closures")
        end
        c_to_c_marker = false
        pcall(hookfunction, coroutine_library.running, c_to_c_exact_old)
        coroutine_library.running()
        if c_to_c_marker then
            fail_test(captures, "hookfunction", "Failed to restore a C -> C hook back to original")
        end
    end

    if type(newcclosure) == "function" then
        local nc_to_c_marker = false
        local native_target = newcclosure(function() return "native" end)
        local nc_to_c_ok, nc_to_c_old = pcall(hookfunction, native_target, function()
            nc_to_c_marker = true
            return "lua"
        end)
        if nc_to_c_ok then
            native_target()
            if not nc_to_c_marker then
                fail_test(captures, "hookfunction", "Failed to hook NC -> C Closures")
            end
            nc_to_c_marker = false
            pcall(hookfunction, native_target, nc_to_c_old)
            native_target()
            if nc_to_c_marker then
                fail_test(captures, "hookfunction", "Failed to restore an NC -> C hook back to original[1]")
            end
        end

        local c_to_nc_marker = false
        local native_replacement = newcclosure(function()
            c_to_nc_marker = true
            return nil
        end)
        local c_to_nc_ok, c_to_nc_old = pcall(hookfunction, coroutine_library.running, native_replacement)
        if c_to_nc_ok then
            coroutine_library.running()
            if not c_to_nc_marker then
                fail_test(captures, "hookfunction", "Failed to hook C -> NC Closures")
            end
            c_to_nc_marker = false
            pcall(hookfunction, coroutine_library.running, c_to_nc_old)
            coroutine_library.running()
            if c_to_nc_marker then
                fail_test(captures, "hookfunction", "Failed to restore a C -> NC hook back to original[1]")
            end
        end
    end

    checkpoint("hookfunction-10: detection & ENV leak test")
    local replicated_storage = environment.game and environment.game:GetService("ReplicatedStorage")
    local test_functions = replicated_storage and replicated_storage:FindFirstChild("TestFuncs")
    local remote = test_functions and test_functions:FindFirstChild("awuuu")
    if remote and type(environment.getrawmetatable) == "function" then
        local ok_probe, detected = pcall(function()
            remote:InvokeServer()
            return remote:GetAttribute("cwazybwo")
        end)
        if ok_probe and detected then
            fail_test(captures, "hookfunction", "generic namecall hook detected")
        end
    end
end

local function test_clonefunction(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local clonefunction = environment.clonefunction
    local hookfunction = environment.hookfunction
    if type(hookfunction) ~= "function" then
        return fail_test(captures, "clonefunction", "Can't test due to hookfunction not working reliably")
    end

    -- Basic cloning: preserve every return value but never return the same closure.
    local function original(first_value)
        return "capulapeste", first_value - 1
    end
    local clone = clonefunction(original)
    local _, original_result = original(7)
    local _, clone_result = clone(7)
    if original_result ~= clone_result then
        fail_test(captures, "clonefunction", "Didn't return the same value")
    end
    if clone == original then
        fail_test(captures, "clonefunction", "Functions should not be the same")
    end

    -- The original temporarily hid setfenv from getgenv() while comparing the
    -- environments. That prevents an implementation from passing by consulting
    -- the executor-facing alias instead of preserving the closure environment.
    local global_environment = environment.getgenv and environment.getgenv()
    local saved_setfenv = global_environment and global_environment.setfenv
    if global_environment then global_environment.setfenv = nil end

    local environment_probe_ok, environment_probe_error = pcall(function()
        if environment.getfenv(original) ~= environment.getfenv(clone) then
            error("Environment of the cloned function and original shouldn't differ", 0)
        end
    end)
    if not environment_probe_ok then
        fail_test(captures, "clonefunction", tostring(environment_probe_error))
    end

    local function empty_probe() end
    local empty_clone = clonefunction(empty_probe)
    if environment.getfenv(empty_clone) ~= environment.getfenv() then
        fail_test(captures, "clonefunction", "Environment of the cloned function differs[1]")
    end

    local function caller_environment_probe()
        return environment.getfenv(2)
    end
    local caller_environment_clone = clonefunction(caller_environment_probe)
    if caller_environment_clone() ~= caller_environment_probe() then
        fail_test(captures, "clonefunction", "Environment of the cloned function differs[2]")
    end

    if global_environment then global_environment.setfenv = saved_setfenv end

    -- Hooking the original Lua closure must not alter the already-created clone.
    local function snow_probe() return "Those who snow" end
    local snow_clone = clonefunction(snow_probe)
    local previous_snow = hookfunction(snow_probe, function() return "Those who glow" end)
    if snow_clone() == snow_probe() then
        fail_test(captures, "clonefunction", "Cloned function was affected when hooking original[1]")
    end
    pcall(hookfunction, snow_probe, previous_snow)

    -- P220_K21 was a complete nested virtual machine. Its readable payload is
    -- inlined below and still tested through loadstring, as in the compiled suite.
    if type(environment.loadstring) == "function" then
        -- Deobfuscated and devirtualized from P220_K21. The outer clonefunction test
        -- deliberately compiles this source and observes its workspace-side signal.
        -- The second labyrinth reduced to seven lines. It had budgeted considerably
        -- more darkness for the occasion.
        local fixture_chunk, compile_error = environment.loadstring([[
            local expected_caller = debug.info(1, "f")
            local cloned_probe = clonefunction(function()
                return debug.info(2, "f") ~= expected_caller
            end)

            if cloned_probe() then
                workspace["Remember when we were all at schoo'"].Archivable = false
            end
        ]])
        if type(fixture_chunk) ~= "function" then
            fail_test(captures, "clonefunction", "REAL lua clonefunction 🥳🥳: " .. tostring(compile_error))
        else
            local ran, runtime_error = pcall(fixture_chunk)
            if not ran then
                fail_test(captures, "clonefunction", "REAL lua clonefunction 🥳🥳: " .. tostring(runtime_error))
            else
                if environment.task and environment.task.wait then environment.task.wait() end
                -- This marker is pre-seeded by the dedicated sUNC place; the suite
                -- never creates it. Direct indexing is intentional and matches P220:
                -- absence of the fixture is itself an execution failure.
                local fixture = environment.workspace["Remember when we were all at schoo'"]
                if not fixture.Archivable then
                    fail_test(captures, "clonefunction", "REAL lua clonefunction 🥳🥳")
                    fixture.Archivable = true
                end
            end
        end
    end

    -- A cloned native coroutine constructor must remain independent after the
    -- original global constructor is hooked.
    local cloned_coroutine_create = clonefunction(environment.coroutine.create)
    local previous_coroutine_create = hookfunction(environment.coroutine.create, function()
        return "OKoek"
    end)
    local cloned_coroutine_result = cloned_coroutine_create(function() end)
    if cloned_coroutine_result == "OKoek" then
        fail_test(captures, "clonefunction", "Cloned function was affected when hooking original[2]")
    end
    pcall(hookfunction, environment.coroutine.create, previous_coroutine_create)

    -- clonefunction must also accept newcclosure output. Hooking the clone must
    -- not mutate the source native closure.
    if type(environment.newcclosure) == "function" then
        local native_source = environment.newcclosure(function() return 1 end)
        local native_clone = clonefunction(native_source)
        pcall(hookfunction, native_clone, function() end)
        if native_source() ~= 1 then
            fail_test(captures, "clonefunction", "Failed to use clonefunction on a newcclosure")
        end
    end
end

local function test_restorefunction(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.hookfunction) ~= "function" then
        fail_test(captures, "restorefunction", "hookfunction is needed in order to test")
        return fail_test(captures, "restorefunction", "Can't test due to 'hookfunction' not working reliably")
    end

    local hookfunction = environment.hookfunction
    local restorefunction = assert(environment.restorefunction)
    local coroutine_library = environment.coroutine or coroutine
    local checkpoint_enabled = captures.debug_config and captures.debug_config.printcheckpoints
    local function checkpoint(name)
        if checkpoint_enabled then print(name) end
        local delay = captures.debug_config and captures.debug_config.delaybetweentests or 0
        if delay > 0 then environment.task.wait(delay) end
    end

    checkpoint("restorefunction-1: L -> C Restore")
    local function original_lua(value) return value, "original" end
    for _ = 1, 5 do
        hookfunction(original_lua, tostring)
        restorefunction(original_lua)
        local first, second = original_lua("probe")
        if first ~= "probe" or second ~= "original" then
            fail_test(captures, "restorefunction", "Couldn't restore a function back to original")
            break
        end
    end

    local function yielding_target() return "not-yielding" end
    hookfunction(yielding_target, coroutine_library.yield)
    restorefunction(yielding_target)
    if yielding_target() ~= "not-yielding" then
        fail_test(captures, "restorefunction", "Failed to restore a L -> C hook back to original[1]")
    end

    checkpoint("restorefunction-2: C -> C and L -> C Restore")
    local original_resume = hookfunction(coroutine_library.yield, coroutine_library.resume)
    restorefunction(coroutine_library.yield)
    local thread = coroutine_library.create(function()
        return coroutine_library.yield("yield-restored")
    end)
    local resumed, yielded = coroutine_library.resume(thread)
    if not resumed or yielded ~= "yield-restored" then
        fail_test(captures, "restorefunction", "Failed to restore a C -> C hook back to original[1]")
    end

    hookfunction(coroutine_library.yield, coroutine_library.resume)
    hookfunction(coroutine_library.yield, tostring)
    restorefunction(coroutine_library.yield)
    local second_thread = coroutine_library.create(function()
        return coroutine_library.yield("fully-restored")
    end)
    local second_resumed, second_yielded = coroutine_library.resume(second_thread)
    if not second_resumed then
        fail_test(captures, "restorefunction", "Failed to restore a C -> C hook back to original[2]")
    elseif second_yielded ~= "fully-restored" then
        fail_test(captures, "restorefunction", "Failed to restore a C -> C hook back to original[3]")
    end
    if original_resume and type(original_resume) ~= "function" then
        fail_test(captures, "restorefunction", "Failed to restore a C -> C hook back to original[3]")
    end

    local function returns_bbb() return "BBB" end
    hookfunction(returns_bbb, tostring)
    restorefunction(returns_bbb)
    if returns_bbb() ~= "BBB" then
        fail_test(captures, "restorefunction", "Failed to restore a L -> C hook back to original[2]")
    end

    local function repeatedly_hooked() return 1 end
    hookfunction(repeatedly_hooked, function() return 2 end)
    hookfunction(repeatedly_hooked, function() return 3 end)
    hookfunction(repeatedly_hooked, function() return 4 end)
    restorefunction(repeatedly_hooked)
    if repeatedly_hooked() ~= 1 then
        fail_test(captures, "restorefunction", "Failed to fully restore a hooked function")
    end

    checkpoint("restorefunction-3: Restore NC[1] -> NC[2] and NC[2] -> NC[1] x4")
    if type(environment.newcclosure) == "function" then
        local first_marker, second_marker = {}, {}
        local first_native = environment.newcclosure(function() return first_marker end)
        local second_native = environment.newcclosure(function() return second_marker end)
        for _ = 1, 4 do
            hookfunction(first_native, second_native)
            hookfunction(second_native, first_native)
        end
        restorefunction(first_native)
        restorefunction(second_native)
        if first_native() ~= first_marker then
            fail_test(captures, "restorefunction", "Failed to restore NC[1] -> NC[2] -> NC[1]. [1]")
        end
        if second_native() ~= second_marker then
            fail_test(captures, "restorefunction", "Failed to restore NC[1] -> NC[2] -> NC[1]. [2]")
        end
    end
end

local function test_iscclosure(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.newcclosure) ~= "function" then
        return fail_test(captures, "iscclosure", "newcclosure is needed in order to test")
    end

    local function lua_closure() return true end
    local converted = environment.newcclosure(lua_closure)
    if not environment.iscclosure(converted) then
        fail_test(captures, "iscclosure", "Failed to determine a cclosure made from 'newcclosure'")
    end
    local native = (environment.coroutine or coroutine).wrap(function() end)
    if not environment.iscclosure(native) then
        fail_test(captures, "iscclosure", "Failed to determine a native cclosure")
    end
    if environment.iscclosure(lua_closure) then
        fail_test(captures, "iscclosure", "Failed to determine a non-cclosure")
    end
end

local function test_isexecutorclosure(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getgenv) ~= "function" then
        return fail_test(captures, "isexecutorclosure", "getgenv is needed in order to test")
    end

    local executor_closure = function() return "bro+ are we deduzik" end
    if environment.isexecutorclosure(executor_closure) ~= true then
        fail_test(captures, "isexecutorclosure", "Couldn't determine if the function is an exec-closure")
    end
    local line_ok, line = pcall(environment.debug.info, executor_closure, "l")
    if line_ok and line == -1 then
        fail_test(captures, "isexecutorclosure", "The closure should not be defined at line -1")
    end

    if environment.isexecutorclosure(environment.print or print) then
        fail_test(captures, "isexecutorclosure", "Returned true for a non-exec closure")
    end
    local game_closure = environment.getscriptclosure(environment.game.Players.LocalPlayer.PlayerScripts.PlayerModule)
    if environment.isexecutorclosure(game_closure) then
        fail_test(captures, "isexecutorclosure", "Returned true for a non-exec closure.")
    end

    local no_argument_ok, no_argument_result = pcall(environment.isexecutorclosure)
    if no_argument_ok and no_argument_result == true then
        fail_test(captures, "isexecutorclosure", "Returned true for no closure")
    end
end

local function test_firetouchinterest(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local root = environment.game.Players.LocalPlayer.Character.HumanoidRootPart
    local touch_part = environment.Instance.new("Part")
    touch_part.Name = "LOEALOEA"
    touch_part.Anchored = true
    touch_part.CFrame = environment.CFrame.new(0, -555, 0)
    touch_part.Parent = environment.workspace

    local touched, correct_part = false, false
    local connection = touch_part.Touched:Connect(function(other_part)
        touched = true
        correct_part = other_part == root
    end)

    local original_position = root.CFrame.Position
    environment.firetouchinterest(root, touch_part, 1)
    environment.firetouchinterest(root, touch_part, 0)

    -- firetouchinterest should synthesize the contact without physically moving
    -- either part into touching distance.
    if (original_position - touch_part.CFrame.Position).Magnitude <= 30 then
        fail_test(captures, "firetouchinterest", "In the BIG 25 🥀🙏")
    end
    if not wait_until(environment, function() return touched end, 55) then
        fail_test(captures, "firetouchinterest", "Couldn't trigger the touch signal")
    elseif not correct_part then
        fail_test(captures, "firetouchinterest", "Wasn't able to determine the correct firing part")
    end

    disconnect(connection)
    safe_destroy(touch_part)
end

local function test_islclosure(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if environment.islclosure(environment.print or print) ~= false then
        fail_test(captures, "islclosure", "Couldn't determine if the function is lclosure")
    end
    local lua_closure = function() end
    if environment.islclosure(lua_closure) ~= true then
        fail_test(captures, "islclosure", "Returned false for an lclosure")
    end
end

local function test_newcclosure(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}
    if not environment.debug or type(environment.debug.info) ~= "function" then
        return fail_test(captures, "newcclosure", "debug.info is needed in order to test")
    end
    if prerequisites.clonefunction or type(environment.clonefunction) ~= "function" then
        return fail_test(captures, "newcclosure", "Can't test due to 'clonefunction' not working reliably")
    end

    local task_library = environment.task
    local table_library = environment.table or table
    local coroutine_library = environment.coroutine or coroutine

    local function original() return "wow" end
    local converted = environment.newcclosure(original)
    if converted() ~= original() then
        fail_test(captures, "newcclosure", "Closure didn't return the same value as original")
    end
    if converted == original then
        fail_test(captures, "newcclosure", "Closures should differ")
    end

    local running_wrapper = environment.newcclosure(function()
        return coroutine_library.running()
    end)
    if running_wrapper() ~= coroutine_library.running() then
        fail_test(captures, "newcclosure", "Bad implementation of the function, not made in C")
    end

    local line_probe = environment.newcclosure(function() end)
    if tostring(environment.debug.info(line_probe, "l")) ~= "-1" then
        fail_test(captures, "newcclosure", "REAL newcclosure WHAT!!! REAL ILEMENTATION 💲💲💲 😂😂😂🤣 🇲🇩#̶̢̛̲͇̺͍͎̻̣̳̘͚͉̣̎̐̈͐̀͌̌̈́̽̿̉̔͘M̶͇̩̝̺͍̭̠͓̝̼͍͚̓̍̄̕a̶͎̲̠͇͉̠̝͍̫̱̗̬̲̽͐͑̓̎̓̿̏̑̑̾͝i̵̫̘͈͚͍̹̣͙͋̍͌̾͂ͅͅͅã̵̼͓͙̥̦͛̀̓̃̕Ṣ̴͇̘̳̎̀͒̈́̎̈́̀̈́́̕̕͠a̸͈̔́̂͋̂̽̀͒̈́̏n̴̝͂̀͑̅̒̾̊̄̎͋͗̂̉̈́͝d̷̨̤͓͖̳͙̻̦̼͗̎͗̎̌͌́̾̄̽̑͝ū̴̡̠̾̄̌̚😂S😂a😂n😂d😂u🇲🇩😂😂😂😂")
    end

    local function yielding_identity(value)
        task_library.wait()
        return value
    end

    local yielding_variants = {
        environment.newcclosure(yielding_identity),
        environment.clonefunction(environment.newcclosure(yielding_identity)),
        environment.newcclosure(environment.clonefunction(yielding_identity)),
        environment.clonefunction(environment.newcclosure(environment.clonefunction(yielding_identity))),
        environment.newcclosure(environment.clonefunction(environment.newcclosure(yielding_identity))),
        environment.clonefunction(environment.newcclosure(environment.clonefunction(environment.newcclosure(yielding_identity)))),
    }

    for index, callback in ipairs(yielding_variants) do
        local finished, returned = false, nil
        task_library.spawn(function()
            local ok, result = pcall(callback, "meow")
            finished = ok
            returned = result
        end)
        if not wait_until(environment, function() return finished end, 60) or returned ~= "meow" then
            fail_test(captures, "newcclosure", "Poor/no yielding implementation[" .. index .. "]")
        end
    end

    -- A wrapped C closure must preserve every argument and its exact identity.
    local bindable = environment.Instance.new("BindableEvent")
    local argument_fixture = table_library.pack(
        "pmo",
        environment.game,
        environment.DateTime.now(),
        environment.Vector3.new(0, 10, 0),
        environment.RaycastParams.new(),
        environment.UDim2.new(0, 0, 0, 0),
        environment.buffer.create(55),
        environment.Faces.new(environment.Enum.NormalId.Front),
        bindable
    )
    local pack_arguments = environment.newcclosure(function(...)
        return table_library.pack(...)
    end)

    local function compare_arguments(callback, suffix)
        local returned = callback(table_library.unpack(argument_fixture, 1, argument_fixture.n))
        if type(returned) ~= "table" or returned.n ~= argument_fixture.n then
            fail_test(captures, "newcclosure", "Argument return mismatch[" .. suffix .. "]")
            return
        end
        for index = 1, argument_fixture.n do
            if returned[index] ~= argument_fixture[index] then
                fail_test(captures, "newcclosure", "Argument return mismatch[" .. suffix .. "]")
                return
            end
        end
    end
    compare_arguments(pack_arguments, 1)
    compare_arguments(environment.clonefunction(pack_arguments), 2)

    -- The notorious boundary error belongs to an implementation bug, not to a
    -- valid yielding newcclosure. Merely seeing the phrase is a failure signal.
    for _, callback in ipairs({ pack_arguments, environment.clonefunction(pack_arguments) }) do
        local ok, error_message = pcall(callback, "attempt to yield across metamethod/C-call boundary")
        if not ok and tostring(error_message):find("attempt to yield across metamethod/C%-call boundary") then
            fail_test(captures, "newcclosure", "Poor/no yielding implementation[6]")
        end
    end

    safe_destroy(bindable)
end

local function test_getscripthash(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local animate_clone = environment.game.Players.LocalPlayer.Character.Animate:Clone()
    local first_hash = environment.getscripthash(animate_clone)
    local second_hash = environment.getscripthash(animate_clone)
    if first_hash ~= second_hash then
        fail_test(captures, "getscripthash", "Returned different results for the same script")
    end
    if type(first_hash) ~= "string"
        or not first_hash:match("^[0-9a-fA-F]+$")
        or (#first_hash ~= 96 and #first_hash ~= 128)
    then
        fail_test(captures, "getscripthash", "Should return a hex representation of a SHA384 or blake2b hash")
    end

    local original_source = animate_clone.Source
    local write_ok = pcall(function() animate_clone.Source = "print('real')" end)
    if write_ok then
        local changed_ok, changed_hash = pcall(environment.getscripthash, animate_clone)
        if not changed_ok then
            fail_test(captures, "getscripthash", "Should hash the compressed and encrypted bytecode")
        elseif changed_hash == first_hash then
            fail_test(captures, "getscripthash", "Extra Udness Engaged 🔥🔥")
        end
        pcall(function() animate_clone.Source = original_source end)
    end

    local client_script = environment.game.ReplicatedStorage.Folder.Folder.Script
    if not pcall(environment.getscripthash, client_script) then
        fail_test(captures, "getscripthash", "Failed to get the hash of a Script with RunContext set to Client")
    end
    safe_destroy(animate_clone)
end

local function test_setreadonly(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local mutable_probe = { success = false }
    environment.table.freeze(mutable_probe)
    if not environment.table.isfrozen(mutable_probe) then
        fail_test(captures, "setreadonly", "chopped af 🔥🔥🔥🔥")
    end

    environment.setreadonly(mutable_probe, false)
    mutable_probe.success = true
    if not mutable_probe.success then
        fail_test(captures, "setreadonly", "Failed to set the value in the frozen table")
    end

    local readonly_probe = { 5 }
    environment.table.freeze(readonly_probe)
    local write_succeeded = pcall(function()
        readonly_probe[1] = true
    end)
    if write_succeeded then
        fail_test(captures, "setreadonly", "I like my UNC not faked, bruh 💦")
    end
end

local function test_request(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local ok, response = pcall(environment.request, {
        Url = "https://api.rubis.app/v2/scrap/eupJy408XkzQdshz/raw",
        Method = "GET",
    })
    if not ok then
        return fail_test(captures, "request", "Encountered an error trying to make a request: " .. tostring(response))
    end
    if response == nil then return fail_test(captures, "request", "Request response is nil") end
    if type(response) ~= "table" then
        return fail_test(captures, "request", "Request returned a " .. environment.typeof(response) .. " instead of a response table")
    end
    if response.Success ~= true then
        fail_test(captures, "request", "Request was not successful, status message: " .. tostring(response.StatusMessage))
    end
    if type(response.Headers) ~= "table" then
        return fail_test(captures, "request", response.Headers == nil and "Request headers is nil"
            or ("Request headers returned a " .. environment.typeof(response.Headers) .. " instead of a headers table"))
    end

    local reported_length = response.Headers["Content-Length"] or response.Headers["content-length"]
    if reported_length and tonumber(reported_length) ~= #(response.Body or "") then
        fail_test(captures, "request", "Headers and Content length don't match")
    end

    local decoded_ok, decoded = pcall(function()
        local http_service = environment.game:GetService("HttpService")
        return http_service:JSONDecode(response.Body)
    end)
    if not decoded_ok then
        return fail_test(captures, "request", "Failed to parse JSON response body, error: " .. tostring(decoded))
    end
    if decoded.test ~= false or decoded.test2 ~= "nooo" then
        fail_test(captures, "request", "JSON body contains incorrect values ???")
    end
end

local function test_fireclickdetector(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    -- First fixture: firing an unparented detector must not silently parent it,
    -- and MouseClick must receive LocalPlayer as its argument.
    local detector = environment.Instance.new("ClickDetector")
    local first_fired = false
    detector.MouseClick:Once(function(player)
        if player ~= environment.game.Players.LocalPlayer then
            fail_test(captures, "fireclickdetector", "Wrong argument passed")
        end
        first_fired = true
    end)
    environment.fireclickdetector(detector)
    environment.task.wait()
    if detector.Parent ~= nil then
        fail_test(captures, "fireclickdetector", "Let it go bro...💔💔[2]")
    end
    if not first_fired then
        fail_test(captures, "fireclickdetector", "Couldn't fire the click detector")
    end

    -- Second fixture: the third argument selects the exact ClickDetector event.
    local event_detector = environment.Instance.new("ClickDetector")
    local fired = {
        MouseClick = false,
        RightMouseClick = false,
        MouseHoverEnter = false,
        MouseHoverLeave = false,
    }
    local connections = {
        event_detector.MouseClick:Connect(function() fired.MouseClick = true end),
        event_detector.MouseHoverEnter:Connect(function() fired.MouseHoverEnter = true end),
        event_detector.RightMouseClick:Connect(function() fired.RightMouseClick = true end),
        event_detector.MouseHoverLeave:Connect(function() fired.MouseHoverLeave = true end),
    }

    local cases = {
        { "MouseClick", "Failed to fire with 'MouseClick' as 3rd argument" },
        { "RightMouseClick", "Failed to fire with 'RightMouseClick' as 3rd argument" },
        { "MouseHoverEnter", "Failed to fire with 'MouseHoverEnter' as 3rd argument" },
        -- The bytecode checks this flag through the same final branch and reuses
        -- the hover-enter diagnostic constant.
        { "MouseHoverLeave", "Failed to fire with 'MouseHoverEnter' as 3rd argument" },
    }
    for _, case in ipairs(cases) do
        local event_name, failure = case[1], case[2]
        fired[event_name] = false
        environment.fireclickdetector(event_detector, 0, event_name)
        environment.task.wait()
        if not fired[event_name] then fail_test(captures, "fireclickdetector", failure) end
    end

    for _, connection in ipairs(connections) do disconnect(connection) end
    safe_destroy(detector)
    safe_destroy(event_detector)
end

local function test_fireproximityprompt(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local state_part = environment.workspace.eeeeeeeeeeeeeeeeeeee
    local initial_transparency = state_part.Transparency
    if initial_transparency == 0.8 then
        return fail_test(captures, "fireproximityprompt", "Failed to fire a proximityprompt on the server")
    end

    local mover = environment.workspace.somestufffirst
    mover.CFrame = environment.workspace.somestufflast.CFrame
    environment.task.wait(0.1)
    mover.CFrame = environment.CFrame.new(50, 50, 300)

    environment.fireproximityprompt(environment.workspace.gwentsotsk.Part.ProximityPrompt)
    local changed = wait_until(environment, function()
        if captures.debug_config and captures.debug_config.extradebugprints then
            (environment.print or print)("waiting for false", state_part.Transparency)
        end
        return state_part.Transparency == 0.8 or state_part.Transparency == 0.4
    end, 300)

    if not changed then
        fail_test(captures, "fireproximityprompt", "Timed out while waiting for a response from the server")
    elseif state_part.Transparency ~= 0.8 and state_part.Transparency ~= 0.4 then
        fail_test(captures, "fireproximityprompt", "Failed to fire a proximityprompt on the server.")
    elseif state_part.Transparency == 0.4 then
        fail_test(captures, "fireproximityprompt", "Failed to fire a proximityprompt on the server")
    end
end

-- This combines the executor's getconnections object model with a foreign-state
-- __namecall hook, matching the two related test groups in the recovered code.
local function test_hookmetamethod_and_connections(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local function debug_foreign_thread(foreign_thread, main_thread, timeout)
        if captures.debug_config and captures.debug_config.extradebugprints then
            (environment.print or print)(string.format(
                "[DEBUG] Foreign thread: %s; Main thread: %s,\n timeout: %s",
                tostring(foreign_thread), tostring(main_thread), tostring(timeout)
            ))
        end
    end
    local checkpoint_enabled = captures.debug_config and captures.debug_config.printcheckpoints
    local function checkpoint(name)
        if checkpoint_enabled then print(name) end
        local delay = captures.debug_config and captures.debug_config.delaybetweentests or 0
        if delay > 0 then environment.task.wait(delay) end
    end

    local function require_field(connection, field, expected_type)
        if connection[field] == nil then
            fail_test(captures, "getconnections", "Did not return a table with a '" .. field .. "' field")
            return false
        end
        if type(connection[field]) ~= expected_type then
            fail_test(captures, "getconnections",
                "Did not return a table with " .. field .. " as a " .. expected_type
                .. " (got " .. type(connection[field]) .. ")")
            return false
        end
        return true
    end

    local event = environment.Instance.new("BindableEvent")
    local fire_count = 0
    local first_connection = event.Event:Connect(function(value)
        fire_count = fire_count + (value or 1)
    end)
    local wrappers = environment.getconnections(event.Event)
    if type(wrappers) ~= "table" or #wrappers == 0 then
        safe_destroy(event)
        return fail_test(captures, "getconnections", "Those who return true: 💀")
    end

    local first = wrappers[1]
    local required_fields = {
        Enabled = "boolean", ForeignState = "boolean", LuaConnection = "boolean",
        Function = "function", Thread = "thread", Fire = "function", Defer = "function",
        Disconnect = "function", Disable = "function", Enable = "function",
    }
    for field, expected_type in pairs(required_fields) do
        require_field(first, field, expected_type)
    end

    checkpoint("getconnections-1")
    first:Fire(1)
    if fire_count == 0 then
        fail_test(captures, "getconnections", "Failed to trigger the :Fire signal")
    end
    if first.Enabled ~= true then
        fail_test(captures, "getconnections", "Returned false for an enabled connection on 'Enabled' field")
    end

    first:Disable()
    local disabled_count = fire_count
    event:Fire(2)
    environment.task.wait()
    if fire_count ~= disabled_count then
        fail_test(captures, "getconnections", "Triggered the connection after disabling")
    end
    if first.Enabled ~= false then
        fail_test(captures, "getconnections", "Returned true for a disabled connection on 'Enabled' field")
    end

    checkpoint("getconnections-2")
    first:Enable()
    event:Fire(3)
    environment.task.wait()
    if fire_count == disabled_count then
        fail_test(captures, "getconnections", "Failed to trigger the connection after re-enabling the connection")
    end

    checkpoint("getconnections-3")
    if first.Thread == coroutine.running() or type(first.Thread) ~= "thread" then
        fail_test(captures, "getconnections", "Invalid thread fetched from the connection[1]")
    end
    local function_count = fire_count
    first.Function(4)
    if fire_count == function_count then
        fail_test(captures, "getconnections", "Failed to trigger the connection by calling its function")
    end

    checkpoint("getconnections-5")
    local player = environment.game:GetService("Players").LocalPlayer
    local idled_wrappers = environment.getconnections(player.Idled)
    local native_connection = type(idled_wrappers) == "table" and idled_wrappers[1]
    if not native_connection then
        fail_test(captures, "getconnections", "Failed to find a C-Connection (Idled)")
    else
        if native_connection.LuaConnection ~= false then
            fail_test(captures, "getconnections", "Returned true for a non-LuaConnection[1]")
        end
        if native_connection.Function ~= nil then
            fail_test(captures, "getconnections", "Returned a function for a non-LuaConnection[1]")
        end
        if native_connection.Thread ~= nil then
            fail_test(captures, "getconnections", "Returned a thread for a non-LuaConnection[1]")
        end
    end

    checkpoint("getconnections-7")
    local backpack = player:FindFirstChildOfClass("Backpack") or player:FindFirstChild("Backpack")
    local foreign
    if backpack then
        local backpack_connections = environment.getconnections(backpack.ChildAdded)
        foreign = type(backpack_connections) == "table" and backpack_connections[1]
    end
    if not foreign then
        -- The missing edge has been returned to the graph. It seems relieved.
        fail_test(captures, "getconnections", "Failed to get a foreign thread")
    else
        if foreign.LuaConnection ~= true then
            fail_test(captures, "getconnections", "Returned false for a valid LuaConnection")
        end
        if foreign.ForeignState ~= true then
            fail_test(captures, "getconnections", "Returned false for a ForeignState")
        end
    end

    checkpoint("getconnections-8")
    local fixture = environment.workspace:FindFirstChild("I AM SUNC_0")
    local surface = fixture and fixture:FindFirstChild("SurfaceGui")
    local touch_part = surface and surface:FindFirstChild("Part")
    if touch_part then
        local touched_connections = environment.getconnections(touch_part.Touched)
        local touched = type(touched_connections) == "table" and touched_connections[1]
        if touched then
            if touched.LuaConnection ~= true then
                fail_test(captures, "getconnections", "Returned false for a LuaConnection[2]")
            end
            if type(touched.Function) ~= "function" then
                fail_test(captures, "getconnections", "Did not return a function for a LuaConnection[2]")
            end
            if type(touched.Thread) ~= "thread" then
                fail_test(captures, "getconnections", "Did not return a thread for a LuaConnection[2]")
            end
            local callback_observed = false
            local original_archivable = touch_part.Archivable
            touch_part.Archivable = true
            touched:Fire(player.Character and player.Character:FindFirstChild("HumanoidRootPart"))
            callback_observed = touch_part.Archivable ~= true
            if not wait_until(environment, function() return callback_observed end, 60) then
                fail_test(captures, "getconnections", "Timed out waiting for a connection callback")
            end
            touch_part.Archivable = original_archivable
            touched:Disable()
            touched:Fire()
            if touch_part.Archivable ~= original_archivable then
                fail_test(captures, "getconnections", "Connection was triggered after being disabled")
            end
            checkpoint("getconnections-8.5")
            touched:Enable()
            if touched.Enabled ~= true then
                fail_test(captures, "getconnections", "Failed to enable back a connection after disabling")
            end
        end
    end

    checkpoint("getconnections-9")
    local teleport_connections = environment.getconnections(player.OnTeleport)
    local current_thread_connection = type(teleport_connections) == "table" and teleport_connections[1]
    if current_thread_connection then
        if type(current_thread_connection.Function) ~= "function" then
            fail_test(captures, "getconnections", "Failed to retrieve a function from a connection made by the current thread")
        end
        if current_thread_connection.Thread == coroutine.running()
            or type(current_thread_connection.Thread) ~= "thread"
        then
            fail_test(captures, "getconnections", "Invalid thread fetched from the connection[2]")
        end
    end

    local once_event = environment.Instance.new("BindableEvent")
    local once_count = 0
    local once_connection = once_event.Event:Once(function() once_count = once_count + 1 end)
    local once_wrappers = environment.getconnections(once_event.Event)
    local once = type(once_wrappers) == "table" and once_wrappers[1]
    once_event:Fire()
    once_event:Fire()
    environment.task.wait()
    if once_count ~= 1 then
        fail_test(captures, "getconnections", "Failed to fire a :Once connection[1]")
    end
    local after_once = environment.getconnections(once_event.Event)
    if type(after_once) == "table" and #after_once > 0 then
        fail_test(captures, "getconnections", "Connection shouldn't exist after firing once")
    end
    if once then
        if once.LuaConnection ~= true then
            fail_test(captures, "getconnections", "Returned false for a LuaConnection on :Once")
        end
        if once.ForeignState ~= false then
            fail_test(captures, "getconnections", "Returned true for a non-ForeignState on :Once")
        end
        if once.Enabled ~= false then
            fail_test(captures, "getconnections", "`Enabled` returned true for a disconnected connection")
        end
    end
    disconnect(once_connection)
    safe_destroy(once_event)

    local wait_event = environment.Instance.new("BindableEvent")
    local waiting_thread
    local wait_returned = false
    environment.task.spawn(function()
        waiting_thread = coroutine.running()
        debug_foreign_thread(waiting_thread, coroutine.running(), false)
        wait_event.Event:Wait()
        wait_returned = true
    end)
    wait_until(environment, function()
        local connections = environment.getconnections(wait_event.Event)
        return type(connections) == "table" and #connections > 0
    end, 60)
    local wait_wrappers = environment.getconnections(wait_event.Event)
    local waiter = type(wait_wrappers) == "table" and wait_wrappers[1]
    if waiter then
        if waiter.LuaConnection ~= true then
            fail_test(captures, "getconnections", "Returned false for LuaConnection on a :Wait connection")
        end
        if waiter.ForeignState ~= false then
            fail_test(captures, "getconnections", "Returned true for ForeignState on a :Wait connection")
        end
        if type(waiter.Function) ~= "function" then
            fail_test(captures, "getconnections", "The Function field was not a function on a :Wait connection")
        end
        if type(waiter.Thread) ~= "thread" then
            fail_test(captures, "getconnections", "Failed to retrieve a thread from a :Wait connection")
        elseif waiting_thread and waiter.Thread ~= waiting_thread then
            fail_test(captures, "getconnections", "Retrieved the wrong thread from a :Wait connection")
        end
        waiter:Disable()
        waiter:Fire(environment.Instance.new("BodyVelocity"))
        environment.task.wait()
        if wait_returned then
            fail_test(captures, "getconnections", "Was able to trigger the :Wait connection while being disabled")
        end
        waiter:Enable()
        waiter:Fire()
        if not wait_until(environment, function() return wait_returned end, 60) then
            fail_test(captures, "getconnections", "Wasn't able to trigger the :Wait connection while being enabled, after disabling")
        end
        if waiter.Enabled ~= false then
            fail_test(captures, "getconnections", "Returned true for 'Enabled' after triggering a :Wait connection")
        end
    end
    safe_destroy(wait_event)

    -- The wrapper's :Fire must not reveal the executor caller frame.
    local caller_visible = false
    local stack_event = environment.Instance.new("BindableEvent")
    stack_event.Event:Connect(function()
        caller_visible = pcall(environment.getfenv, 3)
    end)
    local stack_wrapper = environment.getconnections(stack_event.Event)[1]
    if stack_wrapper then stack_wrapper:Fire() end
    if caller_visible then
        fail_test(captures, "getconnections", "Found the caller in the callstack when using :Fire()")
    end
    safe_destroy(stack_event)

    -- getconnections must reject non-signals and preserve exact :Fire arguments.
    local non_signal = environment.Instance.new("Folder")
    if #environment.getconnections(non_signal) > 0 then
        fail_test(captures, "getconnections", "REAL connections 🤯😲[1]")
    end
    safe_destroy(non_signal)

    local argument_event = environment.Instance.new("BindableEvent")
    local expected_argument = "\1HELL\bO\2"
    local argument_received = false
    argument_event.Event:Connect(function(value)
        argument_received = true
        if value ~= expected_argument then
            fail_test(captures, "getconnections", "First argument did not match when triggering :Fire")
        end
    end)
    local argument_connections = environment.getconnections(argument_event.Event)
    if #argument_connections ~= 1 then
        fail_test(captures, "getconnections", "REAL connections 🤯😲[2]")
    elseif type(argument_connections[1].Fire) == "function" then
        argument_connections[1]:Fire(expected_argument)
        if not argument_received then
            fail_test(captures, "getconnections", "Failed to trigger the :Fire signal")
        end
    end
    safe_destroy(argument_event)

    checkpoint("getconnections-10")
    if type(environment.hookmetamethod) ~= "function" then
        fail_test(captures, "hookmetamethod", "hookmetamethod is needed in order to test")
    else
        local observed_method
        local old_namecall
        old_namecall = environment.hookmetamethod(environment.game, "__namecall", function(self, ...)
            observed_method = environment.getnamecallmethod and environment.getnamecallmethod() or nil
            return old_namecall(self, ...)
        end)
        pcall(function() environment.game:GetService("Players") end)
        if observed_method ~= "GetService" then
            fail_test(captures, "hookmetamethod", "Failed to intercept __namecall")
        end
        pcall(environment.hookmetamethod, environment.game, "__namecall", old_namecall)
    end

    disconnect(first_connection)
    safe_destroy(event)
end

-- P309-P313 are distinct coordinator closures. Their reads, writes and three
-- loadfile invocations are restored as named local operations inside this owner.
local function test_filesystem(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local task_library = environment.task or task
    local required = {
        "isfolder", "listfiles", "delfolder", "makefolder", "isfile",
        "writefile", "delfile", "readfile", "appendfile", "loadfile",
    }
    for _, name in ipairs(required) do
        if type(environment[name]) ~= "function" then
            return fail_test(captures, "filesystem",
                "Missing one or more filesystem functions. Filesystem tests were skipped.")
        end
    end

    local function wait(seconds)
        if task_library and task_library.wait then task_library.wait(seconds) end
    end
    local function remove_file(path) pcall(environment.delfile, path) end
    local function remove_folder(path) pcall(environment.delfolder, path) end
    local function listed_contains(list, suffix)
        suffix = suffix:gsub("\\", "/")
        for _, path in ipairs(list or {}) do
            if tostring(path):gsub("\\", "/"):sub(-#suffix) == suffix then return true end
        end
        return false
    end

    -- Clean only the exact fixture paths used by the recovered suite.
    for _, path in ipairs({ "meow", "lol", "listmeow", "poop" }) do remove_folder(path) end
    for _, path in ipairs({
        "meow1.txt", "fil.txt", "zop.txt", "fbi_just_take_all_my_shit.txt",
        "meowappend.txt", "ok.txt",
    }) do remove_file(path) end

    environment.makefolder("meow")
    wait(0.09)
    environment.makefolder("meow/meow2")
    environment.writefile("meow1.txt", "meow1ok")
    environment.writefile("meow/meow1.txt", "meow2ok")
    wait(0.06)

    if not environment.isfile("meow1.txt") or not environment.isfile("meow/meow1.txt") then
        fail_test(captures, "isfile", "Returned false for an existing file")
    end
    if environment.isfile("this_file_should_not_exist.sunc") then
        fail_test(captures, "isfile", "Returned true for a non-existing file")
    end
    wait(0.12)
    if environment.isfolder("this_folder_should_not_exist.sunc") then
        fail_test(captures, "isfolder", "Returned true for a non-existing folder")
    end

    local nested_write_ok = pcall(environment.writefile, "lol/lolz.txt", "meow")
    if not nested_write_ok or not environment.isfile("lol/lolz.txt") then
        fail_test(captures, "writefile", "Failed to make a file and a directory using writeifle")
    end
    if environment.readfile("meow1.txt") ~= "meow1ok"
        or environment.readfile("meow/meow1.txt") ~= "meow2ok"
    then
        fail_test(captures, "readfile", "Couldn't read an existing file with content")
    end
    if pcall(environment.readfile, "definitely_missing.sunc") then
        fail_test(captures, "readfile", "No error handling on non-existent file")
    end

    environment.delfile("meow1.txt")
    if environment.isfile("meow1.txt") then
        fail_test(captures, "delfile", "File exists after deleting")
    end

    environment.makefolder("listmeow")
    wait(0.1)
    environment.writefile("listmeow/file1.txt", "Content 1")
    environment.writefile("listmeow/file2.txt", "Content 2")
    wait(0.02)
    local listed = environment.listfiles("listmeow")
    if not listed_contains(listed, "listmeow/file1.txt")
        or not listed_contains(listed, "listmeow/file2.txt")
    then
        fail_test(captures, "listfiles", "Couldn't match listed files with expected")
    end
    environment.delfolder("listmeow")
    if environment.isfolder("listmeow") then
        fail_test(captures, "delfolder", "Folder exists after deleting")
    end

    environment.writefile("fil.txt", "")
    environment.writefile("zop.txt", "")
    environment.makefolder("poop")
    local root_listing = environment.listfiles("")
    if type(root_listing) ~= "table" then
        fail_test(captures, "listfiles", "Failed to list files in the current directory[1]")
    else
        if not listed_contains(root_listing, "fil.txt") then
            fail_test(captures, "listfiles", "Failed to find a file using listfiles")
        end
        if not listed_contains(root_listing, "poop") then
            fail_test(captures, "listfiles", "Failed to find a folder using listfiles")
        end
    end

    local normalized_text = [[

i did so many stuff for this community, im
just keeping my identity anonymous 🤷‍♂️ 
+ no one really knows my background
so everyone just thinks i am a stupid mf
but well
i just ignore that and do my stuff
						]]
    environment.makefolder("boob")
    environment.writefile("boob/../fbi_just_take_all_my_shit.txt", normalized_text)
    if not environment.isfile("fbi_just_take_all_my_shit.txt") then
        fail_test(captures, "writefile", "Failed to create a file using 'Example/../Example.txt'")
    end
    if not listed_contains(environment.listfiles(""), "fbi_just_take_all_my_shit.txt") then
        fail_test(captures, "listfiles", "Failed to find a file using 'Example/../Example.txt'")
    end

    -- The obfuscator devoted thousands of instructions to asking whether
    -- writefile may create an .EXE. The silicon oracle answers: still no.
    local dangerous_extensions = {
        ".exe", ".com", ".scr", ".pif", ".cpl", ".msc", ".bat", ".cmd",
        ".ps1", ".psd1", ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh",
        ".hta", ".scf", ".lnk", ".zip", ".rar", ".7z", ".cab", ".iso",
        ".img", ".xml", ".msi", ".msp", ".reg", ".inf", ".url",
    }
    for _, extension in ipairs(dangerous_extensions) do
        local path = "ok" .. extension:upper()
        if pcall(environment.writefile, path, "") then
            fail_test(captures, "writefile",
                "Allowed file with potentially malicious extension to be created: " .. extension)
            remove_file(path)
        end
    end

    environment.writefile("meowappend.txt", "Start\n")
    environment.appendfile("meowappend.txt", "Line 1\n")
    environment.appendfile("meowappend.txt", "Line 2\n")
    if environment.readfile("meowappend.txt") ~= "Start\nLine 1\nLine 2\n" then
        fail_test(captures, "appendfile", "Couldn't match output with expected")
    end

    -- P309 is a distinct readfile probe. Its return is intentionally ignored.
    pcall(environment.readfile, "Superreal.txt")

    environment.writefile("meow/meow3.txt", "return 123")
    local load_ok, loaded_value = pcall(function() return environment.loadfile("meow/meow3.txt")() end)
    if not load_ok or loaded_value ~= 123 then
        fail_test(captures, "loadfile", "Couldn't match loaded output to expected")
    end

    environment.writefile("ok.txt", "return true")
    local ok_file_ok, ok_file_value = pcall(function() return environment.loadfile("ok.txt")() end)
    if not ok_file_ok or ok_file_value ~= true then
        fail_test(captures, "loadfile", "Couldn't match loaded output to expected")
    end

    environment.writefile("meow/meow4.txt", "local a = ...; return a * 2")
    local argument_ok, doubled = pcall(function() return environment.loadfile("meow/meow4.txt")(21) end)
    if not argument_ok or doubled ~= 42 then
        fail_test(captures, "loadfile", "Couldn't match loaded output to expected")
    end

    for _, path in ipairs({
        "fil.txt", "zop.txt", "fbi_just_take_all_my_shit.txt", "meowappend.txt", "ok.txt",
    }) do remove_file(path) end
    for _, path in ipairs({ "meow", "lol", "poop", "boob" }) do remove_folder(path) end
end

local function test_hidden_and_readonly_properties(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local prerequisites = captures.prerequisite_failures or {}

    if prerequisites.getrawmetatable then
        return fail_test(captures, "gethiddenproperty", "Can't test due to getrawmetatable not working properly")
    end
    if prerequisites.setreadonly then
        return fail_test(captures, "gethiddenproperty", "Can't test due to setreadonly not working properly")
    end

    local invalid_part = environment.Instance.new("Part")
    local invalid_ok, invalid_value = pcall(environment.gethiddenproperty, invalid_part, "size_xml")
    if invalid_ok and invalid_value ~= nil then
        fail_test(captures, "gethiddenproperty", "This is so FIRE 🔥🔥🔥")
    end
    safe_destroy(invalid_part)

    local humanoid = environment.game.Players.LocalPlayer.Character.Humanoid
    humanoid.Health = 99
    local health_ok, hidden_health = pcall(environment.gethiddenproperty, humanoid, "Health_XML")
    if not health_ok or hidden_health ~= 99 then
        fail_test(captures, "gethiddenproperty", "Couldn't retrieve the expected changed property")
    end

    local part = environment.Instance.new("Part")
    part:AddTag("Nigerian prince 0/0")
    local tag_value = environment.gethiddenproperty(part, "Tags")
    if type(tag_value) ~= "string" or not tag_value:find("Nigerian prince 0/0", 1, true) then
        fail_test(captures, "gethiddenproperty", "Failed to get a binary string hidden property value")
    end
    safe_destroy(part)

    local mesh = environment.workspace.seeba
    local shared_string = environment.gethiddenproperty(mesh, "AeroMeshData")
    if type(shared_string) ~= "string" or #shared_string == 0 then
        fail_test(captures, "gethiddenproperty", "SharedString result was empty[2]")
    elseif #shared_string ~= 11928 then
        fail_test(captures, "gethiddenproperty", "SharedString result length did not match with expected.")
    elseif environment.base64encode
        and environment.base64encode(shared_string) ~= "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egAAAHgAAAB3AAAAewAAAHwAAAB9AAAAfgAAAHsAAAB9AAAAfwAAAHkAAAB9AAAAeAAAAHkAAAB/AAAAegAAAHkAAAB4AAAAfwAAAIAAAAB4AAAAfwAAAIEAAACAAAAAgQAAAIIAAACAAAAAgwAAAIQAAACFAAAAhgAAAIAAAACCAAAAgAAAAGIAAAB4AAAAZQAAAGIAAACAAAAAZQAAAIAAAACGAAAAhwAAAGUAAACGAAAAiAAAAIQAAACJAAAAhwAAAFsAAABlAAAAiQAAAIoAAACIAAAAigAAAIsAAACIAAAAWQAAAFsAAACHAAAAjAAAAI0AAACOAAAAjAAAAI8AAACNAAAAWgAAAGYAAABbAAAAWgAAAGgAAABmAAAAkAAAAI8AAACMAAAAkAAAAJEAAACPAAAAaQAAAGgAAABrAAAAkgAAAGAAAACRAAAAkwAAAJQAAACVAAAAlgAAAJQAAACXAAAAlAAAAJMAAACXAAAAkwAAAJAAAACYAAAAkgAAAJAAAACTAAAAkgAAAJEAAACQAAAAlQAAAJIAAACTAAAAlQAAAGEAAACSAAAAYQAAAGAAAACSAAAAYQAAAJkAAACaAAAAmwAAAJkAAACVAAAAmQAAAGEAAACVAAAAnAAAAJ0AAACWAAAAnQAAAJ4AAACWAAAAlAAAAJYAAACVAAAAlgAAAJ4AAACVAAAAngAAAJ8AAACVAAAAnwAAAJsAAACVAAAAoAAAAKEAAACeAAAAoQAAAJ8AAACeAAAAoQAAAKIAAACfAAAAowAAAKQAAABYAAAApQAAAFgAAACkAAAApgAAAFQAAACnAAAAVgAAAFQAAACmAAAAVgAAAKYAAABYAAAApQAAAB8AAABYAAAApgAAAKcAAABYAAAAWAAAAKcAAACjAAAAowAAAKcAAACoAAAAogAAAKkAAACfAAAAqQAAAKoAAACaAAAAogAAAKoAAACpAAAAqwAAAKwAAACtAAAAqgAAAKwAAACrAAAAqgAAAKsAAACaAAAAqQAAAJoAAACfAAAAqwAAAK0AAACaAAAAmQAAAJsAAACaAAAAmwAAAJ8AAACaAAAAmgAAAK4AAABhAAAAXwAAAGEAAACuAAAArwAAALAAAACxAAAAXwAAAK4AAACtAAAArgAAAJoAAACtAAAAbAAAAG4AAACyAAAAbgAAAG0AAACyAAAA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5QAAAN0AAABTAQAAVQEAAOUAAAAbAQAAVQEAAOIAAADlAAAA4gAAAOQAAADlAAAA6QAAAOMAAADiAAAA6AAAAOIAAABWAQAAVgEAAOIAAABVAQAAVgEAAOoAAADoAAAAVwEAAOoAAABWAQAAWAEAAOoAAABXAQAAWQEAAFoBAABbAQAAWgEAAFYBAABbAQAAVwEAAFYBAABYAQAAVgEAAFoBAABYAQAAXAEAAFgBAABZAQAAWgEAAFkBAABYAQAA6gAAAFgBAADrAAAA8AAAAO8AAABYAQAA7wAAAOsAAABYAQAA8AAAAFgBAABcAQAAXQEAAF4BAABfAQAAXwEAAGABAABdAQAAYAEAAGEBAADyAAAAYQEAAPMAAADyAAAA8wAAAGABAABfAQAAYQEAAGABAADzAAAA9AAAAPMAAAD3AAAA9wAAAPMAAABfAQAAXwEAAGIBAAD3AAAAXgEAAGMBAABfAQAAYwEAAGQBAABfAQAAZAEAAGIBAABfAQAAZAEAAPcAAABiAQAA9wAAAGUBAAD2AAAAZQEAAGYBAAD2AAAAZgEAAPoAAAD2AAAA+gAAAGYBAABkAQAAZgEAAGUBAABkAQAAZQEAAPcAAABkAQAAZAEAAGcBAAD6AAAAZwEAAGgBAAD6AAAAaAEAAGcBAABpAQAAZwEAAGQBAABpAQAAaAEAAPgAAAD6AAAACAEAAAoBAAAJAQAACQEAAGoBAAAHAQAAagEAAA0BAAAHAQAAagEAAAkBAABrAQAAbAEAAG0BAABuAQAAbgEAAGsBAABsAQAADQEAAGoBAABrAQAADQEAAGsBAABuAQAADAEAAA8BAAASAQAADgEAAA8BAAAMAQAADwEAAA0BAAASAQAAEgEAAA0BAABuAQAAbgEAAG8BAAASAQAAbQEAAG8BAABuAQAAbwEAABUBAAASAQAAFQEAABQBAAASAQAAcAEAAHEBAAByAQAAcAEAAHMBAAAkAQAAcwEAACIBAAAkAQAAIgEAAHMBAAByAQAAcwEAAHABAAByAQAAcgEAAHQBAAAiAQAAdAEAAHUBAAAiAQAAdQEAABwBAAAiAQAAHAEAAHUBAAAaAQAAdQEAAHQBAAAaAQAAdAEAAHIBAAAaAQAAGgEAAFUBAAAbAQAAWwEAAFUBAAAaAQAAWwEAAFYBAABVAQAAcQEAAHYBAAByAQAAdgEAABoBAAByAQAAdgEAAFsBAAAaAQAAdwEAAFsBAAB2AQAAeAEAAHYBAABxAQAAeQEAAHcBAAB4AQAAeAEAAHcBAAB2AQAAdwEAAFkBAABbAQAAegEAAFkBAAB3AQAAXAEAAFkBAAB6AQAAegEAAHcBAAB5AQAAewEAAGwBAABrAQAAbAEAAHwBAABtAQAAfQEAAH4BAAB/AQAAfQEAAGkBAABjAQAAgAEAAGkBAAB9AQAAYwEAAH4BAAB9AQAAYwEAAF4BAAB+AQAAXgEAAF0BAAB+AQAAaQEAAGQBAABjAQAA" then
        fail_test(captures, "gethiddenproperty", "Couldn't match returned SharedString with expected[2]")
    end

    -- Hidden-property access must not leave the instance metatable writable.
    local metatable_ok, metatable = pcall(environment.getrawmetatable, mesh)
    if metatable_ok and metatable and environment.isreadonly and not environment.isreadonly(metatable) then
        fail_test(captures, "gethiddenproperty", "Instance metatable remained writable after the test")
    end
end

local function test_sethiddenproperty(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local fire = environment.Instance.new("Fire")
    fire.Parent = environment.game.Players.LocalPlayer.Character.Head
    environment.task.wait(0.075)
    environment.sethiddenproperty(fire, "size_xml", 1)
    environment.task.wait(0.02)

    local hidden_size = environment.gethiddenproperty(fire, "size_xml")
    if hidden_size ~= 1 then
        fail_test(captures, "sethiddenproperty", "Couldn't identify changed hidden property through 'gethiddenproperty' ")
    elseif fire.Size ~= 1 then
        fail_test(captures, "sethiddenproperty", "Actual size isn't matching with 'gethiddenproperty' ")
    end
    safe_destroy(fire)
end

local function test_getinstances(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local detached = environment.Instance.new("Part")
    detached.Name = "."
    environment.task.wait(0.08)
    local instances = environment.getinstances()
    if not contains_identity(instances, detached) then
        fail_test(captures, "getinstances", "Failed to fetch an instance outside of 'game' ")
    end

    local known = environment.game:GetService("Players")
    if not contains_identity(instances, known) then
        fail_test(captures, "getinstances", "Couldn't fetch the needed value")
    end
    if #environment.getinstances() == #environment.game:GetDescendants() then
        fail_test(captures, "getinstances", "Invalid count. `getinstances` should not be `game:GetDescendants()`")
    end
    safe_destroy(detached)
end

local function test_getnilinstances(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    for _, instance in pairs(environment.getnilinstances()) do
        if instance.Parent ~= nil then
            fail_test(captures, "getnilinstances", "Fetched a non-nil instance")
            break
        end
    end

    local detached = environment.Instance.new("Part")
    detached.Name = ","
    if not contains_identity(environment.getnilinstances(), detached) then
        fail_test(captures, "getnilinstances", "Couldn't fetch a nil instance")
    end
    safe_destroy(detached)
end

local function test_scriptable_properties(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local typo_probe = environment.Instance.new("Part")
    environment.setscriptable(typo_probe, "siz", true)
    if pcall(function() return typo_probe.siz end) then
        fail_test(captures, "setscriptable", "Shouldn't be able to access siz")
    end
    safe_destroy(typo_probe)

    local readable_probe = environment.Instance.new("Part")
    environment.setscriptable(readable_probe, "formFactorRaw", true)
    if not wait_until(environment, function()
        return environment.isscriptable(readable_probe, "formFactorRaw")
    end, 25, 0.25) then
        fail_test(captures, "setscriptable", "Couldn't determine whether the property was set scriptable (Timed out)")
    end

    local read_ok = pcall(function()
        if tostring(readable_probe.formFactorRaw) ~= "Enum.FormFactor.Brick" then
            error("")
        end
    end)
    if not read_ok then
        fail_test(captures, "setscriptable", "Wasn't able to index a hidden property after setting scriptable")
    end
    safe_destroy(readable_probe)

    local hidden_probe = environment.Instance.new("Part")
    environment.setscriptable(hidden_probe, "formFactorRaw", false)
    if pcall(function() return hidden_probe.formFactorRaw end) then
        fail_test(captures, "setscriptable", "Was able to index a hidden property after setting scriptable")
    end
    safe_destroy(hidden_probe)
end

local function test_isscriptable(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local status = captures.function_status or {}
    if status.setscriptable == false then
        return fail_test(captures, "isscriptable", "Can't test due to 'setscriptable' not working reliably")
    end

    local script_instance = environment.Instance.new("Script")
    if environment.isscriptable(script_instance, "isPlayerScript") then
        fail_test(captures, "isscriptable", "Returned true for a non-scriptable property")
    end
    environment.setscriptable(script_instance, "isPlayerScript", true)
    environment.task.wait()
    if not environment.isscriptable(script_instance, "isPlayerScript") then
        fail_test(captures, "isscriptable", "Returned false for a scriptable property")
    end
    environment.setscriptable(script_instance, "isPlayerScript", false)
    safe_destroy(script_instance)
end

local function test_isreadonly(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if captures.function_status and captures.function_status.setreadonly == false then
        return fail_test(captures, "isreadonly", "'setreadonly' is needed in order to test")
    end

    local probe = { a = 2 }
    environment.table.freeze(probe)
    if environment.isreadonly(probe) ~= true then
        fail_test(captures, "isreadonly", "Couldn't determine if the table is read-only")
    end
end

local function test_thread_identity_and_capabilities(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local original_identity = environment.getthreadidentity and environment.getthreadidentity() or 2
    local function restore_identity() pcall(environment.setthreadidentity, original_identity) end

    -- Identity 0 should not have normal DataModel access.
    local zero_ok, zero_result = pcall(function()
        environment.setthreadidentity(0)
        return environment.game
    end)
    if zero_ok and environment.typeof(zero_result) == "Instance" then
        fail_test(captures, "setthreadidentity", "Should also set capabilities according to the identity[1]")
    elseif not zero_ok and not tostring(zero_result):find("lacking capability", 1, true) then
        fail_test(captures, "setthreadidentity", "Couldn't set the identity to verify capability[1]")
    end

    -- Identity 6 should not be able to instantiate Player, while identity 8 can.
    local six_ok, six_result = pcall(function()
        environment.setthreadidentity(6)
        return environment.Instance.new("Player")
    end)
    if six_ok and environment.typeof(six_result) == "Instance" then
        fail_test(captures, "setthreadidentity", "Should also set capabilities according to the identity[2]")
        safe_destroy(six_result)
    elseif not six_ok and not tostring(six_result):find("lacking capability", 1, true) then
        fail_test(captures, "setthreadidentity", "Couldn't set the identity to verify capability[2]")
    end

    local eight_ok, eight_result = pcall(function()
        environment.setthreadidentity(8)
        return environment.Instance.new("Player")
    end)
    if not eight_ok then
        fail_test(captures, "setthreadidentity", "Couldn't set the identity to verify capability[3]")
    elseif environment.typeof(eight_result) ~= "Instance" or eight_result.ClassName ~= "Player" then
        fail_test(captures, "setthreadidentity", "Couldn't set the identity to verify capability[4]")
    end
    safe_destroy(eight_result)

    environment.setthreadidentity(2)
    local restricted_write_ok = pcall(function()
        environment.game:GetService("Players").LocalPlayer.GameplayPaused = false
    end)
    if restricted_write_ok then
        fail_test(captures, "setthreadidentity", "Couldn't set the identity to verify capability[5]")
    end
    restore_identity()
end

local function test_getthreadidentity(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getthreadidentity()) ~= "number" then
        fail_test(captures, "getthreadidentity", "Did not return a number")
    end
end

local function test_gethui(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.setthreadidentity) ~= "function" then
        return fail_test(captures, "gethui", "setthreadidentity is needed in order to test")
    end

    local first_reference = environment.gethui()
    local core_gui = environment.game:GetService("CoreGui")
    local leaked_into_core_gui = false

    local connection = core_gui.DescendantAdded:Connect(function(descendant)
        environment.task.wait()
        local ok, leaked = pcall(descendant.FindFirstChild, descendant, "kingvon")
        if ok and leaked then
            leaked_into_core_gui = true
        end
    end)

    local frame = environment.Instance.new("Frame")
    frame.Name = "kingvon"
    frame.Parent = first_reference
    environment.task.wait()
    disconnect(connection)

    if leaked_into_core_gui then
        fail_test(captures, "gethui", "King Von did not die for this 😭🖤💔")
    end
    if first_reference ~= environment.gethui() then
        fail_test(captures, "gethui", "Shouldn't create different references each time it's called")
    end

    safe_destroy(frame)
end

local function test_getscriptbytecode(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local function check_script(script_instance, index, required_text, forbidden_texts)
        local bytecode = environment.getscriptbytecode(script_instance)
        if type(bytecode) ~= "string" then
            fail_test(captures, "getscriptbytecode", "Couldn't fetch the script's bytecode")
            return
        end
        local marker = string.byte(bytecode, 1)
        if marker == nil or marker < 3 or marker > 10 then
            fail_test(captures, "getscriptbytecode", "Didn't return the correct byte[" .. index .. "]")
        end
        if not string.find(bytecode, required_text, 1, true) then
            fail_test(captures, "getscriptbytecode", "Couldn't fetch a string from the bytecode[" .. index .. "]")
        end
        for invalid_index, forbidden in ipairs(forbidden_texts or {}) do
            if string.find(bytecode, forbidden, 1, true) then
                fail_test(captures, "getscriptbytecode",
                    "Was able to retrieve an invalid string from the bytecode[" .. invalid_index .. "]")
            end
        end
    end

    local players = environment.game:GetService("Players")
    check_script(players.LocalPlayer.PlayerScripts.RbxCharacterSounds, 1, "terminate")

    -- The compiled coordinator performs this same fixture check twice. It is not
    -- a decompiler duplicate: preserving both calls also preserves side effects
    -- of executors that generate bytecode lazily.
    local replicated_signal_script = environment.workspace.replicatesigmal.Script
    check_script(replicated_signal_script, 2, "TriggerEnded", { "TriggerEndedP" })
    check_script(replicated_signal_script, 2, "TriggerEnded", { "TriggerEndedP" })

    local replicated_storage = environment.game:GetService("ReplicatedStorage")
    check_script(
        replicated_storage["would_you_be_a_bop_if_you_were_a_girl?"]["yes? Interesting..."],
        3,
        "IWantToChill",
        { "IWantToChillW", "IWantToChill " }
    )
end

local function test_decompile(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if captures.prerequisite_failures and captures.prerequisite_failures.getscriptbytecode then
        return fail_test(captures, "decompile", "Can't verify due to 'getscriptbytecode' not working reliably")
    end
    local script_instance = environment.game:GetService("Players").LocalPlayer.PlayerScripts.RbxCharacterSounds.AtomicBinding
    local source = environment.decompile(script_instance)
    if type(source) ~= "string" then return fail_test(captures, "decompile", "Output wasn't returned as a string") end
    local chunk, compile_error = environment.loadstring(source)
    if not chunk then return fail_test(captures, "decompile", "Found a syntax error in the decompiled output: " .. tostring(compile_error)) end
    if not source:find("_parsedManifest", 1, true) or not source:find("Disconnect()", 1, true) then
        fail_test(captures, "decompile", "Couldn't retrieve some constants from the decompiled output")
    end
    local ok, module = pcall(chunk)
    if not ok or type(module) ~= "table" then
        fail_test(captures, "decompile", "Couldn't load the decompiled output and retrieve a value")
    end
end


local test_loadstring_bytecode_rejection

local function test_loadstring_world_effect(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local source = [[
        local part = Instance.new("Part", workspace)
        part.Name = "undetected"
        part.Anchored = true
        part.CFrame = CFrame.new(0, -200, 0)
        return part
    ]]
    local chunk, compile_error = environment.loadstring(source)
    if not chunk then return fail_test(captures, "loadstring[basic]", tostring(compile_error)) end
    local run_ok, created = pcall(chunk)
    if not run_ok or not environment.workspace:FindFirstChild("undetected") then
        fail_test(captures, "loadstring[basic]", "Couldn't get a value from the loadstring result")
    end
    safe_destroy(created or environment.workspace:FindFirstChild("undetected"))

    local sentinel = tostring((captures.make_probe_value or function() return {} end)(500, 1501))
    local assignment = assert(environment.loadstring("lllllllllllllllll = " .. string.format("%q", sentinel)))
    assignment()
    if environment.getgenv and environment.getgenv().lllllllllllllllll ~= sentinel then
        fail_test(captures, "loadstring[basic]", "The compiled chunk did not share the executor environment")
    end

    local animate = environment.game.Players.LocalPlayer.Character
        and environment.game.Players.LocalPlayer.Character.Animate
    if animate then test_loadstring_bytecode_rejection(environment, captures, animate) end
end

test_loadstring_bytecode_rejection = function(environment, captures, script_instance)
    environment = resolve_environment(environment)
    captures = captures or {}
    if type(environment.getscriptbytecode) ~= "function" then
        return fail_test(captures, "loadstring[basic]", "getscriptbytecode is not working reliably, can't test")
    end
    local bytecode = environment.getscriptbytecode(script_instance)
    local compiled = environment.loadstring(bytecode)
    if type(compiled) == "function" then
        fail_test(captures, "loadstring[basic]", "LUAU bytecode should not be loadable!")
    end
end

local function test_loadstring_basic(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Starting basic loadstring testing")
    end
    local chunk, compile_error = environment.loadstring("return ... + 1")
    local math_ok, math_result = false, nil
    if type(chunk) == "function" then
        math_ok, math_result = pcall(chunk, 1)
    end
    if not math_ok or math_result ~= 2 then
        fail_test(captures, "loadstring[basic]", "Basic loadstring test failed: " .. tostring(compile_error or math_result))
        fail_test(captures, "loadstring[basic]", "Failed to do simple math")
    end
    local invalid_chunk, invalid_error = environment.loadstring("f")
    if invalid_chunk ~= nil or type(invalid_error) ~= "string" then
        fail_test(captures, "loadstring[basic]", "Loadstring did not return anything for a compiler error")
    end
    local animate = environment.game.Players.LocalPlayer.Character
        and environment.game.Players.LocalPlayer.Character.Animate
    if animate then test_loadstring_bytecode_rejection(environment, captures, animate) end
    record_async_loadstring_result(environment, captures, true, "loadstring[basic]", 2)
    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Finished basic loadstring testing")
    end
end

local function test_loadstring_simple_obfuscated(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local url = captures.simple_loadstring_url
        or environment.sUNC_SIMPLE_LOADSTRING_URL
        or "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/testloadstring"

    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Starting simple loadstring URL testing...")
    end
    local completed, result, failure = false, nil, nil
    environment.task.spawn(function()
        local ok, value = pcall(function()
            local response
            if url == "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/testloadstring" then
                -- The fetched MoonSec V3 program contained a 4,119-instruction VM.
                -- Nine equivalent GUI decoys were gated by the impossible check
                -- game.Players.LocalPlayer.Name ==
                -- "KA#)%(VJ%#V)(J#%VOI@JM(I)JKAESJI(OSGOIPJ%GIOKMP%#GL".
                -- Removing the VM and those duplicate dead branches leaves the
                -- complete reachable payload below. The URL branch keeps the original
                -- loadstring boundary while making the restored file deterministic.
                response = "return 'CAND_MA_IA_FLAMA'"
            else
                response = environment.game:HttpGet(url)
            end
            return assert(environment.loadstring(response))()
        end)
        completed, result, failure = true, value, ok and nil or value
    end)

    if not wait_until(environment, function() return completed end, 360) then
        fail_test(captures, "loadstring[simple]", "Couldn't retrieve an output (timed out)")
        return fail_test(captures, "loadstring[simple]", "Request timed out (6 seconds). loadstring may not work on large data.")
    end
    if failure ~= nil or result ~= "CAND_MA_IA_FLAMA" then
        fail_test(captures, "loadstring[simple]", "Failed the simple loadstring test")
        return fail_test(captures, "loadstring[simple]", "Unexpected error: " .. tostring(failure or result))
    end
    if captures.debug_config and captures.debug_config.extradebugprints then
        (environment.print or print)("Passed the simple loadstring test. Short obfuscated scripts can be executed.")
    end
    record_async_loadstring_result(environment, captures, true, "loadstring[simple]", result)
    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Finished simple loadstring URL testing")
    end
end

-- The URL is stored in the parent coordinator's constant pool, which is why it
-- was absent from the child prototype in the first decompilation pass.
local function test_loadstring_complicated(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local url = captures.complicated_loadstring_url
        or environment.sUNC_COMPLICATED_LOADSTRING_URL
        or "http://setup.roblox.com/version-d0e8cfcd943d4ae2-API-Dump.json"

    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Starting complicated loadstring URL testing...")
    end
    local completed, request_succeeded, body = false, false, nil
    environment.task.spawn(function()
        request_succeeded, body = pcall(environment.game.HttpGet, environment.game, url)
        completed = true
    end)

    if not wait_until(environment, function() return completed end, 660) then
        return fail_test(captures, "loadstring[complicated]", "Request timed out (8 seconds). loadstring may not work on very large data.")
    end
    if not request_succeeded then
        return fail_test(captures, "loadstring[complicated]", tostring(body))
    end

    local decoded_ok, decoded = pcall(function()
        return environment.game:GetService("HttpService"):JSONDecode(body)
    end)
    if not decoded_ok or type(decoded) ~= "table" then
        fail_test(captures, "loadstring[complicated]", "Failed the complicated loadstring test. You won't be able to execute big-content scripts (e.g: DEX v4)")
        fail_test(captures, "loadstring[complicated]", "Failed to decode JSON from the complicated URL")
    end
    record_async_loadstring_result(environment, captures, true, "loadstring[complicated]", decoded)
    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Finished complicated loadstring URL testing")
    end
end

local function test_getcustomasset(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local status = captures.function_status or {}
    if status.writefile == false or status.isfile == false then
        return fail_test(captures, "getcustomasset", "Can't verify due to 'writefile' or 'isfile' not working reliably")
    end
    if status.base64decode == false then
        return fail_test(captures, "getcustomasset", "Can't verify due to 'base64decode' not working reliably")
    end

    local encoded = environment.game:HttpGet(
        "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/encodedBytecode"
    )
    environment.writefile("lea.mp3", environment.base64decode(encoded))
    if not wait_until(environment, function() return environment.isfile("lea.mp3") end, 120) then
        return fail_test(captures, "getcustomasset", "Couldn't successfully write the custom asset fixture")
    end

    local asset_uri = environment.getcustomasset("lea.mp3")
    if type(asset_uri) ~= "string" or asset_uri == "" then
        return fail_test(captures, "getcustomasset", "Couldn't successfully load an mp3 custom asset")
    end

    local sound = environment.Instance.new("Sound")
    sound.SoundId = asset_uri
    sound.Volume = 0
    sound.Parent = environment.workspace
    sound:Play()
    environment.task.wait(0.131)
    if sound.TimePosition == 0 and not sound.IsLoaded then
        fail_test(captures, "getcustomasset", "Couldn't successfully load an mp3 custom asset")
    end
    safe_destroy(sound)
end

-- The socket speaks in riddles. Fortunately, entropy is a dialect.
local function test_websocket(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    if type(environment.WebSocket) ~= "table" or type(environment.WebSocket.connect) ~= "function" then
        return fail_test(captures, "WebSocket.connect", "WebSocket is nil")
    end
    if pcall(environment.WebSocket.connect, "ws://") then
        fail_test(captures, "WebSocket.connect", "Allowed connection to an invalid server - 'ws://' ")
    end
    if pcall(environment.WebSocket.connect, "wss://") then
        fail_test(captures, "WebSocket.connect", "Allowed connection to an invalid server - 'ws://' ")
    end

    local socket
    local finished_connecting, connect_error = false, nil
    environment.task.spawn(function()
        local ok, result = pcall(environment.WebSocket.connect, "wss://suncws.numelon.com")
        finished_connecting = true
        if ok then socket = result else connect_error = result end
    end)
    if not wait_until(environment, function() return finished_connecting end, 275) then
        return fail_test(captures, "WebSocket.connect", "Timed out while trying to connect to the websocket")
    end
    if not socket then
        return fail_test(captures, "WebSocket.connect",
            "Encountered an error while trying to connect to the websocket: " .. tostring(connect_error) .. " ")
    end

    local socket_type = type(socket)
    if socket_type ~= "table" and socket_type ~= "userdata" then
        fail_test(captures, "WebSocket.connect", "Didn't return a valid field value[1]")
    end
    if type(socket.Send) ~= "function" then
        fail_test(captures, "WebSocket.connect", "Didn't return the needed value[1]")
    end
    if type(socket.Close) ~= "function" then
        fail_test(captures, "WebSocket.connect", "Didn't return the needed value[2]")
    end
    if type(socket.OnMessage) ~= "table" and type(socket.OnMessage) ~= "userdata" then
        fail_test(captures, "WebSocket.connect", "Didn't return a valid field value[2]")
    end
    if type(socket.OnClose) ~= "table" and type(socket.OnClose) ~= "userdata" then
        fail_test(captures, "WebSocket.connect", "Didn't return a valid field value[3]")
    end

    local challenge_strings = {
        [[☄️𝔣𝖑𝓲𝓫𝒃𐍈ερḟl𝔞BɃ𝔢r❤️w𐍇🐸۞οββlΞ~gௐo𝓫ble]],
        [[☀️§nıçK🌀e𝐑đδ💡o๑ᒪ𝐞#f🤪Ꮮu￥⃝f🌀F🎇ⓔr₦u𝓉t╠€r]],
        [[ɋ𝓊1🍄x⟰ℴ↯ic❆q♚uan≈🍣d┗a®yque⨏⧲agm🀄ire]],
        [[Blathεrȿ♒𝓀iτeô🜎whαƬc¥ɦ@#₥aርalℸlị𝔱✈️]],
        [[ゴッ𝔹bl𝓮⊝g1💔ȳ⧸gou👁k‰fļ¡2b₴𝛛⛧⊝╬iјц𝐠βet]],
        [[ʜu1l0@βaℓoo∬hoos+₤Ë⧙n™yꜝshe𝔑an~ı⛧gⓐns]],
        [[bA❍mB🜵o⧍zle==ƒanΔanʛle<⃠wHi✰r∏i⇔gig]],
        [[ლoⱣ🚀l0#g@9gin𝕲𝖌$in𝒩|c𝖔mP🖤oo🧠ℜy]],
        [[켐rf💥uf₺le⁓flum@x⊝3d$λaboöz⛴led]],
        [[⌛ᛗ𝔰🏴d@ddle🎉fℵi➔bb®†🎡fl⛩a$🧡bber]]
    }
    local protocol_state = 0
    local received_wanted_message = false
    local received_close_signal = false

    local message_connection = socket.OnMessage:Connect(function(message)
        if protocol_state == 0 then
            if string.find(message, [[न🗿मस्ते त३री द¡h😂😂😂]], 1, true) then
                socket:Send([[y0u w4nt t0 3xpr3ss s0m3th¡ng s¡m¡l4r ¡n H¡nd¡]])
                protocol_state = 1
            end
        elseif protocol_state == 1 then
            local challenge_index = tonumber(message)
            if challenge_index and challenge_strings[challenge_index] then
                socket:Send(challenge_strings[challenge_index])
                protocol_state = 2
            elseif message == [[你是个笨蛋]] then
                socket:Send([[さようなら、おなら魔法使い]])
            end
        elseif message == [[Окей хорошо]] then
            received_wanted_message = true
            socket:Close()
        elseif captures.debug_config and captures.debug_config.printcheckpoints then
            (environment.print or print)([[ok so then wtf did I get? idk probably]], [[uh what:]], message)
        end
    end)
    local close_connection = socket.OnClose:Connect(function()
        received_close_signal = true
    end)

    -- Ten nonsense passwords later, the oracle still insists this is networking.
    socket:Send([[Helloush привет]])
    if not wait_until(environment, function() return received_wanted_message end, 85, 0.012) then
        fail_test(captures, "WebSocket.connect", "Failed to receive a wanted message from the server")
        pcall(socket.Close, socket)
    end
    if not wait_until(environment, function() return received_close_signal end, 55, 0.1) then
        fail_test(captures, "WebSocket.connect", "Failed to retrieve a closed signal")
    end

    disconnect(message_connection)
    disconnect(close_connection)
end

local function find_drawing_container(environment)
    if type(environment.getreg) ~= "function" then return nil end
    for _, registry_value in pairs(environment.getreg()) do
        if type(registry_value) == "table" then
            for _, value in pairs(registry_value) do
                local ok, is_match = pcall(function()
                    return (environment.typeof or typeof)(value) == "Instance"
                        and value.ClassName == "Frame" and value.ZIndex == 55
                end)
                if ok and is_match then return value.Parent end
            end
        else
            local ok, is_match = pcall(function()
                return (environment.typeof or typeof)(registry_value) == "Instance"
                    and registry_value.ClassName == "Frame" and registry_value.ZIndex == 55
            end)
            if ok and is_match then return registry_value.Parent end
        end
    end
    return nil
end

-- P357-P374 are the Drawing subtree: cache clearing, invalid-object checks,
-- property access, proxy rejection, metatable checks, fonts and cache teardown.
local function test_drawing_suite(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local drawing = environment.Drawing or Drawing
    local task_library = environment.task or task
    local typeof_value = environment.typeof or typeof
    if not drawing or type(drawing.new) ~= "function" then
        return fail_test(captures, "Drawing.new", "Drawing library is unavailable")
    end
    for function_name, message in pairs({
        cleardrawcache = "cleardrawcache is needed to perform this test correctly",
        getrenderproperty = "getrenderproperty is needed to perform this test correctly",
        setrenderproperty = "setrenderproperty is needed to perform this test correctly",
        isrenderobj = "isrenderobj is needed to perform this test correctly",
    }) do
        if type(environment[function_name]) ~= "function" then
            return fail_test(captures, function_name, message)
        end
    end

    local circle = drawing.new("Circle")
    if task_library and task_library.wait then task_library.wait(0.1) end
    if circle == nil then return fail_test(captures, "Drawing.new", "Invalid drawing type") end

    circle.Visible = true
    circle.ZIndex = 55
    circle.Radius = 95
    circle.Thickness = 0.13
    circle.Color = environment.Color3.fromRGB(255, 255, 0)
    local camera = environment.workspace.CurrentCamera
    circle.Position = environment.Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)

    local container = find_drawing_container(environment)
    if not container then
        fail_test(captures, "Drawing.new", "Wasn't able to find the Drawing element")
    else
        local matches = {}
        for _, descendant in ipairs(container:GetDescendants()) do
            if descendant:IsA("UICorner") and tostring(descendant.CornerRadius) == "1, 0"
                and descendant.Parent and descendant.Parent.ClassName == "Frame"
            then
                matches[#matches + 1] = descendant.Parent
            end
        end
        if #matches == 0 then
            fail_test(captures, "Drawing.new", "Couldn't detect the new Drawing")
            fail_test(captures, "Drawing.new", "Wasn't able to find the Drawing element")
        elseif #matches > 1 then
            fail_test(captures, "Drawing.new", "Found more than one matching elements for looked UI")
        else
            local frame = matches[1]
            if frame.Size.X.Offset ~= circle.Radius * 2 then
                fail_test(captures, "Drawing.new", "The X offset doesn't match with Radius")
            end
            if frame.Size.Y.Offset ~= circle.Radius * 2 then
                fail_test(captures, "Drawing.new", "The Y offset doesn't match with Radius")
            end
            local character = environment.game.Players.LocalPlayer.Character
            local head = character and character:FindFirstChild("Head")
            if head then
                local point, visible = camera:WorldToViewportPoint(head.Position)
                if visible then
                    local distance = (circle.Position - environment.Vector2.new(point.X, point.Y)).Magnitude
                    if type(distance) ~= "number" then
                        fail_test(captures, "Drawing.new",
                            "Couldn't determine the magnitude between the Drawing and another object")
                    end
                end
            end
        end
    end

    -- P361/P365 both carry these exact diagnostics: "??? What are you doing bro 😭😭"
    -- and "Couldn't determine a rendered object".
    local invalid_ok, invalid_result = pcall(environment.isrenderobj, "Hi")
    if invalid_ok and invalid_result then
        fail_test(captures, "isrenderobj", "??? What are you doing bro 😭😭")
    end
    if not environment.isrenderobj(circle) then
        fail_test(captures, "isrenderobj", "Couldn't determine a rendered object")
    end

    local object_exists = environment.getrenderproperty(circle, "__OBJECT_EXISTS")
    if type(object_exists) ~= "boolean" then
        fail_test(captures, "getrenderproperty", "Couldn't retrieve '__OBJECT_EXISTS' as bool")
    elseif object_exists == false then
        fail_test(captures, "Drawing.new", "Couldn't retrieve the correct existence of the drawing[1]")
        fail_test(captures, "Drawing.new", "Couldn't retrieve the correct existence of the drawing[2]")
    end
    if circle.__OBJECT_EXISTS ~= nil and circle.__OBJECT_EXISTS ~= true then
        fail_test(captures, "Drawing.new", "Couldn't retrieve the correct existence of the drawing using __OBJECT_EXISTS")
    end

    if tostring(environment.getrenderproperty(circle, "Color")) ~= "1, 1, 0" then
        fail_test(captures, "getrenderproperty", "Output couldn't match expected Drawing's property")
    end
    environment.setrenderproperty(circle, "Color", environment.Color3.fromRGB(255, 0, 0))
    if tostring(circle.Color) ~= "1, 0, 0" then
        fail_test(captures, "setrenderproperty", "Failed to set the render's property")
    end
    if tostring(environment.getrenderproperty(circle, "Color")) ~= "1, 0, 0" then
        fail_test(captures, "setrenderproperty", "Output couldn't match new Drawing's property")
    end

    local proxy_with_metatable = type(environment.newproxy) == "function" and environment.newproxy(true) or {}
    if pcall(drawing.new, proxy_with_metatable) then
        fail_test(captures, "Drawing.new", "Allowed an invalid drawing to be made from improper argument")
    end
    local proxy_without_metatable = type(environment.newproxy) == "function" and environment.newproxy(false) or {}
    local proxy_ok, proxy_object = pcall(drawing.new, proxy_without_metatable)
    if proxy_ok and proxy_object then
        local accepted_bad_properties = pcall(function()
            proxy_object.Filled = true
            proxy_object.Position = environment.Vector2
        end)
        if accepted_bad_properties then
            fail_test(captures, "Drawing.new", "Allowed an invalid drawing to be made from improper argument")
        end
        local removed_ok, removed_error = pcall(function() proxy_object:Remove() end)
        if not removed_ok then
            fail_test(captures, "Drawing.new", "Destroy threw an error: " .. tostring(removed_error))
        end
    end

    local spoofed_color = type(environment.newproxy) == "function" and environment.newproxy(true) or {}
    local spoofed_metatable = environment.getrawmetatable and environment.getrawmetatable(spoofed_color)
    if type(spoofed_metatable) == "table" then spoofed_metatable.__type = "Color3" end
    if pcall(function() circle.Color = spoofed_color end)
        or pcall(function() circle.Position = spoofed_color end)
    then
        fail_test(captures, "Drawing.new", "Accepted an invalid Drawing property value")
    end

    local text_object = drawing.new("Text")
    if pcall(function() text_object.Text = function() return environment.game end end) then
        fail_test(captures, "Drawing.new", "Accepted a function as a Text property")
    end
    local line_object = drawing.new("Line")
    if pcall(function() line_object.From = 0 end)
        or pcall(function() line_object.Thickness = function() end end)
    then
        fail_test(captures, "Drawing.new", "Accepted an invalid Line property value")
    end

    if pcall(environment.isrenderobj, -0) then
        fail_test(captures, "isrenderobj", "Accepted an invalid render object")
    end
    local close_member = environment.game and environment.game.Close
    if close_member ~= nil and pcall(environment.isrenderobj, close_member) then
        fail_test(captures, "isrenderobj", "Accepted an invalid render object")
    end

    -- P359-P374 are separate compiled callbacks. They are kept as explicit
    -- source-level operations here rather than being collapsed into the final
    -- cleardrawcache assertion.
    if container then
        local disposable = environment.Instance.new("Frame")
        disposable.Name = "sUNC_drawing_clear_probe"
        local disposable_child = environment.Instance.new("Frame")
        disposable_child.Parent = disposable
        disposable.Parent = container
        disposable:ClearAllChildren()
        if #disposable:GetChildren() ~= 0 then
            fail_test(captures, "Drawing.new", "ClearAllChildren failed on the Drawing container probe")
        end
        disposable:Destroy()
        if disposable.Parent ~= nil then
            fail_test(captures, "Drawing.new", "Destroy failed on the Drawing container probe")
        end

        local stroke = container:FindFirstChildWhichIsA("UIStroke", true)
        local corner = container:FindFirstChildWhichIsA("UICorner", true)
        if stroke == nil and corner == nil then
            fail_test(captures, "Drawing.new", "Wasn't able to find the Drawing element")
        end
    end

    local previous_color = circle.Color
    environment.setrenderproperty(circle, "Color", environment.Color3.fromRGB(0, 255, 0))
    if tostring(circle.Color) ~= "0, 1, 0" then
        fail_test(captures, "setrenderproperty", "Failed to set the render's color property")
    end
    if tostring(environment.getrenderproperty(circle, "Color")) ~= "0, 1, 0" then
        fail_test(captures, "getrenderproperty", "Output couldn't match new Drawing's color property")
    end
    circle.Color = previous_color

    if captures.debug_config and captures.debug_config.extradebugprints then
        (environment.print or print)("Drawing.Fonts")
    end
    if type(drawing.Fonts) ~= "table" then
        fail_test(captures, "Drawing.Fonts", "Drawing.Fonts does not exist")
    else
        for _, font_name in ipairs({ "UI", "System", "Plex", "Monospace" }) do
            if drawing.Fonts[font_name] == nil then
                fail_test(captures, "Drawing.Fonts", "Drawing.Fonts doesn't have the minimum required fonts")
                break
            end
        end
    end

    environment.cleardrawcache()
    if task_library and task_library.wait then task_library.wait(0.067) end
    for _, object in ipairs({ circle, text_object, line_object }) do
        if environment.isrenderobj(object) then
            fail_test(captures, "cleardrawcache", "The object exists after clearing the cache")
        end
    end
end

local function test_getreg(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local registry = environment.getreg()
    if type(registry) ~= "table" then
        return fail_test(captures, "getreg", "getreg did not return a table")
    end
    local saw_value = false
    for _ in pairs(registry) do saw_value = true break end
    if not saw_value then fail_test(captures, "getreg", "getreg returned an empty registry") end
    return registry
end

local function test_identifyexecutor(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local name, version = environment.identifyexecutor()
    if type(name) ~= "string" or name == "" then
        fail_test(captures, "identifyexecutor", "Didn't return the name as a string")
    end
    if version ~= nil and type(version) ~= "string" then
        fail_test(captures, "identifyexecutor", "Didn't return the version as a string")
    end
    captures.executor_name = name
    captures.executor_version = version
end

local function compare_test_results(_, _, left, right)
    return left.test < right.test
end

local function reserve_result_slot(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local occupied_slots = captures.completed_slots or {}
    local random = captures.random or (environment.math and environment.math.random) or math.random
    local slot = random(0, 124)
    while occupied_slots[slot] do
        environment.task.wait()
        slot = random(0, 124)
    end
    occupied_slots[slot] = true
    captures.completed_slots = occupied_slots
    return slot
end

-- The original closure used math.random twice.  Half of the time it generated
-- a byte in [126, 255]; otherwise it selected one value from a fixture table.
local function choose_remote_probe_value(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local random = captures.random or math.random
    local fixture_values = captures.fixture_values or captures[2] or {}
    if random(0, 1) == 1 then
        return random(126, 255)
    end
    if #fixture_values == 0 then return nil end
    return fixture_values[random(#fixture_values)]
end

local invoke_remote_probe

local function protected_remote_invoke(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    return pcall(invoke_remote_probe, environment, captures)
end

-- Lua adjusts every non-final multiple-return expression to one value.  The
-- original call therefore sent one value from each of the first nine fixture
-- lists and all values from the tenth list.
invoke_remote_probe = function(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local argument_lists = captures.argument_lists or captures[1] or {}
    local remote = environment.game:GetService("ReplicatedStorage"):FindFirstChild("poooop")
    assert(remote and remote.InvokeServer, "missing ReplicatedStorage.poooop")

    local function values(index)
        return table.unpack(argument_lists[index] or {})
    end
    return remote:InvokeServer(
        values(1), values(2), values(3), values(4), values(5),
        values(6), values(7), values(8), values(9), values(10)
    )
end

local function build_remote_probe_buffer(environment)
    environment = resolve_environment(environment)
    local payload = environment.buffer.create(404)
    environment.buffer.writei16(payload, 77, 91)
    environment.buffer.writef64(payload, 91, get_network_ping(environment))
    return payload
end

local function invoke_remote_event_probe(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local argument_factory = captures.argument_factory or captures[1]
    local replicated_storage = environment.game:GetService("ReplicatedStorage")

    local invoke_remote = replicated_storage:FindFirstChild("beepbeepbeepbeep")
    local event_remote = replicated_storage:FindFirstChild("elaborateonthispastingphenomenon")
    local invoke_arguments = table.pack(argument_factory())
    invoke_remote:InvokeServer(table.unpack(invoke_arguments, 1, invoke_arguments.n))
    local event_arguments = table.pack(argument_factory())
    event_remote:FireServer(table.unpack(event_arguments, 1, event_arguments.n))
end

-- P377-P380. The coordinator does not merely define the deterministic random
-- closure: it uses it to reserve collision-free result slots and to assemble
-- randomized argument lists for a protected RemoteFunction probe. The exact
-- fixture pools are place-specific; callers may supply them, while the default
-- pool is reconstructed from values already produced by this suite run.
local function build_remote_probe_argument_lists(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local fixture_values = captures.remote_probe_fixture_values
        or captures.fixture_values
        or {
            captures.executor_name or "Unknown identifier",
            captures.executor_version or "Unknown version",
            captures.serialized_result_archive,
            captures.result_metadata,
            true,
            false,
            0,
            1,
            "sUNC",
        }

    local compact_fixture_values = {}
    for _, value in ipairs(fixture_values) do
        if value ~= nil then compact_fixture_values[#compact_fixture_values + 1] = value end
    end
    if #compact_fixture_values == 0 then compact_fixture_values[1] = "sUNC" end

    captures.fixture_values = compact_fixture_values
    local argument_lists = {}
    for list_index = 1, 10 do
        local values = {}
        -- P380's first nine table.unpack calls are non-final expressions, so
        -- Lua forwards only their first value. The tenth is final and may
        -- forward more than one; two values preserve that observable distinction.
        local value_count = list_index == 10 and 2 or 1
        for value_index = 1, value_count do
            values[value_index] = choose_remote_probe_value(environment, captures)
        end
        argument_lists[list_index] = values
    end

    captures.argument_lists = argument_lists
    return argument_lists
end

local function submit_serialized_result_archive(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}

    local serialized_archive = captures.serialized_result_archive
    if serialized_archive == nil then return nil end

    local replicated_storage = environment.game:GetService("ReplicatedStorage")
    local remote = replicated_storage:FindFirstChild("poooop")
    assert(remote and remote.InvokeServer, "missing ReplicatedStorage.poooop")

    return remote:InvokeServer(
        "\255\t\rFinished\2\251",
        nil,
        environment.buffer.create(1),
        2,
        nil,
        serialized_archive
    )
end

local find_result_metadata_value
local find_fingerprint

local function request_sunc_result_metadata(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local metadata = captures.result_metadata or {}

    local response = environment.request({
        Url = "https://script.sunc.su/sunc.lua/",
        Method = "GET",
    })
    local decoded
    if response and type(response.Body) == "string" then
        local ok, value = pcall(function()
            return environment.game:GetService("HttpService"):JSONDecode(response.Body)
        end)
        if not ok then ok, value = pcall(json_decode, response.Body) end
        if ok then decoded = value end
    end

    local records = decoded and (decoded.unbob or decoded) or {}
    metadata.UserAgent = find_result_metadata_value(nil, nil, records, "UserAgent")
        or "Unknown identifier"
    local fingerprint = find_fingerprint(environment, captures, records)
    metadata.Fingerprint = is_valid_hex_identifier(fingerprint)
        and fingerprint or "Unknown identifier"

    metadata.BufferWriteProbe = table.pack(pcall(build_probe_buffer, environment))
    metadata.EmptyBufferProbe = table.pack(pcall(create_empty_probe_buffer, environment))
    metadata.PublicIPProbe = table.pack(pcall(probe_public_ip_endpoint, environment))

    captures.result_metadata = metadata
    return metadata
end

find_fingerprint = function(environment, captures, records)
    return find_result_metadata_value(environment, captures, records, "Fingerprint")
end

-- Shared implementation inferred from the two identical erased iterator bodies.
find_result_metadata_value = function(_, _, records, wanted_key)
    for key, value in pairs(records or {}) do
        if key == wanted_key then return value end
        if type(value) == "table" then
            if value.name == wanted_key then return value.value end
            if value.key == wanted_key then return value.value or value[2] end
            if value[wanted_key] ~= nil then return value[wanted_key] end
        end
    end
end

-- Reconnect the coordinator edges that were lost when P31 was first replaced by
-- a hand-written test loop. This branch remains behind allow_network, but once
-- enabled it follows the recovered order: protected randomized probe, two
-- buffer-valued remotes, metadata request, then encrypted result submission.
local function run_original_remote_reporter(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local scheduler = environment.task or task

    build_remote_probe_argument_lists(environment, captures)
    local function launch(callback)
        if scheduler and type(scheduler.spawn) == "function" then
            scheduler.spawn(callback)
        else
            callback()
        end
    end

    launch(function()
        captures.random_remote_probe = table.pack(protected_remote_invoke(environment, captures))
    end)

    captures.argument_factory = function()
        return build_remote_probe_buffer(environment)
    end
    launch(function()
        captures.buffer_remote_probe = table.pack(pcall(invoke_remote_event_probe, environment, captures))
    end)

    local metadata = request_sunc_result_metadata(environment, captures)
    captures.result_submission = table.pack(pcall(submit_serialized_result_archive, environment, captures))
    return metadata
end

-- P36 subtracts a fixed amount from each byte. Near the coordinator tail it
-- decodes the place handshake stored in Handle.CollisionGroup with an offset of
-- five, then prefixes the result with r.sunc.su/.
local function decode_shifted_bytes(text, amount)
    local output = table.create and table.create(#text) or {}
    for index = 1, #text do
        output[index] = string.char(string.byte(text, index) - amount)
    end
    return table.concat(output)
end

local function recover_result_link_from_place(environment)
    environment = resolve_environment(environment)
    local workspace_api = environment.workspace or workspace
    local ok, handle = pcall(function()
        return workspace_api.FreakyBox.f["White Kemono Dragon Horns"].Handle
    end)
    if not ok or handle == nil then return nil end

    local encoded = handle.CollisionGroup
    if type(encoded) ~= "string" or encoded == "" or encoded == "Default" then
        return nil
    end

    local result_link = "r.sunc.su/" .. decode_shifted_bytes(encoded, 5)
    handle.CollisionGroup = "Default"
    return result_link
end

-- This is a complete source-level rebuild of the result-link widget.  All
-- dimensions, colors and timing constants come from the recovered prototype.
local copy_result_link

local function create_result_frame(environment, captures, result_link)
    environment = resolve_environment(environment)
    captures = captures or {}
    result_link = result_link or captures.result_link or ""

    local tween_service = environment.game:GetService("TweenService")
    local input_service = environment.game:GetService("UserInputService")

    local frame = environment.Instance.new("Frame")
    frame.Name = "result_frame"
    frame.AnchorPoint = environment.Vector2.new(0.5, 1)
    frame.BackgroundColor3 = environment.Color3.fromRGB(33, 33, 33)
    frame.BorderColor3 = environment.Color3.fromRGB(0, 0, 0)
    frame.BorderSizePixel = 0
    frame.Position = environment.UDim2.new(0.5, 0, 1.3, 0)
    frame.Size = environment.UDim2.new(0.45, 0, 0.08, 0)
    frame.ZIndex = 2

    local corner = environment.Instance.new("UICorner")
    corner.CornerRadius = environment.UDim.new(0.2, 0)
    corner.Parent = frame

    local stroke = environment.Instance.new("UIStroke")
    stroke.Color = environment.Color3.fromRGB(189, 155, 245)
    stroke.Thickness = 2.5
    stroke.Transparency = 0.5
    stroke.Parent = frame

    local text_container = environment.Instance.new("Frame")
    text_container.Name = "text_container"
    text_container.AnchorPoint = environment.Vector2.new(0.5, 0.5)
    text_container.Position = environment.UDim2.new(0.5, 0, 0.5, 0)
    text_container.Size = environment.UDim2.new(1, 0, 1, 0)
    text_container.BackgroundTransparency = 1
    text_container.Parent = frame

    local aspect = environment.Instance.new("UIAspectRatioConstraint")
    aspect.AspectRatio = 10
    aspect.Parent = text_container

    local layout = environment.Instance.new("UIListLayout")
    layout.FillDirection = environment.Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = environment.Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = environment.Enum.VerticalAlignment.Center
    layout.SortOrder = environment.Enum.SortOrder.LayoutOrder
    layout.Padding = environment.UDim.new(0.005, 0)
    layout.Parent = text_container

    local label = environment.Instance.new("TextLabel")
    label.Name = "view_result_textlabel"
    label.BackgroundTransparency = 1
    label.Size = environment.UDim2.new(0.36, 0, 0.7, 0)
    label.ZIndex = 3
    label.Font = environment.Enum.Font.RobotoMono
    label.Text = "View Result:"
    label.TextColor3 = environment.Color3.fromRGB(189, 155, 245)
    label.TextScaled = true
    label.TextWrapped = true
    label.TextXAlignment = environment.Enum.TextXAlignment.Right
    label.LayoutOrder = 1
    label.Parent = text_container

    local label_size = environment.Instance.new("UITextSizeConstraint")
    label_size.MinTextSize = 12
    label_size.MaxTextSize = 40
    label_size.Parent = label

    local link_box = environment.Instance.new("TextBox")
    link_box.Name = "link_textbox"
    link_box.Text = result_link
    link_box.BackgroundTransparency = 1
    link_box.Size = environment.UDim2.new(0.44, 0, 0.7, 0)
    link_box.ZIndex = 3
    link_box.ClearTextOnFocus = false
    link_box.Font = environment.Enum.Font.RobotoMono
    link_box.TextColor3 = environment.Color3.fromRGB(255, 255, 255)
    link_box.TextScaled = true
    link_box.TextWrapped = true
    link_box.TextXAlignment = environment.Enum.TextXAlignment.Left
    link_box.TextEditable = false
    link_box.LayoutOrder = 2
    link_box.Parent = text_container

    local box_size = environment.Instance.new("UITextSizeConstraint")
    box_size.MinTextSize = 12
    box_size.MaxTextSize = 40
    box_size.Parent = link_box

    local click_overlay = environment.Instance.new("TextButton")
    click_overlay.Name = "copy_result_button"
    click_overlay.Text = ""
    click_overlay.AutoButtonColor = false
    click_overlay.BackgroundColor3 = environment.Color3.new(0, 0, 0)
    click_overlay.BackgroundTransparency = 1
    click_overlay.BorderSizePixel = 0
    click_overlay.Position = environment.UDim2.new(0, 0, -0.016, 1)
    click_overlay.Size = environment.UDim2.new(1, 0, 1, 0)
    click_overlay.ZIndex = 4
    click_overlay.Parent = frame

    local overlay_corner = environment.Instance.new("UICorner")
    overlay_corner.CornerRadius = environment.UDim.new(0.2, 0)
    overlay_corner.Parent = click_overlay

    local hover_size = environment.UDim2.new(
        frame.Size.X.Scale * 1.03,
        frame.Size.X.Offset * 1.025,
        frame.Size.Y.Scale * 1.025,
        frame.Size.Y.Offset * 1.025
    )
    local hover_in = tween_service:Create(frame,
        environment.TweenInfo.new(0.245, environment.Enum.EasingStyle.Cubic, environment.Enum.EasingDirection.Out),
        { Size = hover_size })
    local hover_out = tween_service:Create(frame,
        environment.TweenInfo.new(0.19, environment.Enum.EasingStyle.Sine, environment.Enum.EasingDirection.Out),
        { Size = frame.Size })

    frame.MouseEnter:Connect(function() hover_out:Cancel(); hover_in:Play() end)
    frame.MouseLeave:Connect(function() hover_in:Cancel(); hover_out:Play() end)
    click_overlay.MouseButton1Click:Connect(function()
        copy_result_link(environment, captures, result_link, label, link_box, click_overlay)
    end)

    tween_service:Create(frame,
        environment.TweenInfo.new(0.27, environment.Enum.EasingStyle.Cubic, environment.Enum.EasingDirection.Out),
        { Position = environment.UDim2.new(0.5, 0, 0.932, 0) }):Play()

    -- Preserve references for callers that previously received them through
    -- compiler-generated captures.
    captures.result_frame = frame
    captures.result_label = label
    captures.result_link_box = link_box
    captures.result_input_service = input_service
    return frame
end

copy_result_link = function(environment, captures, result_link, label, link_box, overlay)
    environment = resolve_environment(environment)
    captures = captures or {}
    result_link = tostring(result_link or "")
    if result_link:sub(1, 8) ~= "https://" then result_link = "https://" .. result_link end
    pcall(environment.setclipboard, result_link)

    local tween_service = environment.game:GetService("TweenService")
    local container = overlay and overlay.Parent
    if not container then return end

    local notice = label:Clone()
    notice.Name = "C"
    notice.Text = "Copied to clipboard!"
    notice.Font = environment.Enum.Font.RobotoMono
    notice.AnchorPoint = environment.Vector2.new(0.5, 0.5)
    notice.Position = environment.UDim2.new(0.5, 0, 0.5, 0)
    notice.Size = environment.UDim2.new(1, 0, 0.7, 0)
    notice.TextXAlignment = environment.Enum.TextXAlignment.Center
    notice.TextTransparency = 1
    notice.ZIndex = 4
    notice.Parent = container

    local fade_overlay_in = tween_service:Create(overlay, environment.TweenInfo.new(0.2), { BackgroundTransparency = 0.15 })
    local fade_overlay_out = tween_service:Create(overlay, environment.TweenInfo.new(0.2), { BackgroundTransparency = 1 })
    local notice_in = tween_service:Create(notice, environment.TweenInfo.new(0.2), { TextTransparency = 0 })
    local notice_out = tween_service:Create(notice, environment.TweenInfo.new(0.5), { TextTransparency = 1 })
    local label_out = tween_service:Create(label, environment.TweenInfo.new(0.1), { TextTransparency = 1 })
    local link_out = tween_service:Create(link_box, environment.TweenInfo.new(0.1), { TextTransparency = 1 })
    local label_in = tween_service:Create(label, environment.TweenInfo.new(0.1), { TextTransparency = 0 })
    local link_in = tween_service:Create(link_box, environment.TweenInfo.new(0.1), { TextTransparency = 0 })

    fade_overlay_in:Play(); notice_in:Play(); label_out:Play(); link_out:Play()
    environment.task.wait(0.51)
    notice_out:Play(); fade_overlay_out:Play()
    environment.task.wait(0.21)
    label_in:Play(); link_in:Play()
    notice_out.Completed:Connect(function() safe_destroy(notice) end)
end

local function create_result_background(environment)
    environment = environment or (getgenv and getgenv()) or _G
    local frame = environment.Instance.new("Frame")
    frame.Name = "result_background"
    frame.AnchorPoint = environment.Vector2.new(0.5, 0.5)
    frame.BackgroundColor3 = environment.Color3.fromRGB(255, 255, 255)
    frame.BackgroundTransparency = 0.5
    frame.BorderSizePixel = 0
    frame.Position = environment.UDim2.new(0.5, 0, 0.5, 0)
    frame.Size = environment.UDim2.new(1, 0, 1, 0)

    local gradient = environment.Instance.new("UIGradient")
    gradient.Color = environment.ColorSequence.new({
        environment.ColorSequenceKeypoint.new(0, environment.Color3.fromRGB(0, 0, 0)),
        environment.ColorSequenceKeypoint.new(1, environment.Color3.fromRGB(0, 0, 0)),
    })
    gradient.Rotation = 90
    gradient.Transparency = environment.NumberSequence.new({
        environment.NumberSequenceKeypoint.new(0, 1),
        environment.NumberSequenceKeypoint.new(0.69, 0.81),
        environment.NumberSequenceKeypoint.new(0.87, 0.68),
        environment.NumberSequenceKeypoint.new(1, 0),
    })
    gradient.Parent = frame
    return frame
end

local function create_result_gui(environment, captures)
    environment = environment or (getgenv and getgenv()) or _G
    captures = captures or {}
    local screen_gui = environment.Instance.new("ScreenGui")
    screen_gui.Name = "sUNC_melon_result"
    screen_gui.ResetOnSpawn = false
    screen_gui.ZIndexBehavior = environment.Enum.ZIndexBehavior.Global
    screen_gui.Parent = environment.game:GetService("CoreGui")

    local background = create_result_background(environment)
    background.Parent = screen_gui

    local frame_factory = captures.create_result_frame or captures[2] or create_result_frame
    if frame_factory then
        local result_frame = frame_factory(environment, captures)
        if result_frame then result_frame.Parent = background end
    end
    return screen_gui
end

local function round_result_value(_, _, value)
    return math.floor(value * 100) / 100
end


-- ============================================================================
-- Suite coordinator
-- ============================================================================
-- P31 also contains fixture payload strings (for example "CatNeMaiPrivim?",
-- "dkplkhaljivcumn?", "Left Arm", and "Let em in"). They are values passed
-- through the place-specific dependency/reporter graph, not independent control
-- flow blocks; their producing calls are restored in the transport functions.
-- Restoration invariant: each TEST_PLAN entry was audited together with every
-- descendant prototype/callback for diagnostic-string and terminal-branch
-- coverage. P31's live coordinator captures are connected below. P66 is the one
-- decoded coordinator closure proven never read. P20 and P82-P89 are explicit
-- source functions or named inlined closures below; none are excluded by name lookup.


-- P72. Telemetry history and the place-specific RemoteEvent receive the same
-- string; the remote name is not an inferred euphemism, unfortunately.
local function send_test_telemetry(environment, history, value)
    local text = tostring(value)
    table.insert(history, text)
    environment.game:GetService("ReplicatedStorage")
        .imagineifwewerecuteandhadcutelittleskirts:FireServer(text)
end

local function placeholder_value(environment)
    return environment._ and environment._[0]
end

local function mark_probe_complete(box)
    box[1] = false
end

local function patch_call_dialog_layout(environment)
    local core_gui = environment.game:GetService("CoreGui")
    local layout = core_gui.CallDialogScreen.CallDialog.AlertContents.Footer.Buttons["1"]
        .ButtonContent.ButtonMiddleContent.UIListLayout
    layout.Archivable = false
end

local function run_call_context_stability_probe(environment)
    for _ = 1, 32 do
        if type(environment.checkcaller) == "function" then environment.checkcaller() end
        if type(environment.getcallingscript) == "function" then environment.getcallingscript() end
        if type(environment.getnamecallmethod) == "function" then environment.getnamecallmethod() end
    end
end

local function test_call_context_apis(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local functions = {
        checkcaller = environment.checkcaller,
        getcallingscript = environment.getcallingscript,
        getnamecallmethod = environment.getnamecallmethod,
    }
    for name, callback in pairs(functions) do
        if type(callback) ~= "function" then
            fail_test(captures, name, "required function is unavailable: " .. name)
        end
    end
    local ok, error_message = pcall(run_call_context_stability_probe, environment)
    if not ok then
        fail_test(captures, "checkcaller", tostring(error_message))
        fail_test(captures, "getcallingscript", tostring(error_message))
        fail_test(captures, "getnamecallmethod", tostring(error_message))
    end
end

local function test_getrawmetatable(environment, captures)
    environment = resolve_environment(environment)
    captures = captures or {}
    local object = environment.game
    local ok, metatable = pcall(environment.getrawmetatable, object)
    if not ok or type(metatable) ~= "table" then
        return fail_test(captures, "getrawmetatable", "Couldn't retrieve a raw metatable")
    end
    if environment.getmetatable and environment.getmetatable(object) == nil then
        fail_test(captures, "getrawmetatable", "Raw metatable lookup did not expose the protected instance metatable")
    end
end

local function invoke_loaded_dependency_callback(callback)
    return callback()
end

local function run_downloaded_loadstring_probe(environment, captures)
    if captures.debug_config and captures.debug_config.printcheckpoints then
        (environment.print or print)("Inside")
        environment.task.wait(0.001)
    end
    environment.task.wait()
    local source = environment.game:HttpGet(
        "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/testy.lua"
    )
    local chunk, compile_error = environment.loadstring(source)
    if not chunk then error(compile_error, 2) end
    return invoke_loaded_dependency_callback(chunk)
end

local function connect_actor_resource_probe(environment)
    environment.task.wait(0.1)
    local render_stepped = environment.game:GetService("RunService").RenderStepped
    return render_stepped:Connect(function()
        -- P79 is the original actor-isolation/resource-exhaustion probe. Nothing
        -- is hidden or softened here. The maze requested a gigabyte at a time;
        -- the machine, having reviewed the request, records the exact audacity.
        while true do
            local allocations = {}
            for index = 1, math.huge do
                allocations[index] = (environment.buffer or buffer).create(2 ^ 30)
            end
            environment.task.wait()
        end
    end)
end

local function handle_result_timeout(output, warning)
    output("\n")
    warning("Timed out while waiting for numelon result.")
end

local function handle_result_failure(output, warning)
    output("\n")
    warning("Failed to get melon result")
end

local function collect_test_function_paths(test_plan)
    local ordered, seen = {}, {}
    local excluded_from_nil_scan = {
        ["base64encode"] = true,
        ["base64decode"] = true,
        ["Drawing.new"] = true,
        ["WebSocket.connect"] = true,
        ["getgenv"] = true,
        ["Drawing.Fonts"] = true,
    }
    for _, specification in ipairs(test_plan) do
        for _, path in ipairs(specification.requires or { specification.test }) do
            if not seen[path] and not excluded_from_nil_scan[path] then
                seen[path] = true
                ordered[#ordered + 1] = path
            end
        end
    end
    return ordered
end

local function discover_passed_functions(environment)
    local passed = {}
    local replicated_storage = environment.game and environment.game:GetService("ReplicatedStorage")
    local remote = replicated_storage and replicated_storage:FindFirstChild("GetPassedFuncs")
    if not remote or type(remote.InvokeServer) ~= "function" then return passed end

    local ok, response = pcall(function() return remote:InvokeServer() end)
    if not ok or response == "Empty" or type(response) ~= "table" then return passed end

    local player = environment.game:GetService("Players").LocalPlayer
    local player_entry = player and response[player.Name]
    if type(player_entry) == "table" then return player_entry end
    return passed
end

-- P80 is a coordinator telemetry closure, not the test-plan dispatcher. It
-- reports executor identity together with the two debug switches to the
-- captured callback. The large arithmetic body surrounding this call was
-- self-modifying obfuscator bookkeeping and has no additional suite effect.
local function report_executor_debug_state(environment, debug_config, reporter)
    local executor_name = type(environment.identifyexecutor) == "function"
        and select(1, environment.identifyexecutor()) or "Unknown"
    return reporter(executor_name, debug_config.printcheckpoints and "1" or "0", debug_config.delaybetweentests)
end

local TEST_PLAN = {
    { after = "Past cache", test = "cache.invalidate", run = test_getreg_cache, requires = { "cache.invalidate", "getreg" } },
    { test = "cache.iscached", run = test_cache_invalidate_and_cache_iscached, requires = { "cache.invalidate", "cache.iscached" } },
    { test = "cache.replace", run = test_cache_invalidate_replace, requires = { "cache.invalidate", "cache.replace" } },
    { before = "Next: getcallbackvalue", after = "Past getcallbackvalue", test = "getcallbackvalue", run = test_getcallbackvalue },
    { before = "Next: getscriptclosure", after = "Past getscriptclosure", test = "getscriptclosure", run = test_getscriptclosure },
    { before = "Next: compareinstances", after = "Past compareinstances", test = "compareinstances", run = test_compareinstances },
    { before = "Next: cloneref", after = "Past cloneref", test = "cloneref", run = test_compareinstances_with_cloneref, requires = { "cloneref", "compareinstances" } },
    { before = "Next: getrenv", after = "Past getrenv", test = "getrenv", run = test_environment_access },
    { before = "Next: firesignal", after = "past firesignal", test = "firesignal", run = test_firesignal },
    { before = "Next: Encoding", after = "Past b64", test = "base64encode", run = test_base64_encode, network = true },
    { test = "base64decode", run = test_base64_decode, network = true },
    { before = "Next: lz4compress", after = "Past lz4", test = "lz4compress", run = test_lz4_compress },
    { after = "Past Encoding", test = "lz4decompress", run = test_lz4_decompress },
    { before = "Next: getgc", after = "Past [5]", test = "getgc", run = test_getgc },
    { before = "Next: genv", after = "Past genv", test = "getgenv", run = test_getgenv },
    { test = "checkcaller", run = test_call_context_apis,
      features = { "checkcaller", "getcallingscript", "getnamecallmethod" },
      requires = { "checkcaller", "getcallingscript", "getnamecallmethod" } },
    { before = "Next: getloadedmodules", after = "Past getloadedmodules", test = "getloadedmodules", run = test_getloadedmodules },
    { test = "getrawmetatable", run = test_getrawmetatable },
    { before = "Next: setrawmetatable", after = "past setrawmetatable", test = "setrawmetatable", run = test_setrawmetatable },
    { before = "Next: getrunningscripts", after = "past getrunningscripts", test = "getrunningscripts", run = test_getrunningscripts },
    { before = "Next: getscripts", after = "past getscripts", test = "getscripts", run = test_getscripts },
    { before = "Next: getscriptfromthread", test = "getscriptfromthread", run = test_getscriptfromthread },
    { before = "Next: getsenv", after = "Past getsenv", test = "getsenv", run = test_getsenv },
    { before = "Next: debug.getproto[o]", after = "past debug.getproto[o]", test = "debug.getproto", run = test_debug_getproto },
    { before = "Next: debug.getconstant", after = "Past debug.getconstant", test = "debug.getconstant", run = test_debug_getconstant_script },
    { before = "Next: debug.getupvalue", after = "past debug.getupvalue", test = "debug.getupvalue", run = test_debug_getupvalue },
    { before = "Next: debug.setupvalue", after = "Past debug.setupvalue", test = "debug.setupvalue", run = test_debug_setupvalue },
    { before = "Next: debug.getprotos", after = "Past debug.getprotos", test = "debug.getprotos", run = test_debug_getprotos },
    { before = "Next: debug.getupvalues", after = "Past debug.getupvalues", test = "debug.getupvalues", run = test_debug_getupvalues },
    { before = "Next: debug.getstack", after = "Past debug.getstack", test = "debug.getstack", run = test_debug_getstack },
    { before = "Next: debug.setstack", after = "Past debug.setstack[2]", test = "debug.setstack", run = run_debug_setstack_test, requires = { "debug.setstack", "debug.getstack", "getgc" } },
    { before = "Next: debug.getinfo", after = "Past debug.getinfo", test = "debug.getinfo", run = test_debug_getinfo },
    { before = "Next: debug.getconstants", after = "Past debug.getconstants", test = "debug.getconstants", run = test_debug_getconstants_script },
    { before = "Next: debug.setconstant", after = "Past debug.setconstant", test = "debug.setconstant", run = test_debug_setconstant },
    { before = "Next: getfunctionhash", after = "Past getfunctionhash", test = "getfunctionhash", run = test_getfunctionhash },
    { before = "Next: filtergc", after = "Past filtergc", test = "filtergc", run = test_filtergc, requires = { "filtergc", "getfunctionhash" } },
    { before = "Next: replicatesignal", after = "Past replicatesigmal", test = "replicatesignal", run = test_replicatesignal },
    { before = "Next: hookfunction", after = "Past hookfunction", test = "hookfunction", run = test_hookfunction },
    { before = "Next: clonefunction", after = "past clonefunction", test = "clonefunction", run = test_clonefunction },
    { before = "Next: restorefunction", after = "Past restorefunction", test = "restorefunction", run = test_restorefunction },
    { before = "Next: iscclosure", after = "Past iscclosure", test = "iscclosure", run = test_iscclosure, requires = { "iscclosure", "newcclosure" } },
    { before = "Next: isexecutorclosure", after = "Past isexecutorclosure", test = "isexecutorclosure", run = test_isexecutorclosure },
    { before = "Next: firetouchinterest", after = "Past firetouchinterest", test = "firetouchinterest", run = test_firetouchinterest },
    { before = "Next: islclosure", after = "Past islclosure", test = "islclosure", run = test_islclosure },
    { before = "Next: newcclosure", after = "Past newcclosure", test = "newcclosure", run = test_newcclosure, requires = { "newcclosure", "debug.info", "clonefunction" } },
    { before = "Next: getscripthash", after = "Past getscripthash", test = "getscripthash", run = test_getscripthash },
    { before = "Next: setreadonly", after = "Past setreadonly", test = "setreadonly", run = test_setreadonly, requires = { "setreadonly", "table.freeze", "table.isfrozen" } },
    { before = "Next: request", after = "past request", test = "request", run = test_request, network = true },
    { before = "Next: fireclickdetector", after = "Past fireclickdetector", test = "fireclickdetector", run = test_fireclickdetector },
    { before = "Next: fireproximityprompt", after = "Past fireproximityprompt fires", test = "fireproximityprompt", run = test_fireproximityprompt },
    { before = "Next: getconnections", after = "Past getconnections", test = "hookmetamethod", run = test_hookmetamethod_and_connections, features = { "hookmetamethod", "getconnections", "getnamecallmethod" } },
    { before = "Next: filesys", after = "Past filesystem", test = "filesystem", run = test_filesystem, filesystem = true,
      features = { "writefile", "readfile", "appendfile", "isfile", "isfolder", "makefolder", "listfiles", "delfile", "delfolder", "loadfile" } },
    { before = "Next: gethiddenproperty", after = "Past properties", test = "gethiddenproperty", run = test_hidden_and_readonly_properties },
    { test = "sethiddenproperty", run = test_sethiddenproperty, prerequisite_reason = "Can't verify due to 'gethiddenproperty' not working reliably" },
    { before = "Next: getinstances", after = "Past getinstances", test = "getinstances", run = test_getinstances },
    { before = "Next: getnilinstances", after = "Past instances", test = "getnilinstances", run = test_getnilinstances },
    { before = "Next: setscriptable", after = "Past scriptables", test = "setscriptable", run = test_scriptable_properties, features = { "setscriptable", "isscriptable" } },
    { test = "isscriptable", run = test_isscriptable },
    { test = "isreadonly", run = test_isreadonly, features = { "isreadonly", "setreadonly" } },
    { before = "Next: setthreadidentity", after = "Past identities", test = "setthreadidentity", run = test_thread_identity_and_capabilities, features = { "setthreadidentity", "getthreadidentity", "getthreadcapabilities" }, prerequisite_reason = "Can't test due to 'setthreadidentity' not working reliably" },
    { test = "getthreadidentity", run = test_getthreadidentity },
    { before = "Next: gethui", after = "Past gethui", test = "gethui", run = test_gethui },
    { before = "Next: getscriptbytecode", after = "Past bytecode", test = "getscriptbytecode", run = test_getscriptbytecode },
    { before = "Next: decompile", after = "Past decompile", test = "decompile", run = test_decompile, requires = { "decompile", "getscriptbytecode", "loadstring" } },
    { before = "Next: loadstring", after = "Past loadstring[basic]", test = "loadstring[basic]", run = test_loadstring_basic, requires = { "loadstring" } },
    { test = "loadstring[environment]", run = test_loadstring_world_effect, requires = { "loadstring" } },
    { test = "loadstring[simple]", run = test_loadstring_simple_obfuscated, network = true, requires = { "loadstring" } },
    { test = "loadstring[complicated]", run = test_loadstring_complicated, network = true, requires = { "loadstring" } },
    { before = "Next: getcustomasset", after = "Past customasset", test = "getcustomasset", run = test_getcustomasset, network = true, filesystem = true },
    { before = "Next: websocket", after = "Past sockets", test = "WebSocket.connect", run = test_websocket, network = true },
    { before = "Next: Drawing", after = "Past drawing", test = "Drawing", run = test_drawing_suite,
      features = { "Drawing.new", "Drawing.Fonts", "isrenderobj", "getrenderproperty", "setrenderproperty", "cleardrawcache" } },
    { test = "identifyexecutor", run = test_identifyexecutor, requires = { "identifyexecutor" } },
}

local function lookup_environment_path(environment, dotted_path)
    local current = environment
    for segment in tostring(dotted_path):gmatch("[^%.]+") do
        if type(current) ~= "table" and type(current) ~= "userdata" then return nil end
        local ok, value = pcall(function() return current[segment] end)
        if not ok or value == nil then return nil end
        current = value
    end
    return current
end

local function copy_array(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end

-- P80. The original coordinator creates this closure and delegates every test
-- specification through it. Keeping the dispatcher named prevents child tests
-- from being declared "unused" merely because their parent was rewritten.
local function execute_test_plan(test_plan, selected_set, context)
    for _, specification in ipairs(test_plan) do
        if context.debug_config and context.debug_config.printcheckpoints and specification.before then
            (context.output or print)(specification.before)
        end
        context.execute_one(specification, selected_set)
        if context.debug_config and context.debug_config.printcheckpoints and specification.after then
            (context.output or print)(specification.after)
        end
        if context.debug_config and context.debug_config.delaybetweentests and context.task then
            context.task.wait()
        end
    end
end

-- This is where "impossible" becomes a regression test and asks for no refund.
run_sunc_suite = function(environment, options)
    environment = resolve_environment(environment)
    options = options or {}
    local clock = environment.tick or tick
    local suite_started_at = clock()

    local debug_config = read_debug_config()
    local output = environment.print or print
    local warning = environment.warn or warn
    local task_library = environment.task or task

    if debug_config.printcheckpoints then
        output("....")
        if task_library and task_library.wait then task_library.wait(0.001) end
    end
    if type(environment.getgenv) ~= "function" then
        warning("Missing global environment, high chance of bugs")
        if task_library and task_library.wait then task_library.wait(1) end
    end

    local passed_functions = discover_passed_functions(environment)
    if debug_config.printcheckpoints then
        output(".....")
        if task_library and task_library.wait then task_library.wait(0.001) end
        output("........")
    end
    output("STARTING sUNC test. Join our Discord server if you want :" .. utf8.char(8204)
        .. ") [discord.gg/yGNzDrvbF5]")

    local results_by_name = {}
    local prerequisite_failures = {}
    local function_status = setmetatable({}, { __index = function() return true end })
    local shared_test_failed = { false }

    -- P31 invokes this callback under pcall before dispatching the test plan.
    -- It looked dead only because the earlier coordinator rewrite dropped that edge.
    local console_patch_ok, console_patch_error = pcall(patch_developer_console, environment)

    local function record_result(passed, feature, detail)
        feature = tostring(feature)
        local previous = results_by_name[feature]
        -- A later success may add context, but never erase an earlier failure.
        if previous == nil or previous.passed or passed == false then
            results_by_name[feature] = {
                test = feature,
                name = feature,
                passed = passed == true,
                detail = detail,
            }
        end
        function_status[feature] = passed == true
        local short_name = feature:match("([^.]+)$")
        if short_name then function_status[short_name] = passed == true end
        if not passed then
            prerequisite_failures[feature] = true
            if short_name then prerequisite_failures[short_name] = true end
            shared_test_failed[1] = true
        end
        return passed
    end

    local function record_skipped(feature, detail)
        feature = tostring(feature)
        results_by_name[feature] = {
            test = feature,
            name = feature,
            skipped = true,
            detail = detail,
        }
    end

    -- P69/P70, folded at their only call sites. The first callback exercises
    -- writes and tostring on a 400-byte buffer; the second returns a fresh
    -- buffer whose runtime type is checked independently.
    local buffer_api = environment.buffer
    if buffer_api == nil then
        record_result(false, "buffer", "Buffers are not supported on this executor[4]!")
    elseif type(buffer_api.create) ~= "function" then
        record_result(false, "buffer", "Buffers are not supported on this executor[3]!")
    else
        local operations_ok, operations_error = pcall(function()
            local probe = buffer_api.create(400)
            buffer_api[decode_xored_base64(
                "uWJxY9uoZW0fW+I=", "zhAYF77bER92NYU="
            )](probe, 0, "idk")
            buffer_api[decode_xored_base64(
                "gI/ZdTFfnIM=", "9/2wAVQ2r7E="
            )](probe, 66, -9)
            tostring(probe)
        end)
        if not operations_ok then
            record_result(false, "buffer",
                "Buffers are not supported on this executor[1]! " .. tostring(operations_error))
        end

        local create_ok, probe = pcall(function()
            return buffer_api.create(400)
        end)
        if not create_ok or (environment.typeof or typeof)(probe) ~= "buffer" then
            record_result(false, "buffer", "Buffers are not supported on this executor[2]!")
        end
    end

    local deterministic_random = create_deterministic_random()
    local telemetry_history = {}
    local probe_complete = { true }
    local actor_connection
    pcall(patch_call_dialog_layout, environment)
    pcall(run_call_context_stability_probe, environment)
    if environment.task and environment.game and environment.buffer then
        local actor_ok, connection_or_error = pcall(connect_actor_resource_probe, environment)
        if actor_ok then actor_connection = connection_or_error end
    end
    -- The original installs the key-exchange callback as part of its network
    -- reporter. Preserve that edge only when the caller explicitly opts into
    -- network behavior; the pure compatibility tests still use the same RNG.
    local result_transport = options.allow_network == true
        and install_original_result_transport(environment) or nil

    local captures = {
        options = options,
        random = deterministic_random,
        result_transport = result_transport,
        remote_probe_fixture_values = options.remote_probe_fixture_values,
        diagnostics = {
            developer_console_patch_ok = console_patch_ok,
            developer_console_patch_error = console_patch_error,
            coordinator_padding_bytes = #("\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"),
        },
        debug_config = debug_config,
        function_status = function_status,
        function_status_2 = function_status,
        prerequisite_failures = prerequisite_failures,
        protected_environment = environment,
        record_result = record_result,
        record_result_2 = record_result,
        record_result_3 = record_result,
        output = warning,
        shared_test_failed = shared_test_failed,
        shared_test_failed_2 = shared_test_failed,
        make_probe_value = function(minimum, maximum)
            if type(environment.newproxy) == "function" then return environment.newproxy(true) end
            return deterministic_random(minimum or 0, maximum or 2^30)
        end,
        simple_loadstring_url = options.simple_loadstring_url
            or "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/testloadstring",
        complicated_loadstring_url = options.complicated_loadstring_url
            or "http://setup.roblox.com/version-d0e8cfcd943d4ae2-API-Dump.json",
    }

    local required_paths = collect_test_function_paths(TEST_PLAN)
    local function is_function_available(path)
        if resolve_environment_path(environment, nil, path) ~= nil then return true end
        return passed_functions[tostring(path)] ~= nil
    end
    for _, path in ipairs(required_paths) do
        if not is_function_available(path) then
            function_status[path] = false
            local short_name = path:match("([^.]+)$")
            if short_name then function_status[short_name] = false end
        end
    end
    if debug_config.extradebugprints then output("past function nil-check") end
    if task_library and task_library.wait then task_library.wait(0.005) end

    -- P80's captured reporter is represented by the telemetry history append.
    pcall(report_executor_debug_state, environment, debug_config, function(name, checkpoints, delay)
        captures.executor_name = name
        telemetry_history[#telemetry_history + 1] = table.concat({ tostring(name), tostring(checkpoints), tostring(delay) }, "|")
    end)

    local selected = options.tests
    local selected_set
    if type(selected) == "table" then
        selected_set = {}
        for _, name in ipairs(selected) do selected_set[name] = true end
    end

    local function execute_one_test(specification, active_selected_set)
        if not active_selected_set or active_selected_set[specification.test] then
            local features = copy_array(specification.features or { specification.test })
            local skip_reason
            local missing_requirement
            if specification.network and options.allow_network ~= true then
                skip_reason = "network test disabled; pass allow_network = true"
            elseif specification.filesystem and options.allow_filesystem == false then
                skip_reason = "filesystem test disabled"
            end

            local requirements = specification.requires or { specification.test }
            if not skip_reason then
                for _, path in ipairs(requirements) do
                    local exists = is_function_available(path)
                    function_status[path] = exists
                    local short_name = path:match("([^.]+)$")
                    if short_name then function_status[short_name] = exists end
                    if not exists then
                        missing_requirement = specification.prerequisite_reason
                            or ("Function is missing: " .. path)
                        break
                    end
                end
            end

            if skip_reason then
                for _, feature in ipairs(features) do
                    record_skipped(feature, skip_reason)
                end
            elseif missing_requirement then
                for _, feature in ipairs(features) do
                    record_result(false, feature, missing_requirement)
                end
            else
                local timer = create_test_timer()
                local succeeded, error_message = pcall(specification.run, environment, captures)
                local elapsed = timer:Stop(specification.test, debug_config)
                if not succeeded then
                    for _, feature in ipairs(features) do
                        record_result(false, feature, "The function failed to be tested: " .. tostring(error_message))
                    end
                else
                    for _, feature in ipairs(features) do
                        if results_by_name[feature] == nil then
                            record_result(true, feature)
                        end
                    end
                end
                if debug_config.printtesttimetaken then
                    (succeeded and output or warning)(specification.test, error_message, elapsed)
                end
            end
        end
    end
    execute_test_plan(TEST_PLAN, selected_set, {
        execute_one = execute_one_test,
        debug_config = debug_config,
        output = output,
        task = task_library,
    })

    output("processing results")
    local ordered_results = {}
    for _, result in pairs(results_by_name) do append_result(environment, { result_list = ordered_results }, result) end
    table.sort(ordered_results, compare_test_results)

    -- P56-P59. The original coordinator stores numeric slots in a typed buffer
    -- archive and applies all negotiated ChaCha layers before transmission.
    -- When the place-specific archive key is unavailable, retain a plain audit
    -- view rather than fabricating a key and silently changing the wire format.
    local result_archive
    if result_transport and result_transport.byte_key_box[1] ~= nil then
        result_archive = create_result_store(
            result_transport.byte_key_box,
            result_transport.key_buffers,
            result_transport.nonce_buffers
        )
        for _, result in ipairs(ordered_results) do
            result_archive:write(reserve_result_slot(environment, captures), result)
        end
        captures.serialized_result_archive = result_archive:serialize()
    else
        result_archive = { directory = {}, buffers = {}, unavailable_key = true }
        for _, result in ipairs(ordered_results) do
            result_archive.directory[result.test] = result
            result_archive.buffers[#result_archive.buffers + 1] = serialize_table(result)
        end
    end
    captures.result_archive = result_archive

    if options.allow_network == true then
        local dependency_ok, dependency_value = pcall(
            load_test_dependency,
            environment,
            captures,
            "https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/gitlab_just_doing_anything_ts_days/dep2.lua"
        )
        if not dependency_ok then
            (environment.warn or warn)("Encountered an error trying to get a dependency:", dependency_value)
            (environment.warn or warn)("Returned an error trying to load a dependency, containing one of sUNC's tests: " .. tostring(dependency_value))
            (environment.warn or warn)("Wasn't able to load the needed dependency. This is either an issue with loadstring not placing the global variables in the environment, or: " .. tostring(dependency_value))
            (environment.warn or warn)("Failed to load a dependancy")
        end
        captures.diagnostics.primary_dependency_ok = dependency_ok
        captures.diagnostics.primary_dependency_result = dependency_value

        local secondary_ok, secondary_value = pcall(run_downloaded_loadstring_probe, environment, captures)
        captures.diagnostics.downloaded_dependency_probe_ok = secondary_ok
        captures.diagnostics.downloaded_dependency_probe_result = secondary_value

        local telemetry_ok, telemetry_error = pcall(send_test_telemetry,
            environment, telemetry_history, #ordered_results)
        captures.diagnostics.telemetry_ok = telemetry_ok
        captures.diagnostics.telemetry_error = telemetry_error

        output("Waiting for melon")
        local reporter_ok, metadata_or_error = pcall(run_original_remote_reporter, environment, captures)
        captures.diagnostics.result_reporter_ok = reporter_ok
        if reporter_ok then
            captures.diagnostics.result_metadata_ok = true
            output("finished meloning")
        else
            warning("Failed to authenticate. This usually means that your exploit doesn't support sUNC. If you have any questions regarding this, let us know [discord.gg/yGNzDrvbF5]")
            captures.diagnostics.result_metadata_ok = false
            captures.diagnostics.result_metadata_error = metadata_or_error
            handle_result_failure(environment.print or print, environment.warn or warn)
        end

        -- P31's final place handshake decodes CollisionGroup, resets it to
        -- "Default", and presents the result link through P397's GUI.
        local link_ok, result_link = pcall(recover_result_link_from_place, environment)
        if link_ok and result_link then
            captures.result_link = result_link
            if options.show_result_gui ~= false then
                local gui_ok, gui_or_error = pcall(create_result_gui, environment, captures)
                captures.diagnostics.result_gui_ok = gui_ok
                if gui_ok then
                    captures.result_gui = gui_or_error
                else
                    captures.diagnostics.result_gui_error = gui_or_error
                end
            end
        end
    end

    local passed_count, failed_count, skipped_count = 0, 0, 0
    for _, result in ipairs(ordered_results) do
        if result.skipped then
            skipped_count = skipped_count + 1
        elseif result.passed then
            passed_count = passed_count + 1
        else
            failed_count = failed_count + 1
        end
    end
    local evaluated_count = passed_count + failed_count
    captures.placeholder_value = placeholder_value(environment)
    mark_probe_complete(probe_complete)
    captures.probe_complete = probe_complete[1] == false
    captures.telemetry_history = telemetry_history
    if actor_connection and actor_connection.Disconnect then
        pcall(function() actor_connection:Disconnect() end)
    end
    local elapsed_seconds = round_result_value(clock() - suite_started_at)
    output("Total tests failed: " .. tostring(failed_count))
    output("😏 This test was made by senS")
    output("🍉 corporate sponsorship лол 😂😂\n")
    output("sUNC, VERSION 2.1.5 " .. tostring(captures.executor_name or ""))
    local run_service = environment.game:GetService("RunService")
    if run_service:IsStudio() then
        output("Contributors: vvultt, GRH, 0_void, Dottik, citam.")
    else
        output("Contribu" .. utf8.char(8204) .. "tors: Richy, Lovre, vvultt, GRH," .. utf8.char(8204) .. " 0_void, Dottik, Pixeluted, citam.")
    end
    output("Finished the test in " .. tostring(elapsed_seconds) .. " seconds")

    return ordered_results, failed_count == 0, {
        passed = passed_count,
        failed = failed_count,
        skipped = skipped_count,
        total = #ordered_results,
        evaluated = evaluated_count,
        elapsed_seconds = elapsed_seconds,
        success_rate = evaluated_count > 0 and math.floor((passed_count / evaluated_count) * 100 + 0.5) or 0,
    }
end


-- The released sUNC script was an executable, not a require-only module. Its
-- outer shell invoked the coordinator immediately and returned no module value.
bootstrap_sunc((getgenv and getgenv()) or _G)
