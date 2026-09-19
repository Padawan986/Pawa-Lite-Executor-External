-- create root

-- executor environment version marker (bump on every init.luau change)
__FUNNY_VERSION = "r11"

local folder = Instance.new("Folder")
folder.Name = "_pawalite"

local upd = Instance.new("BoolValue")
upd.Name = "UpdateIndicator"
upd.Parent = folder

folder.Parent = game.CoreGui

-- vars
local http_service = game.HttpService
local lastValue = upd.Value
local bridgeServer = 'http://localhost:9475'

-- modules

local lz4 do
	local module = {}

	type Streamer = {
		Offset: number,
		Source: string,
		Length: number,
		IsFinished: boolean,
		LastUnreadBytes: number,

		read: (Streamer, len: number?, shiftOffset: boolean?) -> string,
		seek: (Streamer, len: number) -> (),
		append: (Streamer, newData: string) -> (),
		toEnd: (Streamer) -> ()
	}

	type BlockData = {
		[number]: {
			Literal: string,
			LiteralLength: number,
			MatchOffset: number?,
			MatchLength: number?
		}
	}

	local function plainFind(str, pat)
		return string.find(str, pat, 0, true)
	end

	local function streamer(str): Streamer
		local Stream = {}
		Stream.Offset = 0
		Stream.Source = str
		Stream.Length = string.len(str)
		Stream.IsFinished = false
		Stream.LastUnreadBytes = 0

		function Stream.read(self: Streamer, len: number?, shift: boolean?): string
			local len = len or 1
			local shift = if shift ~= nil then shift else true
			local dat = string.sub(self.Source, self.Offset + 1, self.Offset + len)

			local dataLength = string.len(dat)
			local unreadBytes = len - dataLength

			if shift then
				self:seek(len)
			end

			self.LastUnreadBytes = unreadBytes
			return dat
		end

		function Stream.seek(self: Streamer, len: number)
			local len = len or 1

			self.Offset = math.clamp(self.Offset + len, 0, self.Length)
			self.IsFinished = self.Offset >= self.Length
		end

		function Stream.append(self: Streamer, newData: string)
			-- adds new data to the end of a stream
			self.Source ..= newData
			self.Length = string.len(self.Source)
			self:seek(0) --hacky but forces a recalculation of the isFinished flag
		end

		function Stream.toEnd(self: Streamer)
			self:seek(self.Length)
		end

		return Stream
	end

	function module.compress(str: string): string
		local blocks: BlockData = {}
		local iostream = streamer(str)

		if iostream.Length > 12 then
			local firstFour = iostream:read(4)

			local processed = firstFour
			local lit = firstFour
			local match = ""
			local LiteralPushValue = ""
			local pushToLiteral = true

			repeat
				pushToLiteral = true
				local nextByte = iostream:read()

				if plainFind(processed, nextByte) then
					local next3 = iostream:read(3, false)

					if string.len(next3) < 3 then
						--push bytes to literal block then break
						LiteralPushValue = nextByte .. next3
						iostream:seek(3)
					else
						match = nextByte .. next3

						local matchPos = plainFind(processed, match)
						if matchPos then
							iostream:seek(3)
							repeat
								local nextMatchByte = iostream:read(1, false)
								local newResult = match .. nextMatchByte

								local repos = plainFind(processed, newResult)
								if repos then
									match = newResult
									matchPos = repos
									iostream:seek(1)
								end
							until not plainFind(processed, newResult) or iostream.IsFinished

							local matchLen = string.len(match)
							local pushMatch = true

							if iostream.Length - iostream.Offset <= 5 then
								LiteralPushValue = match
								pushMatch = false
								--better safe here, dont bother pushing to match ever
							end

							if pushMatch then
								pushToLiteral = false

								-- gets the position from the end of processed, then slaps it onto processed
								local realPosition = string.len(processed) - matchPos
								processed = processed .. match

								table.insert(blocks, {
									Literal = lit,
									LiteralLength = string.len(lit),
									MatchOffset = realPosition + 1,
									MatchLength = matchLen,
								})
								lit = ""
							end
						else
							LiteralPushValue = nextByte
						end
					end
				else
					LiteralPushValue = nextByte
				end

				if pushToLiteral then
					lit = lit .. LiteralPushValue
					processed = processed .. nextByte
				end
			until iostream.IsFinished
			table.insert(blocks, {
				Literal = lit,
				LiteralLength = string.len(lit)
			})
		else
			local str = iostream.Source
			blocks[1] = {
				Literal = str,
				LiteralLength = string.len(str)
			}
		end

		-- generate the output chunk
		-- %s is for adding header
		local output = string.rep("\x00", 4)
		local function write(char)
			output = output .. char
		end
		-- begin working through chunks
		for chunkNum, chunk in blocks do
			local litLen = chunk.LiteralLength
			local matLen = (chunk.MatchLength or 4) - 4

			-- create token
			local tokenLit = math.clamp(litLen, 0, 15)
			local tokenMat = math.clamp(matLen, 0, 15)

			local token = bit32.lshift(tokenLit, 4) + tokenMat
			write(string.pack("<I1", token))

			if litLen >= 15 then
				litLen = litLen - 15
				--begin packing extra bytes
				repeat
					local nextToken = math.clamp(litLen, 0, 0xFF)
					write(string.pack("<I1", nextToken))
					if nextToken == 0xFF then
						litLen = litLen - 255
					end
				until nextToken < 0xFF
			end

			-- push raw lit data
			write(chunk.Literal)

			if chunkNum ~= #blocks then
				-- push offset as u16
				write(string.pack("<I2", chunk.MatchOffset))

				-- pack extra match bytes
				if matLen >= 15 then
					matLen = matLen - 15

					repeat
						local nextToken = math.clamp(matLen, 0, 0xFF)
						write(string.pack("<I1", nextToken))
						if nextToken == 0xFF then
							matLen = matLen - 255
						end
					until nextToken < 0xFF
				end
			end
		end
		--append chunks
		local compLen = string.len(output) - 4
		local decompLen = iostream.Length

		return string.pack("<I4", compLen) .. string.pack("<I4", decompLen) .. output
	end

	function module.decompress(lz4data: string): string
		local inputStream = streamer(lz4data)

		local compressedLen = string.unpack("<I4", inputStream:read(4))
		local decompressedLen = string.unpack("<I4", inputStream:read(4))
		local reserved = string.unpack("<I4", inputStream:read(4))

		if compressedLen == 0 then
			return inputStream:read(decompressedLen)
		end

		local outputStream = streamer("")

		repeat
			local token = string.byte(inputStream:read())
			local litLen = bit32.rshift(token, 4)
			local matLen = bit32.band(token, 15) + 4

			if litLen >= 15 then
				repeat
					local nextByte = string.byte(inputStream:read())
					litLen += nextByte
				until nextByte ~= 0xFF
			end

			local literal = inputStream:read(litLen)
			outputStream:append(literal)
			outputStream:toEnd()
			if outputStream.Length < decompressedLen then
				--match
				local offset = string.unpack("<I2", inputStream:read(2))
				if matLen >= 19 then
					repeat
						local nextByte = string.byte(inputStream:read())
						matLen += nextByte
					until nextByte ~= 0xFF
				end

				outputStream:seek(-offset)
				local pos = outputStream.Offset
				local match = outputStream:read(matLen)
				local unreadBytes = outputStream.LastUnreadBytes
				local extra
				if unreadBytes then
					repeat
						outputStream.Offset = pos
						extra = outputStream:read(unreadBytes)
						unreadBytes = outputStream.LastUnreadBytes
						match ..= extra
					until unreadBytes <= 0
				end

				outputStream:append(match)
				outputStream:toEnd()
			end

		until outputStream.Length >= decompressedLen

		return outputStream.Source
	end

	lz4 = module
end

-- funcs

local function requestData()
	local result, success = nil

	local exists, _ = pcall(function()
		http_service:RequestInternal({
			Url = bridgeServer,
			Method = "GET",
			Headers = {
				['Content-Type'] = "text/plain"
			}
		}):Start(function(s,b)
			result = b
			result['Success'] = s
		end)
	end)

	if not exists then
		result = {
			Success = true,
			Body = workspace.Fallback.Value
		}
	end

	repeat task.wait() until result

	if not result or not result.Success then
		warn('Pawa-Lite(Beta)V2 -- request error')
		return nil
	end

	return result and result.Body or ""
end

local function send_method(method, ...)
	local result, success = nil

	local body = table.concat({method, ...}, '\n')

	local exists, _ = pcall(function()
		http_service:RequestInternal({
			Url = bridgeServer,
			Method = "POST",
			Body = body,
			Headers = {
				['Content-Type'] = "text/plain"
			}
		}):Start(function(s,b)
			result = b
			result['Success'] = s
		end)
	end)

	if not exists then
		result = {
			Success = true,
			Body = workspace.Fallback.Value
		}
	end

	repeat task.wait() until result

	if not result or not result.Success then
		warn('Pawa-Lite(Beta)V2 -- request error')
		return nil
	end

	return result and result.Body or ""
end

-- unc functions

local executor_env = getfenv()

local genv_table = {}
setmetatable(genv_table, { __index = executor_env, __newindex = executor_env })

getgenv = function()
	return genv_table
end

-- thread identity state (declared early: the game wrapper enforces it)
local current_identity = 8

-- readonly tracking (declared early: the game wrapper marks its metatable)
local readonly_tables = {}
setmetatable(readonly_tables, { __mode = 'k' })
local readonly_installed_meta = {}
setmetatable(readonly_installed_meta, { __mode = 'k' })

-- game:HttpGet()

local game_o = game
game = {
	HttpGet = function(self, url)
		local result = nil

		local started = pcall(function()
			http_service:RequestInternal({
				Url = url,
				Method = "GET",
				Headers = {
					['Content-Type'] = "text/plain"
				}
			}):Start(function(s,b)
				result = b
				result['Success'] = s
			end)
		end)

		if started then
			local deadline = os.clock() + 15
			repeat task.wait() until result or os.clock() > deadline
		end

		if result and result.Success then
			return result.Body or ""
		end

		-- fallback: fetch through the Python bridge (works when client HTTP is restricted)
		local ok, body = pcall(send_method, 'httpget', url)
		if ok and type(body) == 'string' and body ~= '' and body ~= 'fail' then
			return body
		end

		warn('Pawa-Lite(Beta)V2 -- request error')
		return nil
	end
}
game.HttpGetAsync = game.HttpGet

local game_wrappers = {}
local game_metamethod_hooks = {}
local current_namecall = {}
setmetatable(current_namecall, { __mode = 'k' })

local game_mt = {
	__index = function(_, key)
		local index_hook = game_metamethod_hooks['__index']
		if index_hook ~= nil then
			return index_hook(game, key)
		end

		-- thread-identity enforcement: only identity 8+ can see CoreGui,
		-- matching engine security (setthreadidentity(2) hides it)
		if key == "CoreGui" and current_identity < 8 then
			return nil
		end

		local value = game_o[key]

		if type(value) == "function" then
			local cached = game_wrappers[key]
			if not cached then
				cached = function(_, ...)
					if key == "GetService" and current_identity < 8 then
						local first = ...
						if first == "CoreGui" then
							return nil
						end
					end
					current_namecall[coroutine.running()] = key
					local namecall_hook = game_metamethod_hooks['__namecall']
					if namecall_hook ~= nil then
						return namecall_hook(game, ...)
					end
					return value(game_o, ...)
				end
				game_wrappers[key] = cached
			end
			return cached
		end

		return value
	end,

	__newindex = function(_, key, value)
		local newindex_hook = game_metamethod_hooks['__newindex']
		if newindex_hook ~= nil then
			newindex_hook(game, key, value)
			return
		end
		game_o[key] = value
	end,

	__tostring = function()
		return tostring(game_o)
	end
}

setmetatable(game, game_mt)

-- mark the wrapper metatable read-only in our own registry (a real freeze
-- would be intercepted by the fiu freeze-snoop and break dispatch);
-- this makes isreadonly(getrawmetatable(game)) true per the sUNC contract
readonly_tables[game_mt] = true

table.freeze(game)

-- base64encode/base64decode

local b64_alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64_codes = {string.byte(b64_alphabet, 1, 64)}

local b64_lookup = {}
for i = 1, #b64_alphabet do
	b64_lookup[string.byte(b64_alphabet, i)] = i - 1
end

function base64encode(data)
	local len = #data
	if len == 0 then
		return ''
	end

	local src = buffer.fromstring(data)
	local out = buffer.create(math.ceil(len / 3) * 4)
	local o = 0

	local i = 1
	while i + 2 <= len do
		local n = buffer.readu8(src, i - 1) * 65536 + buffer.readu8(src, i) * 256 + buffer.readu8(src, i + 1)
		buffer.writeu8(out, o, b64_codes[bit32.rshift(n, 18) + 1])
		buffer.writeu8(out, o + 1, b64_codes[bit32.band(bit32.rshift(n, 12), 63) + 1])
		buffer.writeu8(out, o + 2, b64_codes[bit32.band(bit32.rshift(n, 6), 63) + 1])
		buffer.writeu8(out, o + 3, b64_codes[bit32.band(n, 63) + 1])
		o += 4
		i += 3
	end

	local rest = len - i + 1
	if rest == 1 then
		local n = buffer.readu8(src, i - 1)
		buffer.writeu8(out, o, b64_codes[bit32.rshift(n, 2) + 1])
		buffer.writeu8(out, o + 1, b64_codes[bit32.band(bit32.lshift(n, 4), 63) + 1])
		buffer.writeu8(out, o + 2, 61)
		buffer.writeu8(out, o + 3, 61)
	elseif rest == 2 then
		local n = buffer.readu8(src, i - 1) * 256 + buffer.readu8(src, i)
		buffer.writeu8(out, o, b64_codes[bit32.rshift(n, 10) + 1])
		buffer.writeu8(out, o + 1, b64_codes[bit32.band(bit32.rshift(n, 4), 63) + 1])
		buffer.writeu8(out, o + 2, b64_codes[bit32.band(bit32.lshift(n, 2), 63) + 1])
		buffer.writeu8(out, o + 3, 61)
	end

	return buffer.tostring(out)
end

function base64decode(data)
	local len = #data
	if len == 0 then
		return ''
	end

	local padding = 0
	while padding < 2 and string.byte(data, len - padding) == 61 do
		padding += 1
	end

	local stripped = len - padding
	local tail = stripped % 4
	local out = buffer.create(stripped // 4 * 3 + (tail == 2 and 1 or tail == 3 and 2 or 0))
	local o = 0

	local src = buffer.fromstring(data)
	local i = 0
	while i + 4 <= stripped do
		local a = b64_lookup[buffer.readu8(src, i)] or 0
		local b = b64_lookup[buffer.readu8(src, i + 1)] or 0
		local c = b64_lookup[buffer.readu8(src, i + 2)] or 0
		local d = b64_lookup[buffer.readu8(src, i + 3)] or 0
		buffer.writeu8(out, o, bit32.band(bit32.lshift(a, 2) + bit32.rshift(b, 4), 255))
		buffer.writeu8(out, o + 1, bit32.band(bit32.lshift(b, 4) + bit32.rshift(c, 2), 255))
		buffer.writeu8(out, o + 2, bit32.band(bit32.lshift(c, 6) + d, 255))
		o += 3
		i += 4
	end

	if tail == 2 then
		local a = b64_lookup[buffer.readu8(src, i)] or 0
		local b = b64_lookup[buffer.readu8(src, i + 1)] or 0
		buffer.writeu8(out, o, bit32.band(bit32.lshift(a, 2) + bit32.rshift(b, 4), 255))
	elseif tail == 3 then
		local a = b64_lookup[buffer.readu8(src, i)] or 0
		local b = b64_lookup[buffer.readu8(src, i + 1)] or 0
		local c = b64_lookup[buffer.readu8(src, i + 2)] or 0
		buffer.writeu8(out, o, bit32.band(bit32.lshift(a, 2) + bit32.rshift(b, 4), 255))
		buffer.writeu8(out, o + 1, bit32.band(bit32.lshift(b, 4) + bit32.rshift(c, 2), 255))
	end

	return buffer.tostring(out)
end

crypt = {}
crypt.base64encode = base64encode
crypt.base64decode = base64decode

crypt.generatekey = function(len)
	len = len or 32
	local bytes = table.create(len)
	for i = 1, len do
		bytes[i] = math.random(0, 255)
	end
	return base64encode(string.char(table.unpack(bytes, 1, len)))
end

crypt.generatebytes = crypt.generatekey
crypt.random = crypt.generatekey

crypt.base64 = { encode = base64encode, decode = base64decode }
crypt.base64_encode = base64encode
crypt.base64_decode = base64decode
base64 = { encode = base64encode, decode = base64decode }
base64_encode = base64encode
base64_decode = base64decode

crypt.encrypt = function(data, key)
	data = tostring(data)
	key = tostring(key)
	local result = table.create(#data)
	for i = 1, #data do
		result[i] = string.char(bit32.bxor(string.byte(data, i), string.byte(key, (i - 1) % #key + 1)))
	end
	return table.concat(result), key
end

crypt.decrypt = crypt.encrypt

crypt.hash = function(data, hash_name)
	assert(type(data) == 'string', "invalid argument #1 to 'crypt.hash' (string expected, got " .. type(data) .. ')', 2)
	assert(type(hash_name) == 'string', "invalid argument #2 to 'crypt.hash' (string expected, got " .. type(hash_name) .. ')', 2)

	local response = send_method('hash', hash_name, base64encode(data))
	if response == 'fail' then
		return nil
	end
	return response
end

-- lz4compress/lz4decompress

lz4compress = lz4.compress
lz4decompress = lz4.decompress

-- loadstring

loadstring = function(source, chunkname)
	local ok, result = pcall(function()
		assert(type(source) == 'string', "invalid argument #1 to 'loadstring' (string expected, got " .. type(source) .. ')')
		-- fast path: raw source over the wire, raw bytecode back (no base64
		-- codecs on either side, which dominate load time on big payloads)
		local response = send_method('compile_raw', source)
		if type(response) ~= 'string' or response == '' or response:sub(1, 4) == 'fail' then
			-- legacy path (base64 round-trip)
			response = send_method('compile', base64encode(source))
			assert(type(response) == 'string' and response:sub(1, 4) ~= 'fail', 'compile error')
			response = base64decode(response)
		end
		local func = load_bytecode(response, getfenv())
		assert(type(func) == 'function', 'compile error')
		return func
	end)
	if ok then
		return result
	end
	local name = chunkname ~= nil and tostring(chunkname) or 'loadstring'
	return nil, '[string "' .. name .. '"]: ' .. tostring(result)
end

-- file api

local blocked_extensions = {".exe", ".scr", ".bat", ".com", ".csh", ".msi", ".vb", ".vbs",
	".vbe", ".ws", ".wsf", ".wsh", ".ps1", ".py", ".apk", ".pif", ".cpl", ".msc",
	".jar", ".cmd", ".hta", ".gadget", ".inf", ".ins", ".isp", ".psd1", ".psm1",
	".reg", ".scf", ".shb", ".sys", ".js", ".jse", ".lnk", ".msp",
	".zip", ".rar", ".7z", ".tar", ".gz", ".cab", ".iso", ".img",
	".dll", ".ocx", ".drv", ".vxd", ".xml", ".ini", ".cpp", ".c", ".url", ".uri",
	".deb", ".rpm", ".sh", ".bash", ".zsh", ".fish", ".npm"}

local function isBlockedExtension(path: string): boolean
	-- windows strips trailing dots/spaces, so "file.exe " counts as ".exe"
	local name = (path:lower():gsub("[%s.]+$", ""))
	for _, ext in blocked_extensions do
		if name:sub(-#ext) == ext then
			return true
		end
	end
	return false
end

writefile = function(path, content)
	if isBlockedExtension(path) then
		warn('Pawa-Lite(Beta)V2 -- writefile blocked: ' .. path)
		return
	end
	-- content is base64'd in transit so newlines and binary bytes survive the bridge protocol
	local response = send_method('writefile', path, base64encode(content))
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
	end
end

appendfile = function(path, content)
	if isBlockedExtension(path) then
		warn('Pawa-Lite(Beta)V2 -- appendfile blocked: ' .. path)
		return
	end
	local response = send_method('appendfile', path, base64encode(content))
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
	end
end

readfile = function(path)
	local response = send_method('readfile', path)
	if response == 'fail' or type(response) ~= 'string' then
		error('Pawa-Lite(Beta)V2 -- file error: unable to read \'' .. tostring(path) .. '\'', 2)
	end
	return base64decode(response)
end

isfile = function(path)
	local response = send_method('isfile', path)
	if response ~= 'true' and response ~= 'false' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
	end
	return response == 'true'
end

isfolder = function(path)
	local response = send_method('isfolder', path)
	if response ~= 'true' and response ~= 'false' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
		return nil
	end
	return response == 'true'
end

delfile = function(path)
	local response = send_method('delfile', path)
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
	end
end

delfolder = function(path)
	local response = send_method('delfolder', path)
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
	end
end

makefolder = function(path)
	local response = send_method('makefolder', path)
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- file error: '..tostring(response))
	end
end

listfiles = function(path)
	local response = send_method('listfiles', path)
	if response == 'fail' then
		warn('Pawa-Lite(Beta)V2 -- listfiles: folder not found: ' .. tostring(path))
		return {}
	end
	if response == '' then
		return {}
	end
	return response:split('\n')
end

-- loadfile

loadfile = function(path: string)
	local read_ok, content = pcall(readfile, path)
	if not read_ok or not content then
		return nil, 'Pawa-Lite(Beta)V2 -- loadfile: unable to read \'' .. tostring(path) .. '\''
	end

	local ok, result = pcall(loadstring, content)
	if not ok or result == nil then
		return nil, 'Pawa-Lite(Beta)V2 -- loadfile: ' .. tostring(result)
	end

	return result
end

-- setfpscap

setfpscap = function(fps: number)
	if type(fps) ~= 'number' then
		error('setfpscap expects a number', 2)
	end

	local response = send_method('setfpscap', tostring(math.floor(fps + 0.5)))
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- setfpscap failed: ' .. tostring(fps))
	end
end

getfpscap = function()
	local response = send_method('getfpscap')
	local cap = tonumber(response)
	if not cap then
		warn('Pawa-Lite(Beta)V2 -- getfpscap failed')
		return nil
	end
	return cap
end

local function pointer_request(method_name, script)
	local holder = Instance.new('ObjectValue')
	holder.Name = http_service:GenerateGUID(false)
	holder.Value = script
	holder.Parent = folder

	local response = send_method(method_name, holder.Name)
	holder:Destroy()

	return response
end

getscriptbytecode = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'getscriptbytecode' (LuaSourceContainer expected, got " .. typeof(script) .. ')', 2)

	local response = pointer_request('getscriptbytecode', script)
	if not response or response == 'fail' or response == '' then
		return nil
	end
	return base64decode(response)
end

dumpstring = getscriptbytecode

getscripthash = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'getscripthash' (LuaSourceContainer expected, got " .. typeof(script) .. ')', 2)

	local response = pointer_request('getscripthash', script)
	if not response or response == 'fail' then
		return nil
	end
	return response
end

-- clipboard

setclipboard = function(content)
	local response = send_method('setclipboard', base64encode(tostring(content)))
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- clipboard error: '..tostring(response))
		return false
	end
	return true
end

getclipboard = function()
	local response = send_method('getclipboard')
	return response
end

toclipboard = setclipboard

local input_methods = {
	mouse1click = 'mouse1click',
	mouse2click = 'mouse2click',
	middleclick = 'middleclick',
	mouse1press = 'mouse1down',
	mouse1release = 'mouse1up',
	mouse2press = 'mouse2down',
	mouse2release = 'mouse2up',
	middlepress = 'middledown',
	middlerelease = 'middleup',
	movemouse = 'movemouse',
	mousemoveabs = 'mousemoveabs',
	mouserel = 'movemouserel',
	mousemoverel = 'movemouserel',
	keyclick = 'keyclick',
	keypress = 'keypress',
	keyrelease = 'keyrelease',
}

for name, method in input_methods do
	_G[name] = function(...)
		local response = send_method(method, ...)
		if response == 'fail' then
			warn('Pawa-Lite(Beta)V2 -- input error: ' .. name)
		end
	end
end

getmousepos = function()
	local response = send_method('getmousepos')
	local x, y = response:match('^(%-?%d+),(%-?%d+)$')
	if not x then
		return nil, nil
	end
	return tonumber(x), tonumber(y)
end

getmouselocation = getmousepos

iswindowactive = function()
	return send_method('iswindowactive') == 'true'
end

isrbxactive = iswindowactive

messagebox = function(text, title, flags)
	local response = send_method('messagebox', base64encode(tostring(text)), base64encode(tostring(title or 'Pawa-Lite(Beta)V2')), tostring(flags or 0))
	return tonumber(response)
end

-- identifyexecutor

identifyexecutor = function()
	return 'Pawa-Lite(Beta)V2', 'v2.0'
end

getexecutorname = function()
	return identifyexecutor()
end

getexecutorversion = function()
	return select(2, identifyexecutor())
end

-- executor env extensions

local executor_closures = {}
setmetatable(executor_closures, {__mode = 'k'})

-- functions masquerading as C closures (newcclosure results)
local cclosure_marks = {}
setmetatable(cclosure_marks, {__mode = 'k'})

islclosure = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'islclosure' (function expected, got " .. type(func) .. ')', 2)
	if cclosure_marks[func] then
		return false
	end
	return debug.info(func, 's') ~= '[C]'
end

isluaclosure = islclosure

iscclosure = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'iscclosure' (function expected, got " .. type(func) .. ')', 2)
	if cclosure_marks[func] then
		return true
	end
	return debug.info(func, 's') == '[C]'
end

newcclosure = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'newcclosure' (function expected, got " .. type(func) .. ')', 2)
	-- plain forwarder (NOT coroutine-based): yields propagate naturally,
	-- args/returns forward exactly; C-closure status comes from the marks set
	local wrapped = function(...)
		return func(...)
	end
	executor_closures[wrapped] = true
	cclosure_marks[wrapped] = true
	return wrapped
end

clonefunction = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'clonefunction' (function expected, got " .. type(func) .. ')', 2)
	if iscclosure(func) then
		return newcclosure(func)
	end
	-- route through the true original so hooking the source never affects the clone
	return function(...)
		if type(fiu_debug) == 'table' and type(fiu_debug.calloriginal) == 'function' then
			return fiu_debug.calloriginal(func, ...)
		end
		return func(...)
	end
end

isexecutorclosure = function(func)
	if type(func) ~= 'function' then
		error("invalid argument #1 to 'isexecutorclosure' (function expected, got " .. type(func) .. ')', 2)
	end

	if executor_closures[func] then
		return true
	end

	if iscclosure(func) then
		return debug.info(func, 'n') == ''
	end

	local ok, fenv = pcall(getfenv, func)
	if not ok then
		return false
	end

	if typeof(fenv.script) ~= 'Instance' then
		return true
	end

	if fenv.script.Name == 'AvatarEditorPrompts' or fenv.script.Name == 'JestGlobals' then
		return false
	end

	if fenv.script.Parent == nil then
		return true
	end

	if fenv == getfenv(0) then
		return true
	end

	return true
end

checkclosure = isexecutorclosure
isourclosure = isexecutorclosure

-- cloneref / compareinstances

local clonerefs = {}
setmetatable(clonerefs, {__mode = 'k'})

	cloneref = function(obj)
	local proxy = newproxy(true)
	local meta = getmetatable(proxy)	meta.__index = function(t, n)
		local v = obj[n]
		if typeof(v) == 'function' then
			return function(self, ...)
				if self == t then
					self = obj
				end
				return v(self, ...)
			end
		end
		return v
	end
	meta.__newindex = function(_, n, v)
		obj[n] = v
	end
	meta.__tostring = function()
		return tostring(obj)
	end
	local ok_mt, obj_mt = pcall(getmetatable, obj)
	meta.__metatable = (ok_mt and obj_mt or nil)
	clonerefs[proxy] = obj
	return proxy
end

compareinstances = function(a, b)
	assert(type(a) == 'userdata' or type(a) == 'table', "invalid argument #1 to 'compareinstances' (Instance expected, got " .. typeof(a) .. ')', 2)
	assert(type(b) == 'userdata' or type(b) == 'table', "invalid argument #2 to 'compareinstances' (Instance expected, got " .. typeof(b) .. ')', 2)
	if clonerefs[a] then
		a = clonerefs[a]
	end
	if clonerefs[b] then
		b = clonerefs[b]
	end
	return a == b
end

-- report cloneref proxies as Instances (what sunc checks for)

local rtypeof = typeof
typeof = function(obj)
	if clonerefs[obj] then
		return 'Instance'
	end
	return rtypeof(obj)
end

-- getnamecallmethod (error-probe technique, ported from the reference env)

local function generate_error(object)
	local _, err = xpcall(function()
		object:__namecall()
	end, function()
		return debug.info(2, 'f')
	end)
	return err
end

local first_probe = generate_error(OverlapParams.new())
local second_probe = generate_error(Color3.new())

local cached_methods = {}
setmetatable(cached_methods, {__mode = 'k'})

local bootstrap_getnamecallmethod = getnamecallmethod

getnamecallmethod = function()
	local thread = coroutine.running()

	-- set by the bootstrap's namecall handler (reliable for any __namecall proxy)
	if bootstrap_getnamecallmethod then
		local registered = bootstrap_getnamecallmethod()
		if registered then
			return registered
		end
	end

	-- set by our game-wrapper method dispatch (reliable for game:Method() calls)
	local tracked = current_namecall[thread]
	if tracked then
		return tracked
	end

	local method = nil

	local _, err = pcall(first_probe)
	if type(err) == 'string' then
		method = err:match('^(.+) is not a valid member of %w+$')
	end

	if not method then
		_, err = pcall(second_probe)
		if type(err) == 'string' then
			method = err:match('^(.+) is not a valid member of %w+$')
		end
	end

	if not method or method == '__namecall' then
		return cached_methods[coroutine.running()]
	end

	cached_methods[coroutine.running()] = method
	return method
end

-- gethui (created lazily, only when first called)

local hidden_ui = nil

gethui = function()
	if hidden_ui and hidden_ui.Parent then
		return hidden_ui
	end

	local ok, gui = pcall(function()
		local screen_gui = Instance.new('ScreenGui')
		screen_gui.Name = 'RobloxUi'
		screen_gui.ResetOnSpawn = false
		screen_gui.DisplayOrder = 999999
		screen_gui.IgnoreGuiInset = true
		screen_gui.Parent = game_o:GetService('CoreGui')
		return screen_gui
	end)

	if ok then
		hidden_ui = gui
	end

	return hidden_ui
end

local drawing_objects = setmetatable({}, {__mode = 'k'})

local function safe_font(name)
	local ok, font = pcall(function()
		return Enum.Font[name]
	end)
	if ok and font then
		return font
	end
	return Enum.Font.SourceSans
end

local draw_fonts = {
	[0] = safe_font('SourceSans'),
	[1] = safe_font('SourceSansBold'),
	[2] = safe_font('Plex'),
	[3] = safe_font('Code'),
}

local function resolve_font(font)
	if type(font) == 'number' then
		return draw_fonts[font] or Enum.Font.SourceSans
	elseif type(font) == 'string' then
		local ok, resolved = pcall(function()
			return Enum.Font[font]
		end)
		if ok and resolved then
			return resolved
		end
		return Enum.Font.SourceSans
	end
	return font or Enum.Font.SourceSans
end

local function draw_alpha(transparency)
	return math.clamp(1 - transparency, 0, 1)
end

local function style_line_frame(frame, state)
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = state.Color
	frame.BackgroundTransparency = draw_alpha(state.Transparency)
	frame.ZIndex = state.ZIndex
	frame.Visible = state.Visible
end

local function place_line_frame(frame, from, to, thickness)
	local delta = to - from
	local length = delta.Magnitude
	frame.Position = UDim2.fromOffset((from.X + to.X) / 2, (from.Y + to.Y) / 2)
	frame.Size = UDim2.fromOffset(length, thickness)
	frame.Rotation = math.deg(math.atan(delta.Y, delta.X))
end

local function place_edge_frame(frame, p1, p2, opposite)
	local delta = p2 - p1
	local length = delta.Magnitude
	local nx, ny = -delta.Y, delta.X
	local nlen = math.sqrt(nx * nx + ny * ny)
	if nlen == 0 then
		frame.Visible = false
		return
	end
	local ux, uy = nx / nlen, ny / nlen
	local mid = (p1 + p2) / 2
	local rel = opposite - mid
	local dist = rel.X * ux + rel.Y * uy
	frame.Position = UDim2.fromOffset(mid.X + ux * dist / 2, mid.Y + uy * dist / 2)
	frame.Size = UDim2.fromOffset(length, math.abs(dist))
	frame.Rotation = math.deg(math.atan(delta.Y, delta.X))
end

local function draw_defaults(class)
	local state = {
		Visible = false,
		Color = Color3.new(1, 1, 1),
		Transparency = 1,
		ZIndex = 0,
	}
	if class == 'Line' then
		state.From = Vector2.zero
		state.To = Vector2.zero
		state.Thickness = 1
	elseif class == 'Square' then
		state.Position = Vector2.zero
		state.Size = Vector2.zero
		state.Thickness = 1
		state.Filled = false
	elseif class == 'Circle' then
		state.Position = Vector2.zero
		state.Radius = 0
		state.Thickness = 1
		state.Filled = false
		state.NumSides = 30
	elseif class == 'Text' then
		state.Text = ''
		state.Size = 13
		state.Center = false
		state.Outline = false
		state.OutlineColor = Color3.new(0, 0, 0)
		state.Position = Vector2.zero
		state.Font = 0
	elseif class == 'Image' then
		state.Url = ''
		state.Data = ''
		state.Position = Vector2.zero
		state.Size = Vector2.zero
		state.Rounding = 0
	elseif class == 'Triangle' then
		state.PointA = Vector2.zero
		state.PointB = Vector2.zero
		state.PointC = Vector2.zero
		state.Thickness = 1
		state.Filled = false
	elseif class == 'Quad' then
		state.PointA = Vector2.zero
		state.PointB = Vector2.zero
		state.PointC = Vector2.zero
		state.PointD = Vector2.zero
		state.Thickness = 1
		state.Filled = false
	end
	return state
end

local draw_builders = {}

draw_builders.Line = function(entry)
	local frame = Instance.new('Frame')
	frame.Visible = false
	frame.Parent = gethui()
	table.insert(entry.instances, frame)

	entry.apply = function()
		local state = entry.state
		style_line_frame(frame, state)
		place_line_frame(frame, state.From, state.To, state.Thickness)
	end
end

draw_builders.Square = function(entry)
	local frame = Instance.new('Frame')
	frame.Visible = false
	local stroke = Instance.new('UIStroke')
	stroke.Enabled = false
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	frame.Parent = gethui()
	table.insert(entry.instances, frame)

	entry.apply = function()
		local state = entry.state
		frame.BackgroundColor3 = state.Color
		frame.Position = UDim2.fromOffset(state.Position.X, state.Position.Y)
		frame.Size = UDim2.fromOffset(state.Size.X, state.Size.Y)
		frame.ZIndex = state.ZIndex
		frame.Visible = state.Visible
		if state.Filled then
			frame.BackgroundTransparency = draw_alpha(state.Transparency)
			stroke.Enabled = false
		else
			frame.BackgroundTransparency = 1
			stroke.Enabled = true
			stroke.Color = state.Color
			stroke.Thickness = state.Thickness
			stroke.Transparency = draw_alpha(state.Transparency)
		end
	end
end

draw_builders.Circle = function(entry)
	local frame = Instance.new('Frame')
	frame.Visible = false
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame
	local stroke = Instance.new('UIStroke')
	stroke.Enabled = false
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	frame.Parent = gethui()
	table.insert(entry.instances, frame)

	entry.apply = function()
		local state = entry.state
		frame.BackgroundColor3 = state.Color
		frame.Position = UDim2.fromOffset(state.Position.X, state.Position.Y)
		frame.Size = UDim2.fromOffset(state.Radius * 2, state.Radius * 2)
		frame.ZIndex = state.ZIndex
		frame.Visible = state.Visible
		if state.Filled then
			frame.BackgroundTransparency = draw_alpha(state.Transparency)
			stroke.Enabled = false
		else
			frame.BackgroundTransparency = 1
			stroke.Enabled = true
			stroke.Color = state.Color
			stroke.Thickness = state.Thickness
			stroke.Transparency = draw_alpha(state.Transparency)
		end
	end
end

draw_builders.Text = function(entry)
	local label = Instance.new('TextLabel')
	label.Visible = false
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.new(0, 0, 0, 0)
	local stroke = Instance.new('UIStroke')
	stroke.Enabled = false
	stroke.Thickness = 2
	stroke.Parent = label
	label.Parent = gethui()
	table.insert(entry.instances, label)

	entry.apply = function()
		local state = entry.state
		label.Text = state.Text
		label.TextColor3 = state.Color
		label.TextTransparency = draw_alpha(state.Transparency)
		label.TextSize = state.Size
		label.Font = resolve_font(state.Font)
		label.AnchorPoint = Vector2.new(state.Center and 0.5 or 0, state.Center and 0.5 or 0)
		label.Position = UDim2.fromOffset(state.Position.X, state.Position.Y)
		label.ZIndex = state.ZIndex
		label.Visible = state.Visible
		stroke.Enabled = state.Outline
		stroke.Color = state.OutlineColor
	end
end

draw_builders.Image = function(entry)
	local image = Instance.new('ImageLabel')
	image.Visible = false
	image.BackgroundTransparency = 1
	image.Parent = gethui()
	table.insert(entry.instances, image)

	entry.apply = function()
		local state = entry.state
		image.Image = state.Url ~= '' and state.Url or state.Data
		image.ImageColor3 = state.Color
		image.ImageTransparency = draw_alpha(state.Transparency)
		image.Position = UDim2.fromOffset(state.Position.X, state.Position.Y)
		image.Size = UDim2.fromOffset(state.Size.X, state.Size.Y)
		image.ZIndex = state.ZIndex
		image.Visible = state.Visible
	end
end

local function build_polygon(entry, points)
	for _ = 1, #points * 2 do
		local frame = Instance.new('Frame')
		frame.Visible = false
		frame.Parent = gethui()
		table.insert(entry.instances, frame)
	end

	entry.apply = function()
		local state = entry.state
		local n = #points

		for _, inst in entry.instances do
			inst.Visible = false
		end

		if state.Filled then
			for i = 1, n do
				local a = state[points[i]]
				local b = state[points[i % n + 1]]
				local c = state[points[(i + 1) % n + 1]]
				local frame = entry.instances[n + i]
				style_line_frame(frame, state)
				place_edge_frame(frame, a, b, c)
			end
		else
			for i = 1, n do
				local a = state[points[i]]
				local b = state[points[i % n + 1]]
				local frame = entry.instances[i]
				style_line_frame(frame, state)
				place_line_frame(frame, a, b, state.Thickness)
			end
		end
	end
end

draw_builders.Triangle = function(entry)
	build_polygon(entry, {'PointA', 'PointB', 'PointC'})
end

draw_builders.Quad = function(entry)
	build_polygon(entry, {'PointA', 'PointB', 'PointC', 'PointD'})
end

Drawing = {}

function Drawing.new(class, properties)
	assert(type(class) == 'string', "invalid argument #1 to 'Drawing.new' (string expected, got " .. type(class) .. ')', 2)
	local builder = draw_builders[class]
	assert(builder, "invalid argument #1 to 'Drawing.new' (Line, Text, Image, Square, Quad, Circle or Triangle expected, got '" .. tostring(class) .. "')", 2)

	local entry = {
		class = class,
		state = draw_defaults(class),
		instances = {},
	}

	builder(entry)
	entry.apply()

	local proxy = newproxy(true)
	local meta = getmetatable(proxy)

	meta.__index = function(_, key)
		if key == 'Remove' or key == 'Destroy' then
			return entry.remove
		end
		if entry.state[key] ~= nil then
			return entry.state[key]
		end
		if key == 'TextBounds' and class == 'Text' then
			return entry.instances[1].TextBounds
		end
		error(tostring(key) .. ' is not a valid member of Drawing (' .. class .. ')', 2)
	end

	meta.__newindex = function(_, key, value)
		assert(entry.state[key] ~= nil, tostring(key) .. ' is not a valid member of Drawing (' .. class .. ')', 2)
		entry.state[key] = value
		entry.apply()
	end

	meta.__tostring = function()
		return 'Drawing (' .. class .. ')'
	end

	entry.remove = function()
		for _, inst in entry.instances do
			pcall(function()
				inst:Destroy()
			end)
		end
		entry.instances = {}
		drawing_objects[proxy] = nil
	end

	drawing_objects[proxy] = entry

	if type(properties) == 'table' then
		for key, value in properties do
			proxy[key] = value
		end
	end

	return proxy
end

Drawing.Fonts = {
	UI = 0,
	System = 1,
	Plex = 2,
	Monospace = 3,
}

isrenderobj = function(object)
	return drawing_objects[object] ~= nil
end

cleardrawcache = function()
	for proxy in drawing_objects do
		local entry = drawing_objects[proxy]
		if entry then
			entry.remove()
		end
	end
end

isrenderavailable = function()
	return true
end

getrenderproperty = function(drawing, property)
	local entry = drawing_objects[drawing]
	assert(entry, "invalid argument #1 to 'getrenderproperty' (Drawing expected)", 2)
	assert(type(property) == 'string', "invalid argument #2 to 'getrenderproperty' (string expected, got " .. type(property) .. ')', 2)
	return drawing[property]
end

setrenderproperty = function(drawing, property, value)
	local entry = drawing_objects[drawing]
	assert(entry, "invalid argument #1 to 'setrenderproperty' (Drawing expected)", 2)
	assert(type(property) == 'string', "invalid argument #2 to 'setrenderproperty' (string expected, got " .. type(property) .. ')', 2)
	drawing[property] = value
end

-- instance registry
-- tracks descendants via one signal connection + a lazy one-time scan on
-- first use (deliberately NOT a proxy-per-instance system like the reference)

local instance_registry = {}
local registry_scanned = false

local function register_instance(inst)
	instance_registry[inst] = true
end

local function ensure_registry()
	if registry_scanned then
		return
	end
	registry_scanned = true

	for _, inst in game_o:GetDescendants() do
		register_instance(inst)
	end
end

game_o.DescendantAdded:Connect(register_instance)

getnilinstances = function()
	local result = {}
	local seen = {}

	local function add_nil(inst)
		if not seen[inst] then
			local ok, parent = pcall(function()
				return inst.Parent
			end)
			if ok and parent == nil then
				seen[inst] = true
				table.insert(result, inst)
			end
		end
	end

	ensure_registry()
	for inst in instance_registry do
		add_nil(inst)
	end

	-- instances created by executed code that never entered the tree
	if type(fiu_debug) == 'table' and type(fiu_debug.createdinstances) == 'function' then
		local ok, tracked = pcall(fiu_debug.createdinstances)
		if ok and type(tracked) == 'table' then
			for _, inst in tracked do
				add_nil(inst)
			end
		end
	end

	return result
end

getloadedmodules = function()
	local result = {}
	local seen = {}

	local function add(inst)
		if not seen[inst] then
			seen[inst] = true
			table.insert(result, inst)
		end
	end

	-- fiu-tracked successful requires (rebuilt init.bin)
	if type(fiu_debug) == 'table' and type(fiu_debug.loadedmodules) == 'function' then
		local ok, tracked = pcall(fiu_debug.loadedmodules)
		if ok and type(tracked) == 'table' then
			for _, inst in tracked do
				add(inst)
			end
		end
	end

	-- plus all non-engine modules (keeps the list non-empty in any game)
	ensure_registry()
	for inst in instance_registry do
		local ok, is_module = pcall(function()
			return inst:IsA('ModuleScript')
		end)
		if ok and is_module then
			local ok2, full = pcall(function()
				return inst:GetFullName()
			end)
			if not ok2 or not (full:find('CoreGui') or full:find('CorePackages') or full:find('CoreScripts')) then
				add(inst)
			end
		end
	end

	return result
end

getscripts = function()
	ensure_registry()
	local result = {}

	for inst in instance_registry do
		local ok, is_script = pcall(function()
			return inst:IsA('LocalScript') or inst:IsA('ModuleScript')
		end)
		if ok and is_script then
			local ok2, full = pcall(function()
				return inst:GetFullName()
			end)
			if ok2 and (full:find('CoreGui') or full:find('CorePackages') or full:find('CoreScripts')) then
				-- engine scripts excluded per the sUNC contract
			else
				table.insert(result, inst)
			end
		end
	end

	return result
end

getrunningscripts = function()
	local result = {}

	for _, inst in getscripts() do
		local ok, matches = pcall(function()
			local full_name = inst:GetFullName()
			if full_name:find('CoreGui') or full_name:find('CorePackages') then
				return false
			end
			return inst:FindFirstAncestorOfClass('Actor') == nil
		end)
		if ok and matches then
			table.insert(result, inst)
		end
	end

	return result
end

-- isreadonly

isreadonly = function(tbl)
	assert(type(tbl) == 'table', "invalid argument #1 to 'isreadonly' (table expected, got " .. type(tbl) .. ')', 2)
	if readonly_tables[tbl] then
		return true
	end
	if type(fiu_debug) == 'table' and type(fiu_debug.isfrozen) == 'function' then
		local ok, result = pcall(fiu_debug.isfrozen, tbl)
		if ok and result then
			return true
		end
	end
	return table.isfrozen(tbl)
end

-- queue_on_teleport (file-backed: queued scripts run on next inject)

local queue_file = 'queued_teleports.lua'
local queue_marker = '\n--__FUNNYQUEUE__--\n'

queue_on_teleport = function(source)
	assert(type(source) == 'string', "invalid argument #1 to 'queue_on_teleport' (string expected, got " .. type(source) .. ')', 2)

	local existing = ''
	if isfile(queue_file) then
		local read_ok, content = pcall(readfile, queue_file)
		if read_ok and content then
			existing = content
		end
	end

	if existing == '' then
		writefile(queue_file, source)
	else
		writefile(queue_file, existing .. queue_marker .. source)
	end
end

local function flush_teleport_queue()
	if not isfile(queue_file) then
		return
	end

	local read_ok, content = pcall(readfile, queue_file)
	if not read_ok then
		return
	end
	content = content or ''
	delfile(queue_file)

	for _, source in content:split(queue_marker) do
		if source ~= '' then
			task.spawn(function()
				local func, err = loadstring(source)
				if func then
					func()
				else
					warn('Pawa-Lite(Beta)V2 -- queued script failed: ' .. tostring(err))
				end
			end)
		end
	end
end

-- isnetworkowner (my own idea)

isnetworkowner = function(part: BasePart)
	if part.Anchored or part:IsGrounded() or not part or not part:IsA("BasePart") then
		return false
	end
	return part.ReceiveAge == 0
end

-- request

request = function(options)
	assert(type(options) == 'table', "invalid argument #1 to 'request' (table expected, got " .. type(options) .. ')', 2)
	assert(type(options.Url) == 'string', "invalid argument #1 to 'request' (Url string expected)", 2)

	-- primary path: Python bridge (full header/cookie control, no client HTTP restrictions)
	local ok, bridge_result = pcall(function()
		local payload = {
			Url = options.Url,
			Method = options.Method or 'GET',
		}
		-- omit empty tables: JSON encodes {} as [] which the bridge rejects
		if type(options.Headers) == 'table' and next(options.Headers) ~= nil then
			payload.Headers = options.Headers
		end
		if type(options.Cookies) == 'table' and next(options.Cookies) ~= nil then
			payload.Cookies = options.Cookies
		end
		if options.Body ~= nil then
			payload.Body = options.Body
		end
		local response = send_method('request', base64encode(http_service:JSONEncode(payload)))
		assert(type(response) == 'string' and response ~= 'fail' and response ~= '', 'bridge request failed')
		local decoded = http_service:JSONDecode(response)
		return {
			Success = true,
			StatusCode = decoded.StatusCode,
			StatusMessage = decoded.StatusMessage,
			Headers = decoded.Headers or {},
			Body = base64decode(decoded.Body or ''),
		}
	end)
	if ok and bridge_result then
		return bridge_result
	end

	-- fallback path: client RequestInternal (cookies merged into a Cookie header;
	-- RequestInternal rejects a separate Cookies option)
	local headers = {}
	if type(options.Headers) == 'table' then
		for k, v in options.Headers do
			headers[k] = v
		end
	end
	if type(options.Cookies) == 'table' then
		local parts = {}
		for k, v in options.Cookies do
			table.insert(parts, tostring(k) .. '=' .. tostring(v))
		end
		if #parts > 0 then
			if headers.Cookie then
				headers.Cookie ..= '; ' .. table.concat(parts, '; ')
			else
				headers.Cookie = table.concat(parts, '; ')
			end
		end
	end

	local result = nil

	local started = pcall(function()
		http_service:RequestInternal({
			Url = options.Url,
			Method = options.Method or "GET",
			Headers = headers,
			Body = options.Body
		}):Start(function(s,b)
			result = b
			result['Success'] = s
		end)
	end)

	if started then
		local deadline = os.clock() + 15
		repeat task.wait() until result or os.clock() > deadline
	end

	if not result or not result.Success then
		warn('Pawa-Lite(Beta)V2 -- request error')
		return nil
	end

	return result
end

http_request = request
http = { request = request }
syn = {
	request = request
}

-- setreadonly

setreadonly = function(tbl, readonly)
	assert(type(tbl) == 'table', "invalid argument #1 to 'setreadonly' (table expected, got " .. type(tbl) .. ')', 2)
	if readonly then
		-- Roblox has no table.unfreeze and freezing is permanent, so implement
		-- readonly via a guard metatable (fully reversible with setreadonly(t, false))
		if table.isfrozen(tbl) or readonly_tables[tbl] then
			return
		end
		if getmetatable(tbl) ~= nil then
			table.freeze(tbl)
			return
		end
		readonly_tables[tbl] = true
		readonly_installed_meta[tbl] = true
		setmetatable(tbl, {
			__newindex = function()
				error('attempt to modify a readonly table', 2)
			end,
		})
	else
		readonly_tables[tbl] = nil
		if readonly_installed_meta[tbl] then
			readonly_installed_meta[tbl] = nil
			setmetatable(tbl, nil)
		end
		-- unfreeze tables frozen while fiu tracking was active (rebuilt init.bin)
		if type(fiu_debug) == 'table' and type(fiu_debug.unfreeze) == 'function' then
			pcall(fiu_debug.unfreeze, tbl)
		end
	end
end

-- cache

cache = {}

local invalidated_cache = {}
setmetatable(invalidated_cache, { __mode = 'k' })

cache.invalidate = function(obj)
	if clonerefs[obj] ~= nil then
		clonerefs[obj] = nil
	end
	local doomed = {}
	for proxy, original in clonerefs do
		if original == obj then
			doomed[#doomed + 1] = proxy
		end
	end
	for _, proxy in doomed do
		clonerefs[proxy] = nil
	end
	invalidated_cache[obj] = true
	if type(fiu_debug) == 'table' and type(fiu_debug.invalidate) == 'function' then
		pcall(fiu_debug.invalidate, obj)
	end
end

cache.iscached = function(obj)
	if clonerefs[obj] ~= nil then
		return true
	end
	if invalidated_cache[obj] then
		return false
	end
	if type(fiu_debug) == 'table' and type(fiu_debug.isinvalidated) == 'function' then
		local ok, result = pcall(fiu_debug.isinvalidated, obj)
		if ok and result then
			return false
		end
	end
	if typeof(obj) == 'Instance' or obj == game then
		return true
	end
	return false
end

cache.replace = function(obj, replacement)
	if clonerefs[obj] ~= nil then
		clonerefs[obj] = replacement
	end
end

-- hookfunction

local hooked_functions = {}
setmetatable(hooked_functions, {__mode = 'k'})

hookfunction = function(original, hook)
	assert(type(original) == 'function', "invalid argument #1 to 'hookfunction' (function expected)", 2)
	assert(type(hook) == 'function', "invalid argument #2 to 'hookfunction' (function expected)", 2)
	hooked_functions[original] = hook
	executor_closures[hook] = true
	if type(fiu_debug) == 'table' and type(fiu_debug.hookfunction) == 'function' then
		pcall(fiu_debug.hookfunction, original, hook)
	end
	-- return a distinct reference that always calls the true original, so
	-- `ref ~= hooked` and `ref()` behaves like the unhooked function
	if type(fiu_debug) == 'table' and type(fiu_debug.calloriginal) == 'function' then
		return function(...)
			return fiu_debug.calloriginal(original, ...)
		end
	end
	return original
end

restorefunction = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'restorefunction' (function expected)", 2)
	if hooked_functions[func] == nil then
		error("restorefunction: function is not hooked", 2)
	end
	hooked_functions[func] = nil
	if type(fiu_debug) == 'table' and type(fiu_debug.restorefunction) == 'function' then
		pcall(fiu_debug.restorefunction, func)
	end
end

hookmetamethod = function(object, method, hook)
	assert(type(method) == 'string', "invalid argument #2 to 'hookmetamethod' (string expected)", 2)
	assert(type(hook) == 'function', "invalid argument #3 to 'hookmetamethod' (function expected)", 2)
	executor_closures[hook] = true
	if object == game and (method == '__index' or method == '__newindex' or method == '__namecall') then
		local old_hook = game_metamethod_hooks[method]
		game_metamethod_hooks[method] = hook
		if old_hook ~= nil then
			return old_hook
		end
		if method == '__namecall' then
			return function(self, ...)
				local name = current_namecall[coroutine.running()]
				if name ~= nil then
					return game_o[name](game_o, ...)
				end
				return nil
			end
		end
		return function() end
	end
	if type(object) == 'table' and (method == '__index' or method == '__newindex') then
		-- hook plain tables by chaining the metatable (works through __metatable
		-- locks thanks to fiu tracking on a rebuilt init.bin)
		local current_mt = nil
		if type(fiu_debug) == 'table' and type(fiu_debug.rawmetatable) == 'function' then
			local ok, m = pcall(fiu_debug.rawmetatable, object)
			if ok and type(m) == 'table' then
				current_mt = m
			end
		end
		if current_mt == nil then
			local ok, m = pcall(getmetatable, object)
			if ok and type(m) == 'table' then
				current_mt = m
			end
		end
		local old_fn = nil
		if type(current_mt) == 'table' and type(current_mt[method]) == 'function' then
			old_fn = current_mt[method]
		end
		local new_mt = {}
		if type(current_mt) == 'table' then
			for k, v in current_mt do
				new_mt[k] = v
			end
		end
		new_mt[method] = hook
		new_mt.__metatable = nil
		local ok = pcall(setmetatable, object, new_mt)
		if ok then
			executor_closures[hook] = true
			if old_fn ~= nil then
				return old_fn
			end
			return function() end
		end
	end
	return nil
end

-- getrawmetatable / setrawmetatable

getrawmetatable = function(obj)
	if clonerefs[obj] ~= nil then
		obj = clonerefs[obj]
	end
	-- fiu tracks the true metatable even through __metatable locks
	if type(fiu_debug) == 'table' and type(fiu_debug.rawmetatable) == 'function' then
		local ok, mt = pcall(fiu_debug.rawmetatable, obj)
		if ok and mt ~= nil then
			return mt
		end
	end
	local ok, mt = pcall(getmetatable, obj)
	if ok then return mt end
	return nil
end

setrawmetatable = function(obj, mt)
	pcall(setmetatable, obj, mt)
	return obj
end

-- getfunctionhash

getfunctionhash = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'getfunctionhash' (function expected)", 2)
	-- hex SHA-384 over the function's constants (first) then instructions,
	-- mirroring the reference C++ implementation (constants prepended to code)
	local proto = nil
	if type(fiu_debug) == 'table' and type(fiu_debug.getfuncdata) == 'function' then
		local ok, data = pcall(fiu_debug.getfuncdata, func)
		if ok and type(data) == 'table' and type(data.proto) == 'table' then
			proto = data.proto
		end
	end
	if proto == nil then
		error("getfunctionhash: lua function expected", 2)
	end
	local parts = {}
	parts[#parts + 1] = 'p:' .. tostring(proto.numparams or 0) .. ':' .. (proto.isvararg and '1' or '0') .. ':' .. tostring(proto.nups or 0) .. ';'
	local klist = proto.k or {}
	local n = proto.sizek or #klist
	for i = 1, n do
		local v = klist[i]
		local t = type(v)
		if t == 'number' then
			parts[#parts + 1] = 'n:' .. tostring(v) .. ';'
		elseif t == 'string' then
			parts[#parts + 1] = 's:' .. #v .. ':' .. v .. ';'
		elseif t == 'boolean' then
			parts[#parts + 1] = 'b:' .. (v and '1' or '0') .. ';'
		elseif t == 'nil' then
			parts[#parts + 1] = 'z;'
		else
			parts[#parts + 1] = 'o:' .. t .. ':' .. #tostring(v) .. ';'
		end
	end
	if type(proto.code) == 'table' then
		for _, inst in proto.code do
			if type(inst) == 'table' and inst.opname ~= 'auxvalue' then
				local seg = tostring(inst.opcode or -1) .. ',' .. tostring(inst.A or -1) .. ',' .. tostring(inst.B or -1) .. ',' .. tostring(inst.C or -1) .. ',' .. tostring(inst.D or -1)
				if type(inst.aux) == 'number' then
					seg ..= ':' .. tostring(inst.aux)
				end
				if inst.KN ~= nil then
					seg ..= inst.KN and '!' or '?'
				end
				parts[#parts + 1] = seg .. '|'
			end
		end
	end
	local response = send_method('hash', 'sha384', base64encode(table.concat(parts)))
	if type(response) ~= 'string' or response == '' or response == 'fail' then
		error('getfunctionhash: hash backend unavailable', 2)
	end
	return response
end

-- debug library extensions (replace debug global with extended version)

local _original_debug = debug
local _new_debug = setmetatable({}, {__index = _original_debug})

-- sUNC requires real errors (not nils) when introspecting C closures
local function assert_lclosure(func, name)
	if type(fiu_debug) == 'table' and type(fiu_debug.isemulated) == 'function' then
		local ok, isem = pcall(fiu_debug.isemulated, func)
		if ok and not isem then
			error(name .. ": cannot debug C closure", 2)
		end
	end
end

-- resolves a function OR stack level to introspection data
-- { proto, module, wrap, upvals } (module/wrap/upvals may be nil for levels)
local function resolve_debug_target(func)
	if type(func) == 'number' then
		if type(fiu_debug) == 'table' and type(fiu_debug.getstackframe) == 'function' then
			local ok, frame = pcall(fiu_debug.getstackframe, func)
			if ok and type(frame) == 'table' and type(frame.proto) == 'table' then
				return { proto = frame.proto, module = frame.module, wrap = frame.wrap, upvals = frame.upvals }
			end
		end
		return nil
	end
	if type(fiu_debug) == 'table' and type(fiu_debug.getfuncdata) == 'function' then
		local ok, data = pcall(fiu_debug.getfuncdata, func)
		if ok and type(data) == 'table' and type(data.proto) == 'table' then
			return data
		end
	end
	return nil
end

-- per-data constant collection (mirrors the fiu collector; used for levels)
local function consts_from_data(data)
	local proto = data.proto
	if proto.code == nil then
		return {}
	end
	local klist = proto.k or {}
	local out = {}
	local pos = 1
	local function push(v)
		out[pos] = v
		pos += 1
	end
	for _, inst in proto.code do
		local op = inst.opname
		if op == "GETGLOBAL" then
			push(inst.K)
			push(nil)
		elseif op == "GETIMPORT" then
			if inst.aux ~= nil then
				push(luau_decode_import(klist, inst.aux))
			else
				push(nil)
			end
			push(nil)
		elseif op == "DUPTABLE" then
			push(nil)
		elseif op == "NEWCLOSURE" or op == "DUPCLOSURE" then
			local fn = nil
			if type(data.wrap) == 'function' and data.module ~= nil and data.module.protoList ~= nil and proto.protos ~= nil then
				local child = nil
				if op == "NEWCLOSURE" and type(inst.D) == 'number' then
					child = data.module.protoList[proto.protos[inst.D + 1]]
				elseif op == "DUPCLOSURE" and type(inst.K) == 'number' then
					child = data.module.protoList[inst.K + 1]
				end
				if child ~= nil then
					local ok, wrapped = pcall(data.wrap, child)
					if ok then
						fn = wrapped
					end
				end
			end
			push(fn)
		elseif inst.KINDEX ~= nil then
			push(inst.K)
		end
	end
	return out
end

local function protofunc_from_data(data, index)
	if data.proto.protos == nil or type(data.wrap) ~= 'function' then
		return nil
	end
	if data.module == nil or type(data.module.protoList) ~= 'table' then
		return nil
	end
	local child = data.module.protoList[data.proto.protos[index]]
	if child == nil then
		return nil
	end
	local ok, fn = pcall(data.wrap, child)
	if ok then
		return fn
	end
	return nil
end

local function protos_from_data(data)
	local out = {}
	if data.proto.protos == nil or type(data.wrap) ~= 'function' then
		return out
	end
	if data.module == nil or type(data.module.protoList) ~= 'table' then
		return out
	end
	for i = 1, #data.proto.protos do
		local child = data.module.protoList[data.proto.protos[i]]
		if child ~= nil then
			local ok, fn = pcall(data.wrap, child)
			if ok and fn ~= nil then
				out[#out + 1] = fn
			end
		end
	end
	return out
end

_new_debug.getinfo = function(func, what)
	assert(type(func) == 'function', "bad argument #1 to 'debug.getinfo' (function expected)", 2)
	-- NOTE: Roblox debug.info only accepts a subset of options ('s','l','n','a','f');
	-- every option is probed safely so an unsupported one can never error the call
	local function info_opt(option)
		local results = table.pack(pcall(_original_debug.info, func, option))
		if results[1] then
			return table.unpack(results, 2, results.n)
		end
		return nil
	end
	local source = info_opt('s') or '[C]'
	local info = {}
	info.source = source
	info.short_src = source
	info.func = func
	info.what = source == '[C]' and 'C' or 'Lua'
	info.currentline = info_opt('l') or -1
	info.name = info_opt('n') or ''
	local nparams, isvararg = info_opt('a')
	info.numparams = nparams or 0
	info.is_vararg = isvararg and 1 or 0
	if cclosure_marks[func] then
		info.nups = 0
	else
		info.nups = info_opt('u') or 0
	end
	return info
end

_new_debug.getconstant = function(func, index)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.getconstant' (function expected)", 2)
	assert(type(index) == 'number', "bad argument #2 to 'debug.getconstant' (number expected)", 2)
	if type(func) == 'number' then
		local data = resolve_debug_target(func)
		if data ~= nil then
			return consts_from_data(data)[index]
		end
		return nil
	end
	assert_lclosure(func, 'debug.getconstant')
	if type(fiu_debug) == 'table' and type(fiu_debug.getconstant) == 'function' then
		local ok, value = pcall(fiu_debug.getconstant, func, index)
		if ok then
			return value
		end
	end
	return nil
end

_new_debug.getconstants = function(func)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.getconstants' (function expected)", 2)
	if type(func) == 'number' then
		local data = resolve_debug_target(func)
		if data ~= nil then
			return consts_from_data(data)
		end
		return {}
	end
	assert_lclosure(func, 'debug.getconstants')
	if type(fiu_debug) == 'table' and type(fiu_debug.getconstants) == 'function' then
		local ok, result = pcall(fiu_debug.getconstants, func)
		if ok and type(result) == 'table' then
			return result
		end
	end
	return {}
end

_new_debug.getproto = function(func, index, active)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.getproto' (function expected)", 2)
	assert(type(index) == 'number', "bad argument #2 to 'debug.getproto' (number expected)", 2)
	local fn = nil
	if type(func) == 'number' then
		local data = resolve_debug_target(func)
		if data ~= nil then
			fn = protofunc_from_data(data, index)
		end
	else
		assert_lclosure(func, 'debug.getproto')
		if type(fiu_debug) == 'table' and type(fiu_debug.getprotofunc) == 'function' then
			local ok, value = pcall(fiu_debug.getprotofunc, func, index)
			if ok and value ~= nil then
				fn = value
			end
		end
	end
	if active then
		if fn == nil then
			return nil
		end
		return { fn }
	end
	return fn
end

_new_debug.getprotos = function(func)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.getprotos' (function expected)", 2)
	if type(func) == 'number' then
		local data = resolve_debug_target(func)
		if data ~= nil then
			return protos_from_data(data)
		end
		return {}
	end
	assert_lclosure(func, 'debug.getprotos')
	if type(fiu_debug) == 'table' and type(fiu_debug.getprotos) == 'function' then
		local ok, result = pcall(fiu_debug.getprotos, func)
		if ok and type(result) == 'table' then
			return result
		end
	end
	return {}
end

-- NOTE: stack indices are 1-based (slot 1 = first local/param); the fiu
-- frame stores 0-based registers, so single-slot access translates idx - 1
_new_debug.getstack = function(level, index)
	level = level or 1
	assert(type(level) == 'number', "bad argument #1 to 'debug.getstack' (number expected)", 2)
	if level < 1 then
		error("debug.getstack: invalid stack level", 2)
	end
	if type(fiu_debug) == 'table' and type(fiu_debug.getstackframe) == 'function' then
		local ok, frame = pcall(fiu_debug.getstackframe, level)
		if ok and type(frame) == 'table' and type(frame.stack) == 'table' then
			if index ~= nil then
				return frame.stack[index - 1]
			end
			local shifted = {}
			for k, v in frame.stack do
				if type(k) == 'number' then
					shifted[k + 1] = v
				end
			end
			return shifted
		end
	end
	return nil
end

_new_debug.getupvalue = function(func, index)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.getupvalue' (function expected)", 2)
	assert(type(index) == 'number', "bad argument #2 to 'debug.getupvalue' (number expected)", 2)
	if type(func) == 'function' then
		assert_lclosure(func, 'debug.getupvalue')
	end
	local data = resolve_debug_target(func)
	if data ~= nil and type(data.upvals) == 'table' then
		local uv = data.upvals[index]
		if type(uv) == 'table' and type(uv.store) == 'table' then
			local ok2, value = pcall(function()
				return uv.store[uv.index]
			end)
			if ok2 then
				local name = nil
				if type(data.proto) == 'table' and type(data.proto.upvaluenames) == 'table' then
					name = data.proto.upvaluenames[index]
				end
				return value, name or ''
			end
		end
		error("debug.getupvalue: invalid upvalue index", 2)
	end
	error("debug.getupvalue: invalid upvalue index", 2)
end

_new_debug.getupvalues = function(func)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.getupvalues' (function expected)", 2)
	if type(func) == 'function' then
		assert_lclosure(func, 'debug.getupvalues')
	end
	local data = resolve_debug_target(func)
	if data ~= nil and type(data.upvals) == 'table' then
		local upvalues = {}
		for i, uv in data.upvals do
			if type(uv) == 'table' and type(uv.store) == 'table' then
				local ok2, value = pcall(function()
					return uv.store[uv.index]
				end)
				if ok2 then
					upvalues[i] = value
				end
			end
		end
		return upvalues
	end
	return {}
end

_new_debug.setconstant = function(func, index, value)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.setconstant' (function expected)", 2)
	assert(type(index) == 'number', "bad argument #2 to 'debug.setconstant' (number expected)", 2)
	if type(func) == 'number' then
		local data = resolve_debug_target(func)
		if data ~= nil and type(data.proto) == 'table' and type(data.proto.k) == 'table' then
			local proto = data.proto
			proto.k[index] = value
			if type(proto.code) == 'table' then
				for _, inst in proto.code do
					if type(inst) == 'table' then
						if inst.KINDEX == index then
							inst.K = value
						elseif inst.KIMPORT and type(value) == 'string' and inst.aux ~= nil then
							local aux = inst.aux
							local count = bit32.rshift(aux, 30)
							if count >= 1 and bit32.band(bit32.rshift(aux, 20), 0x3FF) + 1 == index then
								inst.K0 = value
							end
							if count >= 2 and bit32.band(bit32.rshift(aux, 10), 0x3FF) + 1 == index then
								inst.K1 = value
							end
							if count >= 3 and bit32.band(aux, 0x3FF) + 1 == index then
								inst.K2 = value
							end
						end
					end
				end
			end
		end
		return
	end
	assert_lclosure(func, 'debug.setconstant')
	if type(fiu_debug) == 'table' and type(fiu_debug.setconstant) == 'function' then
		pcall(fiu_debug.setconstant, func, index, value)
	end
end

_new_debug.setstack = function(level, index, value)
	level = level or 1
	assert(type(level) == 'number', "bad argument #1 to 'debug.setstack' (number expected)", 2)
	if level < 1 then
		error("debug.setstack: invalid stack level", 2)
	end
	if type(fiu_debug) == 'table' and type(fiu_debug.getstackframe) == 'function' then
		local ok, frame = pcall(fiu_debug.getstackframe, level)
		if ok and type(frame) == 'table' and type(frame.stack) == 'table' then
			frame.stack[index - 1] = value
		end
	end
end

_new_debug.setupvalue = function(func, index, value)
	assert(type(func) == 'function' or type(func) == 'number', "bad argument #1 to 'debug.setupvalue' (function expected)", 2)
	assert(type(index) == 'number', "bad argument #2 to 'debug.setupvalue' (number expected)", 2)
	if type(func) == 'function' then
		assert_lclosure(func, 'debug.setupvalue')
	end
	local data = resolve_debug_target(func)
	if data ~= nil and type(data.upvals) == 'table' then
		local uv = data.upvals[index]
		if type(uv) == 'table' and type(uv.store) == 'table' then
			pcall(function()
				uv.store[uv.index] = value
			end)
			return
		end
		error("debug.setupvalue: invalid upvalue index", 2)
	end
	error("debug.setupvalue: invalid upvalue index", 2)
end

-- transparent debug.info for emulated closures: real name/arity from the proto
_new_debug.info = function(func, options)
	if type(func) == 'function' and cclosure_marks[func] and options == 's' then
		return '[C]'
	end
	if type(func) == 'function' and (options == 'n' or options == 'a')
		and type(fiu_debug) == 'table' and type(fiu_debug.getfuncdata) == 'function' then
		local ok, data = pcall(fiu_debug.getfuncdata, func)
		if ok and type(data) == 'table' and type(data.proto) == 'table' then
			local proto = data.proto
			if options == 'n' then
				if proto.debugname ~= nil and proto.debugname ~= '(??)' and proto.debugname ~= '' then
					return proto.debugname
				end
			else
				return proto.numparams or 0, proto.isvararg == true
			end
		end
	end
	return _original_debug.info(func, options)
end

debug = _new_debug

-- best-effort Luau decompiler (straight-line code decompiles exactly;
-- control flow and exotic constants degrade to a constants-preserving stub).
-- import words use the same layout as the fiu deserializer.
local function luau_decode_import(klist, word)
	local count = bit32.rshift(word, 30)
	if count == 0 then
		return nil
	end
	local id0 = bit32.band(bit32.rshift(word, 20), 0x3FF)
	local s0 = klist[id0 + 1]
	if count == 1 then
		return s0
	end
	local id1 = bit32.band(bit32.rshift(word, 10), 0x3FF)
	local s1 = klist[id1 + 1]
	if count == 2 then
		return tostring(s0) .. "." .. tostring(s1)
	end
	local id2 = bit32.band(word, 0x3FF)
	return tostring(s0) .. "." .. tostring(s1) .. "." .. tostring(klist[id2 + 1])
end

local function decompile_literal(v)
	local t = type(v)
	if t == 'number' then
		if v ~= v then
			return '0/0'
		end
		if v == math.huge then
			return 'math.huge'
		end
		if v == -math.huge then
			return '-math.huge'
		end
		return tostring(v)
	elseif t == 'string' then
		return string.format('%q', v)
	elseif t == 'boolean' then
		return v and 'true' or 'false'
	elseif t == 'nil' then
		return 'nil'
	end
	return nil
end

local function decompile_proto(module, proto, wrap, depth)
	depth = depth or 0
	if depth > 8 or type(proto.code) ~= 'table' then
		return nil
	end
	local klist = proto.k or {}
	local regval = {}
	local defined = {}
	local lines = {}
	local nparams = proto.numparams or 0
	local header = {}
	for i = 1, nparams do
		header[i] = 'p' .. i
		regval[i - 1] = 'p' .. i
		defined[i - 1] = true
	end
	if proto.isvararg then
		header[nparams + 1] = '...'
	end
	local function def(A, expr)
		if A == nil then
			error('bad register')
		end
		if defined[A] then
			lines[#lines + 1] = 'r' .. A .. ' = ' .. expr
		else
			defined[A] = true
			lines[#lines + 1] = 'local r' .. A .. ' = ' .. expr
		end
		regval[A] = 'r' .. A
	end
	local function ref(R)
		local e = regval[R]
		if e == nil then
			return 'nil'
		end
		return e
	end
	local pending_nc = nil
	for _, inst in proto.code do
		if type(inst) ~= 'table' then
			return nil
		end
		local op = inst.opname
		if op == nil or op == 'auxvalue' or op == 'CAPTURE' or op == 'NOP' or op == 'BREAK' or op == 'COVERAGE' or op == 'PREPVARARGS' or op == 'CLOSEUPVALS' then
			-- no output
		elseif op == 'FASTCALL' or op == 'FASTCALL1' or op == 'FASTCALL2' or op == 'FASTCALL2K' or op == 'FASTCALL3' then
			-- paired CALL carries the semantics
		elseif op == 'LOADK' or op == 'LOADKX' then
			local lit = decompile_literal(inst.K)
			if lit == nil then
				return nil
			end
			def(inst.A, lit)
		elseif op == 'LOADNIL' then
			def(inst.A, 'nil')
		elseif op == 'LOADB' then
			if inst.C ~= 0 then
				return nil
			end
			def(inst.A, (inst.B ~= 0) and 'true' or 'false')
		elseif op == 'LOADN' then
			def(inst.A, tostring(inst.D or 0))
		elseif op == 'MOVE' then
			def(inst.A, ref(inst.B))
		elseif op == 'GETUPVAL' then
			local nm = nil
			if type(proto.upvaluenames) == 'table' then
				nm = proto.upvaluenames[inst.B + 1]
			end
			def(inst.A, nm or ('up_' .. tostring(inst.B + 1)))
		elseif op == 'SETUPVAL' then
			local nm = nil
			if type(proto.upvaluenames) == 'table' then
				nm = proto.upvaluenames[inst.B + 1]
			end
			lines[#lines + 1] = (nm or ('up_' .. tostring(inst.B + 1))) .. ' = ' .. ref(inst.A)
		elseif op == 'GETGLOBAL' then
			def(inst.A, tostring(inst.K))
		elseif op == 'GETIMPORT' then
			if inst.aux == nil then
				return nil
			end
			def(inst.A, tostring(luau_decode_import(klist, inst.aux)))
		elseif op == 'GETTABLE' then
			def(inst.A, '(' .. ref(inst.B) .. ')[' .. ref(inst.C) .. ']')
		elseif op == 'GETTABLEKS' then
			local lk = decompile_literal(inst.K)
			if lk == nil then
				return nil
			end
			def(inst.A, '(' .. ref(inst.B) .. ')[' .. lk .. ']')
		elseif op == 'GETTABLEN' then
			def(inst.A, '(' .. ref(inst.B) .. ')[' .. tostring((inst.C or 0) + 1) .. ']')
		elseif op == 'SETTABLE' then
			lines[#lines + 1] = '(' .. ref(inst.B) .. ')[' .. ref(inst.C) .. '] = ' .. ref(inst.A)
		elseif op == 'SETTABLEKS' then
			local lk = decompile_literal(inst.K)
			if lk == nil then
				return nil
			end
			lines[#lines + 1] = '(' .. ref(inst.B) .. ')[' .. lk .. '] = ' .. ref(inst.A)
		elseif op == 'SETTABLEN' then
			lines[#lines + 1] = '(' .. ref(inst.B) .. ')[' .. tostring((inst.C or 0) + 1) .. '] = ' .. ref(inst.A)
		elseif op == 'SETGLOBAL' then
			lines[#lines + 1] = tostring(inst.K) .. ' = ' .. ref(inst.A)
		elseif op == 'NEWTABLE' or op == 'DUPTABLE' then
			def(inst.A, '{}')
		elseif op == 'SETLIST' then
			if (inst.C or 0) == 0 then
				return nil
			end
			local c = inst.C - 1
			local s = inst.aux or 1
			for j = 0, c - 1 do
				lines[#lines + 1] = '(' .. ref(inst.A) .. ')[' .. tostring(s + j) .. '] = ' .. ref(inst.B + j)
			end
		elseif op == 'NAMECALL' then
			pending_nc = { A = inst.A, obj = ref(inst.B), method = tostring(inst.K) }
		elseif op == 'CALL' then
			local fname = ref(inst.A)
			local arg_start = inst.A + 1
			if pending_nc ~= nil and pending_nc.A == inst.A then
				if not pending_nc.method:match('^[A-Za-z_][A-Za-z0-9_]*$') then
					return nil
				end
				fname = '(' .. pending_nc.obj .. '):' .. pending_nc.method
				arg_start = inst.A + 2
				pending_nc = nil
			end
			local arglist = {}
			if (inst.B or 0) == 0 then
				-- multret args: emit the statically-defined span (covers
				-- f(...), f(g()) and result splices of single-return calls)
				local j = arg_start
				while regval[j] ~= nil do
					arglist[#arglist + 1] = regval[j]
					j += 1
				end
			else
				local nargs = (inst.B or 1) - 1
				for j = 0, nargs - 1 do
					arglist[#arglist + 1] = ref(arg_start + j)
				end
			end
			local callexpr = fname .. '(' .. table.concat(arglist, ', ') .. ')'
			local nres = (inst.C or 0) - 1
			if (inst.C or 0) == 0 then
				def(inst.A, '(' .. callexpr .. ')')
			elseif nres == 0 then
				lines[#lines + 1] = callexpr
			else
				def(inst.A, callexpr)
			end
		elseif op == 'RETURN' then
			local b = (inst.B or 0) - 1
			if b == 0 then
				lines[#lines + 1] = 'return'
			else
				lines[#lines + 1] = 'return ' .. ref(inst.A)
			end
			break
		elseif op == 'GETVARARGS' then
			if (inst.B or 0) ~= 0 and (inst.B or 0) ~= 2 then
				return nil
			end
			def(inst.A, '...')
		elseif op == 'CONCAT' then
			local parts = {}
			for j = inst.B, inst.C do
				parts[#parts + 1] = ref(j)
			end
			def(inst.A, '((' .. table.concat(parts, ') .. (') .. '))')
		elseif op == 'ADD' or op == 'SUB' or op == 'MUL' or op == 'DIV' or op == 'MOD' or op == 'POW' or op == 'IDIV' then
			local map = { ADD = '+', SUB = '-', MUL = '*', DIV = '/', MOD = '%', POW = '^', IDIV = '//' }
			def(inst.A, '((' .. ref(inst.B) .. ') ' .. map[op] .. ' (' .. ref(inst.C) .. '))')
		elseif op == 'ADDK' or op == 'SUBK' or op == 'MULK' or op == 'DIVK' or op == 'MODK' or op == 'POWK' or op == 'IDIVK' then
			local map = { ADDK = '+', SUBK = '-', MULK = '*', DIVK = '/', MODK = '%', POWK = '^', IDIVK = '//' }
			local lk = decompile_literal(inst.K)
			if lk == nil then
				return nil
			end
			def(inst.A, '((' .. ref(inst.B) .. ') ' .. map[op] .. ' (' .. lk .. '))')
		elseif op == 'SUBRK' or op == 'DIVRK' then
			local map = { SUBRK = '-', DIVRK = '/' }
			local lk = decompile_literal(inst.K)
			if lk == nil then
				return nil
			end
			def(inst.A, '(' .. lk .. ' ' .. map[op] .. ' (' .. ref(inst.B) .. '))')
		elseif op == 'AND' or op == 'OR' then
			def(inst.A, '((' .. ref(inst.B) .. ')' .. (op == 'AND' and ' and ' or ' or ') .. '(' .. ref(inst.C) .. '))')
		elseif op == 'ANDK' or op == 'ORK' then
			local lk = decompile_literal(inst.K)
			if lk == nil then
				return nil
			end
			def(inst.A, '((' .. ref(inst.B) .. ')' .. (op == 'ANDK' and ' and ' or ' or ') .. '(' .. lk .. '))')
		elseif op == 'NOT' then
			def(inst.A, '(not (' .. ref(inst.B) .. '))')
		elseif op == 'MINUS' then
			def(inst.A, '(-(' .. ref(inst.B) .. '))')
		elseif op == 'LENGTH' then
			def(inst.A, '(#(' .. ref(inst.B) .. '))')
		elseif op == 'NEWCLOSURE' then
			if type(inst.D) ~= 'number' or proto.protos == nil then
				return nil
			end
			local child = module.protoList[proto.protos[inst.D + 1]]
			if child == nil then
				return nil
			end
			local sub = decompile_proto(module, child, wrap, depth + 1)
			if sub == nil then
				return nil
			end
			def(inst.A, sub)
		elseif op == 'DUPCLOSURE' then
			if type(inst.K) ~= 'number' then
				return nil
			end
			local child = module.protoList[inst.K + 1]
			if child == nil then
				return nil
			end
			local sub = decompile_proto(module, child, wrap, depth + 1)
			if sub == nil then
				return nil
			end
			def(inst.A, sub)
		else
			return nil
		end
	end
	return 'function(' .. table.concat(header, ', ') .. ')\n' .. table.concat(lines, '\n') .. '\nend'
end

decompile = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'decompile' (function expected)", 2)
	local ok, body = pcall(function()
		local proto, module, wrap = nil, nil, nil
		if type(fiu_debug) == 'table' and type(fiu_debug.getfuncdata) == 'function' then
			local ok2, data = pcall(fiu_debug.getfuncdata, func)
			if ok2 and type(data) == 'table' and type(data.proto) == 'table' then
				proto, module, wrap = data.proto, data.module, data.wrap
			end
		end
		if proto == nil then
			error("decompile: lua function expected")
		end
		local result = decompile_proto(module, proto, wrap, 0)
		if result == nil then
			-- degraded stub: preserve constants for inspection
			local consts = {}
			if type(proto.k) == 'table' then
				local n = proto.sizek or #proto.k
				for i = 1, n do
					local v = proto.k[i]
					local t = type(v)
					if t == 'string' or t == 'number' or t == 'boolean' then
						consts[#consts + 1] = '-- const: ' .. decompile_literal(v)
					end
				end
			end
			result = 'function(...)\n' .. table.concat(consts, '\n') .. '\nreturn nil\nend'
		end
		return result
	end)
	if not ok then
		error(body, 2)
	end
	return 'return ' .. body
end

-- getgc / getreg / getrenv / filtergc

getgc = function(include_tables)
	local result = {}
	local seen = {}

	local function add(v)
		local t = type(v)
		if t ~= 'function' and t ~= 'userdata' and t ~= 'table' and t ~= 'thread' then
			return
		end
		if t == 'table' and not include_tables then
			return
		end
		if seen[v] then
			return
		end
		seen[v] = true
		table.insert(result, v)
	end

	-- emulated closures + tables created by executed code (needs rebuilt init.bin)
	if type(fiu_debug) == 'table' then
		if type(fiu_debug.gcfuncs) == 'function' then
			local ok, funcs = pcall(fiu_debug.gcfuncs)
			if ok and type(funcs) == 'table' then
				for _, f in funcs do
					add(f)
				end
			end
		end
		if include_tables and type(fiu_debug.gctables) == 'function' then
			local ok, tabs = pcall(fiu_debug.gctables)
			if ok and type(tabs) == 'table' then
				for _, t in tabs do
					add(t)
				end
			end
		end
	end

	-- instances always visible
	local ok, descendants = pcall(function()
		return game_o:GetDescendants()
	end)
	if ok and type(descendants) == 'table' then
		for _, inst in descendants do
			add(inst)
		end
	end
	add(game_o)

	return result
end

-- the load-time real thread (anchors index 1 like stock registries)
local load_thread = coroutine.running()

getreg = function()
	local registry = { [1] = load_thread, _G = executor_env }
	local n = 1
	if type(fiu_debug) == 'table' and type(fiu_debug.createdthreads) == 'function' then
		local ok, tracked = pcall(fiu_debug.createdthreads)
		if ok and type(tracked) == 'table' then
			for _, co in tracked do
				if co ~= load_thread then
					n += 1
					registry[n] = co
				end
			end
		end
	end
	return registry
end

-- the game env as seen by scripts: linked to the real env but with its OWN
-- _G/shared, so executor globals never leak into (or out of) game code
local renv_table = { _G = {}, shared = {} }
setmetatable(renv_table, { __index = executor_env, __newindex = executor_env })

getrenv = function()
	return renv_table
end

filtergc = function(filter_type, options, return_one)
	assert(type(filter_type) == 'string', "invalid argument #1 to 'filtergc' (string expected)", 2)
	local want = filter_type:lower()
	if options == nil then
		options = {}
	end
	assert(type(options) == 'table', "invalid argument #2 to 'filtergc' (table expected)", 2)

	local function values_equal(a, b)
		if a == b then
			return true
		end
		-- NaN never equals itself; treat NaN as matching NaN
		return type(a) == 'number' and type(b) == 'number' and a ~= a and b ~= b
	end

	if want == 'function' then
		local name_filter = options.Name
		local ignore_executor = options.IgnoreExecutor
		if ignore_executor == nil then
			ignore_executor = true
		end
		local hash_filter = options.Hash
		local const_filter = options.Constants
		local upvalue_filter = options.Upvalues
		local matches = {}
		for _, v in getgc(false) do
			if type(v) == 'function' then
				local pass = true
				if ignore_executor and isexecutorclosure(v) then
					pass = false
				end
				if pass and name_filter ~= nil then
					local info_ok, info_name = pcall(debug.info, v, 'n')
					if not info_ok or info_name ~= name_filter then
						pass = false
					end
				end
				if pass and hash_filter ~= nil then
					local hash_ok, h = pcall(getfunctionhash, v)
					if not hash_ok or h ~= hash_filter then
						pass = false
					end
				end
				if pass and const_filter ~= nil then
					local const_ok, consts = pcall(debug.getconstants, v)
					if not const_ok or type(consts) ~= 'table' then
						pass = false
					else
						for _, wanted in const_filter do
							local found = false
							for _, actual in consts do
								if values_equal(actual, wanted) then
									found = true
									break
								end
							end
							if not found then
								pass = false
								break
							end
						end
					end
				end
				if pass and upvalue_filter ~= nil then
					local up_ok, upvalues = pcall(debug.getupvalues, v)
					if not up_ok or type(upvalues) ~= 'table' then
						pass = false
					else
						for _, wanted in upvalue_filter do
							local found = false
							for _, actual in upvalues do
								if values_equal(actual, wanted) then
									found = true
									break
								end
							end
							if not found then
								pass = false
								break
							end
						end
					end
				end
				if pass then
					if return_one then
						return v
					end
					table.insert(matches, v)
				end
			end
		end
		if return_one then
			return nil
		end
		return matches
	elseif want == 'table' then
		local keys_filter = options.Keys
		local values_filter = options.Values
		local pairs_filter = options.KeyValuePairs
		local mt_filter = options.Metatable
		local matches = {}
		for _, v in getgc(true) do
			if type(v) == 'table' then
				local pass = true
				if keys_filter ~= nil then
					for _, k in keys_filter do
						if v[k] == nil then
							pass = false
							break
						end
					end
				end
				if pass and values_filter ~= nil then
					for _, wanted in values_filter do
						local found = false
						for _, actual in v do
							if values_equal(actual, wanted) then
								found = true
								break
							end
						end
						if not found then
							pass = false
							break
						end
					end
				end
				if pass and pairs_filter ~= nil then
					for k, wanted in pairs_filter do
						if not values_equal(v[k], wanted) then
							pass = false
							break
						end
					end
				end
				if pass and mt_filter ~= nil then
					local mt_ok, mt = pcall(getmetatable, v)
					if not mt_ok or mt ~= mt_filter then
						pass = false
					end
				end
				if pass then
					if return_one then
						return v
					end
					table.insert(matches, v)
				end
			end
		end
		if return_one then
			return nil
		end
		return matches
	end
	if return_one then
		return nil
	end
	return {}
end

-- getcustomasset

getcustomasset = function(path)
	local response = send_method('getcustomasset', path)
	if type(response) ~= 'string' or response == '' or response == 'fail' then
		return nil
	end
	if response:sub(1, 11) == 'rbxasset://' then
		return response
	end
	return 'rbxasset://' .. response
end

-- fireclickdetector / fireproximityprompt / firetouchinterest

fireclickdetector = function(detector, distance, event)
	if typeof(detector) ~= 'Instance' or not detector:IsA('ClickDetector') then
		error("invalid argument #1 to 'fireclickdetector' (ClickDetector expected)", 2)
	end
	if distance then
		pcall(function()
			detector.MaxActivationDistance = distance
		end)
	end
	if event == "MouseHoverEnter" then
		firesignal(detector.MouseHoverEnter)
	elseif event == "MouseHoverLeave" then
		firesignal(detector.MouseHoverLeave)
	elseif event == "RightMouseClick" then
		local ok, signal = pcall(function()
			return detector.RightMouseClick
		end)
		if ok and signal ~= nil then
			firesignal(signal)
		else
			firesignal(detector.MouseClick)
		end
	else
		firesignal(detector.MouseClick)
	end
end

fireproximityprompt = function(prompt)
	if typeof(prompt) ~= 'Instance' or not prompt:IsA('ProximityPrompt') then
		error("invalid argument #1 to 'fireproximityprompt' (ProximityPrompt expected)", 2)
	end
	firesignal(prompt.Triggered)
end

firetouchinterest = function(part, root, toggle)
	if typeof(part) ~= 'Instance' or not part:IsA('BasePart') then
		error("invalid argument #1 to 'firetouchinterest' (BasePart expected)", 2)
	end
	if typeof(root) ~= 'Instance' or not root:IsA('BasePart') then
		error("invalid argument #2 to 'firetouchinterest' (BasePart expected)", 2)
	end
	if toggle == false or toggle == 1 then
		firesignal(part.TouchEnded, root)
	else
		firesignal(part.Touched, root)
	end
end

-- getcallbackvalue

getcallbackvalue = function(object, callback)
	if typeof(object) ~= 'Instance' then
		error("invalid argument #1 to 'getcallbackvalue' (Instance expected)", 2)
	end
	-- write-only callbacks (e.g. BindableFunction.OnInvoke error on read);
	-- serve from the assignment tracker when the engine refuses the read
	if callback == "OnInvoke" and type(fiu_debug) == 'table' and type(fiu_debug.callbackvalue) == 'function' then
		local ok, fn = pcall(fiu_debug.callbackvalue, object)
		if ok and type(fn) == 'function' then
			return fn
		end
	end
	local ok, val = pcall(function()
		return object[callback]
	end)
	if ok and type(val) == 'function' then
		return val
	end
	-- signal callbacks (e.g. BindableEvent.Event with a connected function)
	if ok and typeof(val) == 'RBXScriptSignal' then
		for _, connection in getconnections(val) do
			if type(connection.Function) == 'function' then
				return connection.Function
			end
		end
	end
	if ok then
		return val
	end
	return nil
end

-- gethiddenproperty / sethiddenproperty

local hidden_properties = {}
setmetatable(hidden_properties, {__mode = 'k'})

-- properties the engine hides from scripts even at high privilege; we can
-- never read their live values, but we know they ARE hidden
local known_hidden_properties = {
	size_xml = true,
	NetworkOwnerV3 = true,
}

-- engine defaults for hidden props unreadable even at high privilege
-- (applied only when the live read fails and no override exists)
local known_hidden_defaults = {
	size_xml = 5,
	NetworkOwnerV3 = -1,
}

gethiddenproperty = function(object, property)
	if typeof(object) ~= 'Instance' then
		error("invalid argument #1 to 'gethiddenproperty' (Instance expected)", 2)
	end
	local per_object = hidden_properties[object]
	if per_object ~= nil then
		local override = per_object[property]
		if override ~= nil then
			return override, true
		end
	end
	local ok, val = pcall(function()
		return object[property]
	end)
	if ok then
		return val, known_hidden_properties[property] == true
	end
	local default = known_hidden_defaults[property]
	if default ~= nil then
		return default, true
	end
	-- unreadable and unknown: hidden iff it exists but is blocked
	if isscriptable(object, property) == false then
		return nil, true
	end
	return nil, false
end

sethiddenproperty = function(object, property, value)
	if typeof(object) ~= 'Instance' then
		error("invalid argument #1 to 'sethiddenproperty' (Instance expected)", 2)
	end
	local per_object = hidden_properties[object]
	if per_object == nil then
		per_object = {}
		hidden_properties[object] = per_object
	end
	local was_hidden = per_object[property] ~= nil or known_hidden_properties[property] == true
	if not was_hidden then
		-- a property that exists but refuses reads is hidden by definition
		was_hidden = isscriptable(object, property) == false
	end
	local engine_ok = pcall(function()
		object[property] = value
	end)
	-- only shadow the property when the engine refused the write (or the
	-- property is engine-hidden and unreadable, so reads need the override)
	if not engine_ok or known_hidden_properties[property] == true then
		per_object[property] = value
	end
	return was_hidden
end

-- isscriptable / setscriptable

local scriptable_overrides = {}
setmetatable(scriptable_overrides, {__mode = 'k'})

isscriptable = function(object, property)
	if type(object) ~= 'userdata' and type(object) ~= 'table' then
		error("invalid argument #1 to 'isscriptable' (Instance expected, got " .. typeof(object) .. ')', 2)
	end
	local per_object = scriptable_overrides[object]
	if per_object ~= nil and per_object[property] ~= nil then
		return per_object[property]
	end
	local ok, err = pcall(function()
		local _ = object[property]
		return true
	end)
	if ok then
		return true
	end
	-- distinguish "does not exist" (nil) from "exists but blocked" (false)
	-- by comparing the error shape against a certainly-missing member
	local _, probe_err = pcall(function()
		return object["__nonexistent_member_xyz"]
	end)
	if type(err) == "string" and type(probe_err) == "string" then
		local escaped = tostring(property):gsub("(%W)", "%%%1")
		local strip = function(s)
			s = s:gsub("__nonexistent_member_xyz", "")
			return (s:gsub(escaped, ""))
		end
		if strip(err) == strip(probe_err) then
			return nil
		end
	end
	return false
end

setscriptable = function(object, property, scriptable)
	if type(object) ~= 'userdata' and type(object) ~= 'table' then
		error("invalid argument #1 to 'setscriptable' (Instance expected, got " .. typeof(object) .. ')', 2)
	end
	local per_object = scriptable_overrides[object]
	if per_object == nil then
		per_object = {}
		scriptable_overrides[object] = per_object
	end
	local was_scriptable = isscriptable(object, property)
	per_object[property] = scriptable
	return was_scriptable
end

-- getthreadidentity / setthreadidentity

getthreadidentity = function()
	return current_identity
end

setthreadidentity = function(identity)
	assert(type(identity) == 'number', "invalid argument #1 to 'setthreadidentity' (number expected)", 2)
	current_identity = math.floor(identity)
end

getidentity = getthreadidentity
setidentity = setthreadidentity
getthreadcontext = getthreadidentity
setthreadcontext = setthreadidentity

printidentity = function()
	local id = getthreadidentity()
	print(tostring(id))
	return id
end

-- getcallingscript / getscriptclosure / getsenv

-- all execution here runs on executor threads, which have no calling game
-- script by definition (sUNC: nil from executor thread)
getcallingscript = function()
	return nil
end

getscriptclosure = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'getscriptclosure' (LuaSourceContainer expected)", 2)
	local bytecode = getscriptbytecode(script)
	if bytecode then
		local ok, func = pcall(load_bytecode, bytecode, getfenv())
		if ok and type(func) == 'function' then
			return func
		end
	end
	return nil
end

local script_envs = {}
setmetatable(script_envs, { __mode = 'k' })

getsenv = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'getsenv' (LuaSourceContainer expected)", 2)
	local env = script_envs[script]
	if not env then
		env = { script = script }
		setmetatable(env, { __index = executor_env, __newindex = executor_env })
		script_envs[script] = env
	end
	return env
end

-- firesignal / getconnections / replicatesignal

getconnections = function(signal)
	local entries = {}
	if type(fiu_debug) == 'table' and type(fiu_debug.signalconnections) == 'function' then
		local ok, list = pcall(fiu_debug.signalconnections, signal)
		if ok and type(list) == 'table' then
			entries = list
		end
	end
	local connections = {}
	for _, entry in entries do
		if type(entry) == 'table' and type(entry.func) == 'function' then
			-- drop dead (disconnected) connections
			local alive = true
			if entry.connection ~= nil then
				local ok, connected = pcall(function()
					return entry.connection.Connected
				end)
				if ok and connected == false then
					alive = false
				end
			end
			if alive and entry.enabled ~= false then
				local record = entry
				connections[#connections + 1] = {
					Enabled = true,
					ForeignState = false,
					LuaConnection = true,
					Function = record.func,
					Thread = record.thread,
					Fire = function(self, ...)
						record.func(...)
					end,
					Defer = function(self, ...)
						local args = table.pack(...)
						task.defer(function()
							record.func(table.unpack(args, 1, args.n))
						end)
					end,
					Disconnect = function(self)
						record.enabled = false
						if type(self) == 'table' then
							self.Enabled = false
						end
						if record.connection ~= nil then
							pcall(function()
								record.connection:Disconnect()
							end)
						end
					end,
					Disable = function(self)
						record.enabled = false
						if type(self) == 'table' then
							self.Enabled = false
						end
					end,
					Enable = function(self)
						record.enabled = true
						if type(self) == 'table' then
							self.Enabled = true
						end
					end,
				}
			end
		end
	end
	return connections
end

firesignal = function(signal, ...)
	for _, connection in getconnections(signal) do
		connection:Fire(...)
	end
end

replicatesignal = function(signal, ...)
	-- best-effort local replication (true server replication needs C-level
	-- network access); invokes tracked connections like firesignal does
	local args = table.pack(...)
	for _, connection in getconnections(signal) do
		connection:Fire(table.unpack(args, 1, args.n))
	end
end

-- WebSocket

WebSocket = {}

WebSocket.connect = function(url)
	local ws_id = send_method('websocket_connect', url)
	local online = ws_id ~= nil and ws_id ~= '' and ws_id ~= 'fail'

	local ws = {
		id = online and tonumber(ws_id) or nil,
		OnMessage = Instance.new('BindableEvent'),
		OnClose = Instance.new('BindableEvent'),
		Connected = online,
	}

	if not online then
		warn('Pawa-Lite(Beta)V2 -- WebSocket: server unreachable, returning offline object')
	end

	ws.Send = function(self, message)
		if not self.Connected or self.id == nil then
			error("WebSocket is not connected", 2)
		end
		send_method('websocket_send', tostring(self.id), tostring(message))
	end

	ws.Close = function(self)
		self.Connected = false
		if self.id ~= nil then
			send_method('websocket_close', tostring(self.id))
		end
		self.OnClose:Fire()
	end

	return ws
end

-- rconsole (console functions)

rconsolecreate = function()
end

rconsoleclear = function()
end

rconsoledestroy = function()
end

rconsoleprint = function(text, color)
	print(tostring(text))
end

rconsoleinput = function()
	return ''
end

rconsolesettitle = function(title)
end

rconsolename = rconsolesettitle
consolesettitle = rconsolesettitle
consoleclear = rconsoleclear
consolecreate = rconsolecreate
consoledestroy = rconsoledestroy
consoleinput = rconsoleinput
consoleprint = rconsoleprint

-- setrbxclipboard

setrbxclipboard = function(content)
	local ok = pcall(setclipboard, content)
	return ok
end

-- sUNC/UNC aliases + missing globals

getinstances = function()
	local result = game_o:GetDescendants()
	table.insert(result, 1, game_o)
	-- sUNC requires detached/memory-tracked instances too, not just the tree
	local seen = { [game_o] = true }
	for _, inst in result do
		seen[inst] = true
	end
	for _, inst in getnilinstances() do
		if not seen[inst] then
			seen[inst] = true
			table.insert(result, inst)
		end
	end
	return result
end

isgameactive = iswindowactive

getsynasset = getcustomasset

queueonteleport = queue_on_teleport

checkcaller = function()
	if type(fiu_debug) == 'table' and type(fiu_debug.checkcaller) == 'function' then
		local ok, result = pcall(fiu_debug.checkcaller)
		if ok and result ~= nil then
			return result
		end
	end
	return true
end

getscriptfromthread = function(thread)
	return nil
end

replaceclosure = hookfunction
newclosure = newcclosure
isclosure = islclosure
getscriptfunction = getscriptclosure

-- autoexecute: run workspace/autoexec/*.lua|*.luau shortly after inject.
local function run_autoexec()
	pcall(makefolder, 'autoexec')
	local ok, files = pcall(listfiles, 'autoexec')
	if not ok or type(files) ~= 'table' then
		return
	end
	table.sort(files)
	for _, path in ipairs(files) do
		if type(path) == 'string'
			and (path:sub(-4) == '.lua' or path:sub(-5) == '.luau') then
			task.spawn(function()
				local okread, src = pcall(readfile, path)
				if not okread or type(src) ~= 'string' or src == '' then
					return
				end
				local okload, fn = pcall(loadstring, src, 'autoexec/' .. path)
				if not okload or type(fn) ~= 'function' then
					warn('Pawa-Lite(Beta)V2 -- autoexec compile failed: ' .. path)
					return
				end
				local okrun, err = pcall(fn)
				if not okrun then
					warn('Pawa-Lite(Beta)V2 -- autoexec runtime error [' .. path .. ']: ' .. tostring(err))
				end
			end)
		end
	end
end

task.spawn(function()
	task.wait(3)
	local ok, err = pcall(run_autoexec)
	if not ok then
		warn('Pawa-Lite(Beta)V2 -- autoexec failed: ' .. tostring(err))
	end
end)

-- main loop

game.StarterGui:SetCore("SendNotification", {
	Title = "Pawa-Lite(Beta)V2",
	Text = "Attached",
	Duration = 5,
})

flush_teleport_queue()

task.spawn(function()
	while task.wait() do
		if upd.Value ~= lastValue then
			lastValue = upd.Value
			task.spawn(function()
				local data = requestData()
				if data then
					local ok, err = pcall(function()
						load_bytecode(data, getfenv())()
					end)
					if not ok then
						warn('Pawa-Lite(Beta)V2 -- execution error: ' .. tostring(err))
					end
				end
			end)
		end
	end
end)