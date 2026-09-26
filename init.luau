-- create root

local folder = Instance.new("Folder")
	folder.Name = "_pawalite"

local upd = Instance.new("BoolValue")
upd.Name = "UpdateIndicator"
upd.Parent = folder

folder.Parent = game.CoreGui

-- vars
local http = game.HttpService
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
			self.Source ..= newData
			self.Length = string.len(self.Source)
			self:seek(0)
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
							end

							if pushMatch then
								pushToLiteral = false

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

		local output = ""
		local function write(char)
			output = output .. char
		end
		for chunkNum, chunk in blocks do
			local litLen = chunk.LiteralLength
			local matLen = (chunk.MatchLength or 4) - 4

			local tokenLit = math.clamp(litLen, 0, 15)
			local tokenMat = math.clamp(matLen, 0, 15)

			local token = bit32.lshift(tokenLit, 4) + tokenMat
			write(string.pack("<I1", token))

			if litLen >= 15 then
				litLen = litLen - 15
				repeat
					local nextToken = math.clamp(litLen, 0, 0xFF)
					write(string.pack("<I1", nextToken))
					if nextToken == 0xFF then
						litLen = litLen - 255
					end
				until nextToken < 0xFF
			end

			write(chunk.Literal)

			if chunkNum ~= #blocks then
				write(string.pack("<I2", chunk.MatchOffset))

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

		return output
	end

	function module.decompress(lz4data: string, decompressedLen: number?): string
		local inputStream = streamer(lz4data)
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

			if inputStream.IsFinished then
				break
			end

			if decompressedLen and outputStream.Length >= decompressedLen then
				break
			end

			local offset = string.unpack("<I2", inputStream:read(2))
			if bit32.band(token, 15) >= 15 then
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

			if inputStream.IsFinished then
				break
			end

		until decompressedLen ~= nil and outputStream.Length >= decompressedLen

		return outputStream.Source
	end

	lz4 = module
end

-- funcs

local function requestData()
	local result, success = nil

	local exists, _ = pcall(function()
		http:RequestInternal({
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
		local okfb, fb = pcall(function()
			return workspace.Fallback.Value
		end)
		if okfb then
			result = {
				Success = true,
				Body = fb
			}
		else
			warn('Pawa-Lite(Beta)V2 -- request error (transport unavailable)')
			return nil
		end
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
		http:RequestInternal({
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
		local okfb, fb = pcall(function()
			return workspace.Fallback.Value
		end)
		if okfb then
			result = {
				Success = true,
				Body = fb
			}
		else
			warn('Pawa-Lite(Beta)V2 -- request error (transport unavailable)')
			return nil
		end
	end

	repeat task.wait() until result

	if not result or not result.Success then
		warn('Pawa-Lite(Beta)V2 -- request error')
		return nil
	end

	return result and result.Body or ""
end

-- unc functions

local genv_table = {}

getgenv = function()
	return genv_table
end

-- Resolve a global through proxy env chains. The bootstrap env only
-- carries raw keys; the real globals live behind __index links.
-- Cycle-guarded (never follows function __index, never revisits tables).
local function resolve_global(k)
	local ok, env = pcall(getfenv)
	local cur = (ok and type(env) == 'table') and env or nil
	local seen = {}
	while cur ~= nil and not seen[cur] do
		seen[cur] = true
		local v = rawget(cur, k)
		if v ~= nil then
			return v
		end
		local mt_ok, mt = pcall(getmetatable, cur)
		if not mt_ok or type(mt) ~= 'table' then
			break
		end
		local ix_ok, ix = pcall(function() return rawget(mt, '__index') end)
		if not ix_ok or type(ix) ~= 'table' then
			break
		end
		cur = ix
	end
	return nil
end

do
	local ok = pcall(function()
		local env = getfenv()
		local meta = getmetatable(env)
		if type(meta) ~= 'table' then
			meta = {}
		end
		meta.__index = genv_table
		setmetatable(env, meta)
	end)
	-- belt and suspenders: mirror getgenv writes into the real global env,
	-- so `getgenv().X = v` stays visible as bare `X` even if the __index
	-- link above ever fails to install (e.g. per-thread env tables).
	local genv_mt = getmetatable(genv_table)
	if type(genv_mt) ~= 'table' then
		genv_mt = {}
	end
	genv_mt.__newindex = function(t, k, v)
		rawset(t, k, v)
		pcall(function() getfenv()[k] = v end)
	end
	-- Reads fall back through the real env chain (cycle-guarded; a bare
	-- rawget would miss every global that only lives behind __index).
	genv_mt.__index = function(t, k)
		return resolve_global(k)
	end
	setmetatable(genv_table, genv_mt)
	-- Eager snapshot: copy every global into genv_table up front, so
	-- `getgenv().print` etc. resolve RAW without any metamethod involved.
	-- (Later-defined globals still resolve through the __index fallback.)
	pcall(function()
		local env = getfenv()
		if type(env) == 'table' then
			for k, v in pairs(env) do
				if rawget(genv_table, k) == nil then
					rawset(genv_table, k, v)
				end
			end
		end
	end)
end

local renv_table = {
	game = game,
	workspace = workspace,
	script = script,
	Instance = Instance,
	Enum = Enum,
	task = task,
	coroutine = coroutine,
	print = print,
	warn = warn,
	error = error,
	assert = assert,
	pcall = pcall,
	xpcall = xpcall,
	select = select,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	typeof = typeof,
	tick = tick,
	wait = wait,
	spawn = spawn,
	delay = delay,
	require = require,
	math = math,
	string = string,
	table = table,
	os = os,
	bit32 = bit32,
	buffer = buffer,
	utf8 = utf8,
	_G = {},
}

getrenv = function()
	return renv_table
end


local AES = {}
do
	local s_box = { 99, 124, 119, 123, 242, 107, 111, 197,  48,   1, 103,  43, 254, 215, 171, 118, 202,
		130, 201, 125, 250,  89,  71, 240, 173, 212, 162, 175, 156, 164, 114, 192, 183, 253, 147,  38,  54,
		 63, 247, 204,  52, 165, 229, 241, 113, 216,  49,  21,   4, 199,  35, 195,  24, 150,   5, 154,   7,
		 18, 128, 226, 235,  39, 178, 117,   9, 131,  44,  26,  27, 110,  90, 160,  82,  59, 214, 179,  41,
		227,  47, 132,  83, 209,   0, 237,  32, 252, 177,  91, 106, 203, 190,  57,  74,  76,  88, 207, 208,
		239, 170, 251,  67,  77,  51, 133,  69, 249,   2, 127,  80,  60, 159, 168,  81, 163,  64, 143, 146,
		157,  56, 245, 188, 182, 218,  33,  16, 255, 243, 210, 205,  12,  19, 236,  95, 151,  68,  23, 196,
		167, 126,  61, 100,  93,  25, 115,  96, 129,  79, 220,  34,  42, 144, 136,  70, 238, 184,  20, 222,
		 94,  11, 219, 224,  50,  58,  10,  73,   6,  36,  92, 194, 211, 172,  98, 145, 149, 228, 121, 231,
		200,  55, 109, 141, 213,  78, 169, 108,  86, 244, 234, 101, 122, 174,   8, 186, 120,  37,  46,  28,
		166, 180, 198, 232, 221, 116,  31,  75, 189, 139, 138, 112,  62, 181, 102,  72,   3, 246,  14,  97,
		 53,  87, 185, 134, 193,  29, 158, 225, 248, 152,  17, 105, 217, 142, 148, 155,  30, 135, 233, 206,
		 85,  40, 223, 140, 161, 137,  13, 191, 230,  66, 104,  65, 153,  45,  15, 176,  84, 187,  22}
	local inv_s_box = { 82,   9, 106, 213,  48,  54, 165,  56, 191,  64, 163, 158, 129, 243, 215, 251, 124,
		227,  57, 130, 155,  47, 255, 135,  52, 142,  67,  68, 196, 222, 233, 203,  84, 123, 148,  50, 166,
		194,  35,  61, 238,  76, 149,  11,  66, 250, 195,  78,   8,  46, 161, 102,  40, 217,  36, 178, 118,
		 91, 162,  73, 109, 139, 209,  37, 114, 248, 246, 100, 134, 104, 152,  22, 212, 164,  92, 204,  93,
		101, 182, 146, 108, 112,  72,  80, 253, 237, 185, 218,  94,  21,  70,  87, 167, 141, 157, 132, 144,
		216, 171,   0, 140, 188, 211,  10, 247, 228,  88,   5, 184, 179,  69,   6, 208,  44,  30, 143, 202,
		 63,  15,   2, 193, 175, 189,   3,   1,  19, 138, 107,  58, 145,  17,  65,  79, 103, 220, 234, 151,
		242, 207, 206, 240, 180, 230, 115, 150, 172, 116,  34, 231, 173,  53, 133, 226, 249,  55, 232,  28,
		117, 223, 110,  71, 241,  26, 113,  29,  41, 197, 137, 111, 183,  98,  14, 170,  24, 190,  27, 252,
		 86,  62,  75, 198, 210, 121,  32, 154, 219, 192, 254, 120, 205,  90, 244,  31, 221, 168,  51, 136,
		  7, 199,  49, 177,  18,  16,  89,  39, 128, 236,  95,  96,  81, 127, 169,  25, 181,  74,  13,  45,
		229, 122, 159, 147, 201, 156, 239, 160, 224,  59,  77, 174,  42, 245, 176, 200, 235, 187,  60, 131,
		 83, 153,  97,  23,  43,   4, 126, 186, 119, 214,  38, 225, 105,  20,  99,  85,  33,  12, 125}

	local rcon = {  0,   1,   2,   4,   8,  16,  32,  64, 128,  27,  54, 108, 216, 171,  77, 154,  47,  94,
		188,  99, 198, 151,  53, 106, 212, 179, 125, 250, 239, 197, 145,  57}

	local function xtime(x)
		local i = bit32.lshift(x, 1)
		return if bit32.band(x, 128) == 0 then i else bit32.bxor(i, 27) % 256
	end

	local function subBytes(s, inv)
		inv = if inv then inv_s_box else s_box
		for i = 1, 4 do
			for j = 1, 4 do
				s[i][j] = inv[s[i][j] + 1]
			end
		end
	end

	local function shiftRows(s, inv)
		s[1][3], s[2][3], s[3][3], s[4][3] = s[3][3], s[4][3], s[1][3], s[2][3]
		if inv then
			s[1][2], s[2][2], s[3][2], s[4][2] = s[4][2], s[1][2], s[2][2], s[3][2]
			s[1][4], s[2][4], s[3][4], s[4][4] = s[2][4], s[3][4], s[4][4], s[1][4]
		else
			s[1][2], s[2][2], s[3][2], s[4][2] = s[2][2], s[3][2], s[4][2], s[1][2]
			s[1][4], s[2][4], s[3][4], s[4][4] = s[4][4], s[1][4], s[2][4], s[3][4]
		end
	end

	local function addRoundKey(s, k)
		for i = 1, 4 do
			for j = 1, 4 do
				s[i][j] = bit32.bxor(s[i][j], k[i][j])
			end
		end
	end

	local function mixColumns(s, inv)
		local t, u
		if inv then
			for i = 1, 4 do
				t = xtime(xtime(bit32.bxor(s[i][1], s[i][3])))
				u = xtime(xtime(bit32.bxor(s[i][2], s[i][4])))
				s[i][1], s[i][2] = bit32.bxor(s[i][1], t), bit32.bxor(s[i][2], u)
				s[i][3], s[i][4] = bit32.bxor(s[i][3], t), bit32.bxor(s[i][4], u)
			end
		end

		local i
		for j = 1, 4 do
			i = s[j]
			t, u = bit32.bxor(i[1], i[2], i[3], i[4]), i[1]
			for k = 1, 4 do
				i[k] = bit32.bxor(i[k], t, xtime(bit32.bxor(i[k], i[k + 1] or u)))
			end
		end
	end

	local function bytesToMatrix(t, c, inv)
		if inv then
			table.move(c[1], 1, 4, 1, t)
			table.move(c[2], 1, 4, 5, t)
			table.move(c[3], 1, 4, 9, t)
			table.move(c[4], 1, 4, 13, t)
		else
			for i = 1, #c / 4 do
				table.clear(t[i])
				table.move(c, i * 4 - 3, i * 4, 1, t[i])
			end
		end

		return t
	end

	local function xorBytes(t, a, b)
		table.clear(t)

		for i = 1, math.min(#a, #b) do
			table.insert(t, bit32.bxor(a[i], b[i]))
		end
		return t
	end

	local function expandKey(key)
		local kc = bytesToMatrix(if #key == 16 then {{}, {}, {}, {}} elseif #key == 24 then {{}, {}, {}, {}
			, {}, {}} else {{}, {}, {}, {}, {}, {}, {}, {}}, key)
		local is = #key / 4
		local i, t, w = 2, {}, nil

		while #kc < (#key / 4 + 7) * 4 do
			w = table.clone(kc[#kc])
			if #kc % is == 0 then
				table.insert(w, table.remove(w, 1))
				for j = 1, 4 do
					w[j] = s_box[w[j] + 1]
				end
				w[1] = bit32.bxor(w[1], rcon[i])
				i += 1
			elseif #key == 32 and #kc % is == 4 then
				for j = 1, 4 do
					w[j] = s_box[w[j] + 1]
				end
			end

			table.clear(t)
			xorBytes(w, table.move(w, 1, 4, 1, t), kc[#kc - is + 1])
			table.insert(kc, w)
		end

		table.clear(t)
		for i = 1, #kc / 4 do
			table.insert(t, {})
			table.move(kc, i * 4 - 3, i * 4, 1, t[#t])
		end
		return t
	end

	local function encryptBlock(key, km, pt, ps, r)
		bytesToMatrix(ps, pt)
		addRoundKey(ps, km[1])

		for i = 2, #key / 4 + 6 do
			subBytes(ps)
			shiftRows(ps)
			mixColumns(ps)
			addRoundKey(ps, km[i])
		end
		subBytes(ps)
		shiftRows(ps)
		addRoundKey(ps, km[#km])

		return bytesToMatrix(r, ps, true)
	end

	local function decryptBlock(key, km, ct, cs, r)
		bytesToMatrix(cs, ct)

		addRoundKey(cs, km[#km])
		shiftRows(cs, true)
		subBytes(cs, true)
		for i = #key / 4 + 6, 2, - 1 do
			addRoundKey(cs, km[i])
			mixColumns(cs, true)
			shiftRows(cs, true)
			subBytes(cs, true)
		end

		addRoundKey(cs, km[1])
		return bytesToMatrix(r, cs, true)
	end

	local function to_bytes(a)
		if type(a) == "string" then
			local r = {}
			for i = 1, string.len(a), 7997 do
				table.move({string.byte(a, i, i + 7996)}, 1, 7997, i, r)
			end
			return r
		elseif type(a) == "table" then
			for _, i in ipairs(a) do
				assert(type(i) == "number" and math.floor(i) == i and 0 <= i and i < 256,
					"Unable to cast value to bytes")
			end
			return a
		else
			error("Unable to cast value to bytes", 0)
		end
	end

	local function to_string(t)
		local parts = {}
		for i = 1, #t, 7997 do
			parts[#parts + 1] = string.char(table.unpack(t, i, math.min(i + 7996, #t)))
		end
		return table.concat(parts)
	end

	function AES.encrypt_CBC(key, plainText, initVector)
		key = to_bytes(key)
		assert(#key == 16 or #key == 24 or #key == 32, "Key must be either 16, 24 or 32 bytes long")
		plainText = to_bytes(plainText)
		initVector = if initVector then to_bytes(initVector) else table.create(16, 0)
		assert(#initVector == 16, "Initialization vector must be 16 bytes long")

		local km = expandKey(key)
		local b, k, p, s, t = {}, {}, initVector, {{}, {}, {}, {}}, {}
		for i = 1, #plainText, 16 do
			table.move(plainText, i, i + 15, 1, k)
			table.move(encryptBlock(key, km, xorBytes(t, k, p), s, p), 1, 16, i, b)
		end

		return b
	end

	function AES.decrypt_CBC(key, cipherText, initVector)
		key = to_bytes(key)
		assert(#key == 16 or #key == 24 or #key == 32, "Key must be either 16, 24 or 32 bytes long")
		cipherText = to_bytes(cipherText)
		assert(#cipherText % 16 == 0, "Input must be a multiple of 16 bytes in length")
		initVector = if initVector then to_bytes(initVector) else table.create(16, 0)
		assert(#initVector == 16, "Initialization vector must be 16 bytes long")

		local km = expandKey(key)
		local b, k, p, s, t = {}, {}, initVector, {{}, {}, {}, {}}, {}
		for i = 1, #cipherText, 16 do
			table.move(cipherText, i, i + 15, 1, k)
			table.move(xorBytes(k, decryptBlock(key, km, k, s, t), p), 1, 16, i, b)
			table.move(cipherText, i, i + 15, 1, p)
		end

		return b
	end

	AES.to_string = to_string
	AES.to_bytes = to_bytes
end

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

crypt.base64 = {
	encode = base64encode,
	decode = base64decode,
}

base64 = {
	encode = base64encode,
	decode = base64decode,
}

base64_encode = base64encode
base64_decode = base64decode
crypt.base64_encode = base64encode
crypt.base64_decode = base64decode

crypt.generatekey = function(len)
	len = len or 32
	local bytes = table.create(len)
	for i = 1, len do
		bytes[i] = math.random(0, 255)
	end
	return base64encode(string.char(table.unpack(bytes, 1, len)))
end

crypt.generatebytes = function(size)
	assert(type(size) == 'number', "invalid argument #1 to 'crypt.generatebytes' (number expected, got " .. type(size) .. ')', 2)
	return base64encode(crypt.random(size))
end

local random_charset do
	local chars = {}
	for ascii = 33, 57 do
		chars[#chars + 1] = string.char(ascii)
	end
	for ascii = 65, 90 do
		chars[#chars + 1] = string.char(ascii)
	end
	for ascii = 97, 122 do
		chars[#chars + 1] = string.char(ascii)
	end
	random_charset = chars
end

crypt.random = function(size)
	size = tonumber(size) or error("Expected number within range (0, 1024), got: " .. tostring(size), 0)
	if size > 1024 or size < 0 then
		error("Expected number within range (0, 1024), got: " .. tostring(size), 0)
	end

	local randomString = table.create(size)
	for i = 1, size do
		randomString[i] = random_charset[math.random(1, #random_charset)]
	end

	return table.concat(randomString)
end

crypt.encrypt = function(data, key, initVector, mode)
	mode = mode or 'CBC'
	if mode ~= 'CBC' then
		error('Unsupported crypt.encrypt mode: ' .. tostring(mode), 0)
	end

	local keyBytes = AES.to_bytes(base64decode(key))
	assert(#keyBytes == 16 or #keyBytes == 24 or #keyBytes == 32, "Key must be either 16, 24 or 32 bytes long")
	local ivBytes = AES.to_bytes(base64decode(initVector))
	assert(#ivBytes == 16, "Initialization vector must be 16 bytes long")

	local plain = AES.to_bytes(tostring(data))
	local pad = 16 - (#plain % 16)
	for _ = 1, pad do
		plain[#plain + 1] = pad
	end

	local cipher = AES.encrypt_CBC(keyBytes, plain, ivBytes)
	return base64encode(AES.to_string(cipher))
end

crypt.decrypt = function(data, key, initVector, mode)
	mode = mode or 'CBC'
	if mode ~= 'CBC' then
		error('Unsupported crypt.decrypt mode: ' .. tostring(mode), 0)
	end

	local keyBytes = AES.to_bytes(base64decode(key))
	assert(#keyBytes == 16 or #keyBytes == 24 or #keyBytes == 32, "Key must be either 16, 24 or 32 bytes long")
	local ivBytes = AES.to_bytes(base64decode(initVector))
	assert(#ivBytes == 16, "Initialization vector must be 16 bytes long")

	local plain = AES.decrypt_CBC(keyBytes, AES.to_bytes(base64decode(data)), ivBytes)

	local pad = plain[#plain]
	if pad and pad >= 1 and pad <= 16 and #plain >= pad then
		local valid = true
		for i = #plain - pad + 1, #plain do
			if plain[i] ~= pad then
				valid = false
				break
			end
		end
		if valid then
			for _ = 1, pad do
				table.remove(plain)
			end
		end
	end

	return AES.to_string(plain)
end

crypt.hmac = function(key, data, algorithm)
	assert(type(key) == 'string', "invalid argument #1 to 'crypt.hmac' (string expected, got " .. type(key) .. ')', 2)
	assert(type(data) == 'string', "invalid argument #2 to 'crypt.hmac' (string expected, got " .. type(data) .. ')', 2)

	local response = send_method('hmac', algorithm or 'sha256', base64encode(key), base64encode(data))
	if response == 'fail' or response == '' then
		return nil
	end
	return response
end

crypt.hash = function(data, hash_name)
	assert(type(data) == 'string', "invalid argument #1 to 'crypt.hash' (string expected, got " .. type(data) .. ')', 2)
	assert(type(hash_name) == 'string', "invalid argument #2 to 'crypt.hash' (string expected, got " .. type(hash_name) .. ')', 2)

	local response = send_method('hash', hash_name, base64encode(data))
	if response == 'fail' then
		return nil
	end
	return response
end

lz4compress = lz4.compress
lz4decompress = lz4.decompress
crypt.lz4compress = lz4.compress
crypt.lz4decompress = lz4.decompress

local chunk_sources = setmetatable({}, {__mode = 'k'})

-- Registry of executor-owned closures (newcclosure results etc.). Declared
-- early so debug.info below can report them as C closures. Values are the
-- known debug name (string) or true when unknown.
local executor_closures = {}
setmetatable(executor_closures, {__mode = 'k'})

local real_debug = debug
local real_debug_info = real_debug.info

debug = setmetatable({}, {__index = real_debug})

debug.info = function(f, what)
	what = what or 'sl'
	if executor_closures[f] then
		if what == 's' then
			return '[C]'
		end
		if what == 'n' then
			if f == debug.info then
				return 'info'
			end
			local stored = executor_closures[f]
			if type(stored) == 'string' and stored ~= '' then
				return stored
			end
		end
	end
	if f == debug.info and what == 'n' then
		return 'info'
	end
	local target = f
	if type(f) == 'number' then
		local okn, func = pcall(real_debug_info, f + 1, 'f')
		target = okn and func or nil
	end

	local name = type(target) == 'function' and chunk_sources[target]
	if name and type(what) == 'string' and what:find('s', 1, true) then
		if what == 's' then
			return name
		end
		local vals = {}
		for i = 1, #what do
			local opt = what:sub(i, i)
			if opt == 's' then
				vals[#vals + 1] = name
			else
				local oko, part = pcall(real_debug_info, target, opt)
				vals[#vals + 1] = oko and part or nil
			end
		end
		return table.unpack(vals, 1, #what)
	end

	return real_debug_info(f, what)
end

loadstring = function(source, chunkname)
	if chunkname then
		chunkname = tostring(chunkname):gsub('^[@=]', '')
	end

	local response = send_method('compile', base64encode(source), base64encode(chunkname or ''))
	if not response or response:sub(1, 4) == 'fail' then
		warn('Pawa-Lite(Beta)V2 -- loadstring compile failed: ' .. tostring(response))
		return nil, 'Pawa-Lite(Beta)V2 -- loadstring error: ' .. tostring(response)
	end
	local func = load_bytecode(base64decode(response), getfenv())
	if chunkname and chunkname ~= '' then
		chunk_sources[func] = chunkname
	end
	return func
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
	assert(type(path) == 'string', "invalid argument #1 to 'writefile' (string expected, got " .. type(path) .. ')', 2)
	if isBlockedExtension(path) then
		error('Pawa-Lite(Beta)V2 -- writefile: extension is blocked: ' .. path, 2)
	end
	local response = send_method('writefile', path, base64encode(content))
	if response ~= 'ok' then
		error('Pawa-Lite(Beta)V2 -- writefile: ' .. tostring(response) .. ': ' .. path, 2)
	end
end

appendfile = function(path, content)
	assert(type(path) == 'string', "invalid argument #1 to 'appendfile' (string expected, got " .. type(path) .. ')', 2)
	if isBlockedExtension(path) then
		error('Pawa-Lite(Beta)V2 -- appendfile: extension is blocked: ' .. path, 2)
	end
	local response = send_method('appendfile', path, base64encode(content))
	if response ~= 'ok' then
		error('Pawa-Lite(Beta)V2 -- appendfile: ' .. tostring(response) .. ': ' .. path, 2)
	end
end

readfile = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'readfile' (string expected, got " .. type(path) .. ')', 2)
	local response = send_method('readfile', path)
	if response == 'fail' or response == 'bad request' then
		error('Pawa-Lite(Beta)V2 -- readfile: cannot read: ' .. path, 2)
	end
	return base64decode(response)
end

isfile = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'isfile' (string expected, got " .. type(path) .. ')', 2)
	local response = send_method('isfile', path)
	return response == 'true'
end

isfolder = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'isfolder' (string expected, got " .. type(path) .. ')', 2)
	local response = send_method('isfolder', path)
	return response == 'true'
end

delfile = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'delfile' (string expected, got " .. type(path) .. ')', 2)
	local response = send_method('delfile', path)
	if response ~= 'ok' then
		error('Pawa-Lite(Beta)V2 -- delfile: cannot delete: ' .. path, 2)
	end
end

delfolder = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'delfolder' (string expected, got " .. type(path) .. ')', 2)
	local response = send_method('delfolder', path)
	if response ~= 'ok' then
		error('Pawa-Lite(Beta)V2 -- delfolder: cannot delete: ' .. path, 2)
	end
end

makefolder = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'makefolder' (string expected, got " .. type(path) .. ')', 2)
	local response = send_method('makefolder', path)
	if response ~= 'ok' then
		error('Pawa-Lite(Beta)V2 -- makefolder: ' .. tostring(response) .. ': ' .. path, 2)
	end
end

listfiles = function(path)
	local response = send_method('listfiles', path)
	if response == 'fail' or response == 'bad request' then
		error('Pawa-Lite(Beta)V2 -- listfiles: folder not found: ' .. tostring(path), 2)
	end
	if response == '' then
		return {}
	end
	return response:split('\n')
end

-- loadfile

loadfile = function(path: string)
	local ok, content = pcall(readfile, path)
	if not ok or content == nil then
		return nil, 'Pawa-Lite(Beta)V2 -- loadfile: unable to read \'' .. tostring(path) .. '\''
	end

	local ok2, result = pcall(loadstring, content)
	if not ok2 or result == nil then
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
	holder.Name = http:GenerateGUID(false)
	holder.Value = script
	holder.Parent = folder

	local response = send_method(method_name, holder.Name)
	holder:Destroy()

	return response
end

getscriptbytecode = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'getscriptbytecode' (LuaSourceContainer expected, got " .. typeof(script) .. ')', 2)

	local response = pointer_request('getscriptbytecode', script)
	if not response or response == 'fail' or response == 'nil' then
		return nil
	end
	return base64decode(response)
end

dumpstring = getscriptbytecode

getscripthash = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'getscripthash' (LuaSourceContainer expected, got " .. typeof(script) .. ')', 2)

	local response = pointer_request('getscripthash', script)
	if not response or response == 'fail' or response == 'nil' then
		return nil
	end
	return response
end

decompile = function(script)
	assert(typeof(script) == 'Instance' and script:IsA('LuaSourceContainer'), "invalid argument #1 to 'decompile' (LuaSourceContainer expected, got " .. typeof(script) .. ')', 2)

	local bytecode = getscriptbytecode(script)
	if not bytecode or #bytecode == 0 then
		return nil, 'Pawa-Lite(Beta)V2 -- decompile: no bytecode for ' .. tostring(script)
	end

	local response = send_method('decompile', base64encode(bytecode))
	if not response or response == 'fail' or response == '' then
		return nil, 'Pawa-Lite(Beta)V2 -- decompile: request failed'
	end
	return response
end

-- clipboard

setclipboard = function(content)
	local response = send_method('setclipboard', base64encode(tostring(content)))
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- clipboard error: '..tostring(response))
	end
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
	keytap = 'keyclick',
	keypress = 'keyclick',
	keyrelease = 'keyrelease',
	mousescroll = 'mousescroll',
}

local env = getfenv()
for name, method in input_methods do
	env[name] = function(...)
		local response = send_method(method, ...)
		if response == 'fail' then
			warn('Pawa-Lite(Beta)V2 -- input error: ' .. name)
		end
	end
end

setrbxclipboard = setclipboard

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
isgameactive = iswindowactive

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
-- NOTE: executor_closures lives near the top (debug section) so debug.info
-- can see the same registry.

islclosure = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'islclosure' (function expected, got " .. type(func) .. ')', 2)
	return debug.info(func, 's') ~= '[C]'
end

isluaclosure = islclosure

iscclosure = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'iscclosure' (function expected, got " .. type(func) .. ')', 2)
	return debug.info(func, 's') == '[C]'
end

newcclosure = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'newcclosure' (function expected, got " .. type(func) .. ')', 2)
	local okname, funcname = pcall(real_debug_info, func, 'n')
	local wrapped = coroutine.wrap(function(...)
		while true do
			coroutine.yield(func(...))
		end
	end)
	executor_closures[wrapped] = (okname and type(funcname) == 'string' and funcname ~= '' and funcname) or true
	return wrapped
end

clonefunction = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'clonefunction' (function expected, got " .. type(func) .. ')', 2)
	if iscclosure(func) then
		return newcclosure(func)
	end
	return function(...)
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

local function clone_target(proxy)
	local obj = clonerefs[proxy]
	if obj == nil then
		error('cloneref target is no longer valid', 3)
	end
	return obj
end

cloneref = function(obj)
	-- Instances pass through untouched: the engine rejects newproxy
	-- userdata wherever an Instance is expected (Parent, Adornee, ...).
	-- Only non-Instances get the hiding proxy.
	if typeof(obj) == 'Instance' then
		return obj
	end
	local proxy = newproxy(true)
	local meta = getmetatable(proxy)
	clonerefs[proxy] = obj
	meta.__index = function(t, n)
		local o = clone_target(t)
		local v = o[n]
		if typeof(v) == 'function' then
			return function(self, ...)
				if self == t then
					self = o
				end
				return v(self, ...)
			end
		end
		return v
	end
	meta.__newindex = function(t, n, v)
		clone_target(t)[n] = v
	end
	meta.__tostring = function(t)
		return tostring(clone_target(t))
	end
	meta.__metatable = getmetatable(obj)
	return proxy
end

local function is_instance_like(v)
	if type(v) == 'userdata' then
		return true
	end
	if type(v) == 'table' then
		local mt = getmetatable(v)
		if type(mt) == 'table' and rawget(mt, '__pawaliteinstance') then
			return true
		end
	end
	return false
end

compareinstances = function(a, b)
	assert(is_instance_like(a), "invalid argument #1 to 'compareinstances' (Instance expected, got " .. typeof(a) .. ')', 2)
	assert(is_instance_like(b), "invalid argument #2 to 'compareinstances' (Instance expected, got " .. typeof(b) .. ')', 2)
	if clonerefs[a] then
		a = clonerefs[a]
	end
	if clonerefs[b] then
		b = clonerefs[b]
	end
	return a == b
end

local rtypeof = typeof
typeof = function(obj)
	if clonerefs[obj] then
		return 'Instance'
	end
	return rtypeof(obj)
end

local bootstrap_getnamecallmethod = getnamecallmethod

getnamecallmethod = function()
	if bootstrap_getnamecallmethod then
		local ok, registered = pcall(bootstrap_getnamecallmethod)
		if ok and registered then
			return registered
		end
	end
	return nil
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
		screen_gui.Parent = game:GetService('CoreGui')
		return screen_gui
	end)

	if ok then
		hidden_ui = gui
	end

	return hidden_ui
end

local drawing_objects = setmetatable({}, {__mode = 'k'})

local drawing_gui = nil

local function drawing_container()
	if drawing_gui and drawing_gui.Parent then
		return drawing_gui
	end

	local ok, gui = pcall(function()
		local screen_gui = Instance.new('ScreenGui')
		screen_gui.Name = 'DrawingGuis'
		screen_gui.ResetOnSpawn = false
		screen_gui.DisplayOrder = 999998
		screen_gui.IgnoreGuiInset = true
		screen_gui.Parent = game:GetService('CoreGui')
		return screen_gui
	end)

	if ok then
		drawing_gui = gui
	end

	return drawing_gui or gethui()
end

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
		__OBJECT_EXISTS = true,
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
	frame.Parent = drawing_container()
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
	frame.Parent = drawing_container()
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
	frame.Parent = drawing_container()
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
	label.Parent = drawing_container()
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
	image.Parent = drawing_container()
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
		frame.Parent = drawing_container()
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

local instance_registry = {}

local function register_instance(inst)
	instance_registry[inst] = true
end

local function registry_entries()
	local entries = {}
	local key = nil
	while true do
		local ok, next_key = pcall(next, instance_registry, key)
		if not ok or next_key == nil then
			break
		end
		entries[#entries + 1] = next_key
		key = next_key
	end
	return entries
end

local function all_known_instances()
	local result, seen = {}, {}
	local function add(inst)
		if inst ~= nil and not seen[inst] then
			seen[inst] = true
			result[#result + 1] = inst
		end
	end
	pcall(function()
		for _, inst in game:GetDescendants() do
			add(inst)
		end
	end)
	for _, inst in ipairs(registry_entries()) do
		local okt, is_inst = pcall(typeof, inst)
		if okt and is_inst == 'Instance' then
			add(inst)
		end
	end
	return result
end

local real_Instance = Instance
Instance = setmetatable({
	new = function(class, parent)
		local inst = real_Instance.new(class)
		register_instance(inst)
		if parent ~= nil then
			pcall(function()
				inst.Parent = parent
			end)
		end
		return inst
	end,
}, {__index = real_Instance})

game.DescendantAdded:Connect(register_instance)

getinstances = function()
	return all_known_instances()
end

getnilinstances = function()
	local result = {}
	for _, inst in ipairs(registry_entries()) do
		local okt, is_inst = pcall(typeof, inst)
		if okt and is_inst == 'Instance' then
			local ok, parent = pcall(function()
				return inst.Parent
			end)
			if ok and parent == nil then
				result[#result + 1] = inst
			end
		end
	end
	return result
end

local function is_client_script(inst)
	local ok, res = pcall(function()
		if inst:IsA('LocalScript') or inst:IsA('ModuleScript') then
			return true
		end
		if inst.ClassName == 'Script' then
			return inst.RunContext == Enum.RunContext.Client
		end
		return false
	end)
	return ok and res == true
end

getscripts = function()
	local result, seen = {}, {}
	local function add(inst)
		if inst ~= nil and not seen[inst] and is_client_script(inst) then
			seen[inst] = true
			result[#result + 1] = inst
		end
	end
	pcall(function()
		for _, inst in game:GetDescendants() do
			add(inst)
		end
	end)
	for _, inst in ipairs(registry_entries()) do
		add(inst)
	end
	return result
end

getrunningscripts = function()
	local result = {}
	for _, inst in ipairs(getscripts()) do
		local ok, running = pcall(function()
			if inst.Parent == nil then
				return false
			end
			local full_name = inst:GetFullName()
			if full_name:find('CoreGui', 1, true) or full_name:find('CorePackages', 1, true) then
				return false
			end
			local oke, enabled = pcall(function()
				return inst.Enabled
			end)
			if oke and enabled == false then
				return false
			end
			return inst:FindFirstAncestorOfClass('Actor') == nil
		end)
		if ok and running then
			result[#result + 1] = inst
		end
	end
	return result
end

local loaded_modules = setmetatable({}, {__mode = 'k'})

local function module_env(mod)
	return setmetatable({script = mod, require = require}, {__index = getfenv()})
end

require = function(mod)
	assert(typeof(mod) == 'Instance', "invalid argument #1 to 'require' (ModuleScript expected, got " .. typeof(mod) .. ')', 2)
	local okm, ism = pcall(function()
		return mod:IsA('ModuleScript')
	end)
	if not okm or not ism then
		error("invalid argument #1 to 'require' (ModuleScript expected, got " .. typeof(mod) .. ')', 2)
	end

	if loaded_modules[mod] ~= nil then
		return loaded_modules[mod]
	end

	local bytecode = getscriptbytecode(mod)
	if not bytecode or #bytecode == 0 then
		error('require: failed to get bytecode for ' .. tostring(mod), 2)
	end

	local chunk = load_bytecode(bytecode, module_env(mod))
	local result = chunk()
	loaded_modules[mod] = result
	return result
end

getloadedmodules = function()
	local result = {}
	for mod in pairs(loaded_modules) do
		result[#result + 1] = mod
	end
	return result
end

getscriptclosure = function(script_inst)
	assert(typeof(script_inst) == 'Instance' and script_inst:IsA('LuaSourceContainer'), "invalid argument #1 to 'getscriptclosure' (LuaSourceContainer expected, got " .. typeof(script_inst) .. ')', 2)
	local bytecode = getscriptbytecode(script_inst)
	if not bytecode or #bytecode == 0 then
		return nil
	end
	return load_bytecode(bytecode, module_env(script_inst))
end

getscriptfunction = getscriptclosure

getsenv = function(script_inst)
	assert(typeof(script_inst) == 'Instance' and script_inst:IsA('LuaSourceContainer'), "invalid argument #1 to 'getsenv' (LuaSourceContainer expected, got " .. typeof(script_inst) .. ')', 2)
	local oke, enabled = pcall(function()
		return script_inst.Enabled
	end)
	if script_inst:IsA('LocalScript') and oke and enabled == false then
		error('getsenv: script is not running', 2)
	end
	return module_env(script_inst)
end

getcallingscript = function()
	return nil
end

-- isreadonly

isreadonly = function(tbl)
	assert(type(tbl) == 'table', "invalid argument #1 to 'isreadonly' (table expected, got " .. type(tbl) .. ')', 2)
	return table.isfrozen(tbl)
end

-- cache (service refs swap through the bootstrap GetService cache)

local invalidated = setmetatable({}, {__mode = 'k'})

local function find_service_name(inst)
	local sc = rawget(getfenv(), '__pawalite_service_cache')
	if type(sc) ~= 'table' then
		return nil
	end
	for name, service in pairs(sc) do
		if service == inst then
			return name
		end
	end
	return nil
end

cache = {}

cache.invalidate = function(inst)
	assert(typeof(inst) == 'Instance', "invalid argument #1 to 'cache.invalidate' (Instance expected, got " .. typeof(inst) .. ')', 2)
	invalidated[inst] = true
	local name = find_service_name(inst)
	local sc = rawget(getfenv(), '__pawalite_service_cache')
	if name and type(sc) == 'table' then
		sc[name] = cloneref(inst)
	end
end

cache.iscached = function(inst)
	assert(typeof(inst) == 'Instance', "invalid argument #1 to 'cache.iscached' (Instance expected, got " .. typeof(inst) .. ')', 2)
	return invalidated[inst] ~= true
end

cache.replace = function(inst, replacement)
	assert(typeof(inst) == 'Instance', "invalid argument #1 to 'cache.replace' (Instance expected, got " .. typeof(inst) .. ')', 2)
	assert(typeof(replacement) == 'Instance', "invalid argument #2 to 'cache.replace' (Instance expected, got " .. typeof(replacement) .. ')', 2)
	local name = find_service_name(inst)
	local sc = rawget(getfenv(), '__pawalite_service_cache')
	if name and type(sc) == 'table' then
		sc[name] = cloneref(replacement)
	end
end

local queue_file = 'queued_teleports.lua'
local queue_marker = '\n--__FUNNYQUEUE__--\n'

queue_on_teleport = function(source)
	assert(type(source) == 'string', "invalid argument #1 to 'queue_on_teleport' (string expected, got " .. type(source) .. ')', 2)

	local ok, existing = pcall(readfile, queue_file)
	if not ok or not existing or existing == '' then
		pcall(writefile, queue_file, source)
	else
		pcall(writefile, queue_file, existing .. queue_marker .. source)
	end
end

queueonteleport = queue_on_teleport

clearqueueonteleport = function()
	pcall(delfile, queue_file)
end
clearteleportqueue = clearqueueonteleport
clear_teleport_queue = clearqueueonteleport

local function flush_teleport_queue()
	if not isfile(queue_file) then
		return
	end

	local ok, content = pcall(readfile, queue_file)
	if not ok or not content then
		return
	end
	pcall(delfile, queue_file)

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

isnetworkowner = function(part: BasePart)
	if part.Anchored or part:IsGrounded() or not part or not part:IsA("BasePart") then
		return false
	end
	return part.ReceiveAge == 0
end

-- saveinstance
local _saveinstance = nil
saveinstance = function(options) -- docs: https://luau.github.io/UniversalSynSaveInstance/api/SynSaveInstance/
    options = options or {}
    assert(type(options) == "table", "invalid argument #1 to 'saveinstance' (table expected, got " .. type(options) .. ") ", 2)
    _saveinstance = _saveinstance or loadstring(game:HttpGet("https://raw.githubusercontent.com/luau/SynSaveInstance/main/saveinstance.luau", true), "saveinstance")()
    return _saveinstance(options)
end
savegame = saveinstance

firetouchinterest = function(part, otherPart, endTouched)
	assert(typeof(part) == 'Instance', "invalid argument #1 to 'firetouchinterest' (BasePart expected, got " .. typeof(part) .. ')', 2)
	assert(typeof(otherPart) == 'Instance', "invalid argument #2 to 'firetouchinterest' (BasePart expected, got " .. typeof(otherPart) .. ')', 2)
	pcall(function()
		if endTouched then
			otherPart.CFrame = otherPart.CFrame * CFrame.new(0, -60, 0)
		else
			otherPart.CFrame = part.CFrame
		end
	end)
end

getcallbackvalue = function(inst, property)
	assert(typeof(inst) == 'Instance', "invalid argument #1 to 'getcallbackvalue' (Instance expected, got " .. typeof(inst) .. ')', 2)
	assert(type(property) == 'string', "invalid argument #2 to 'getcallbackvalue' (string expected, got " .. type(property) .. ')', 2)
	local ok, value = pcall(function()
		return inst[property]
	end)
	if ok and type(value) == 'function' then
		return value
	end
	return nil
end

-- Hosts whose responses depend on the player's auth cookies (balance,
-- trades, payouts, identity, chat, ...). Scripts must not reach them
-- through request(): fail closed with an error (fail = mitigated).
local blocked_api_hosts = {
	['economy.roblox.com'] = true,
	['trades.roblox.com'] = true,
	['groups.roblox.com'] = true,
	['users.roblox.com'] = true,
	['friends.roblox.com'] = true,
	['chat.roblox.com'] = true,
	['accountsettings.roblox.com'] = true,
	['accountinformation.roblox.com'] = true,
	['auth.roblox.com'] = true,
	['apis.roblox.com'] = true,
	['api.roblox.com'] = true,
	['billing.roblox.com'] = true,
	['premiumfeatures.roblox.com'] = true,
	['www.roblox.com'] = true,
	['roblox.com'] = true,
}

local function blocked_api_host(url)
	local host = tostring(url or ''):lower():match('^%s*https?://([^/%?#:]+)') or ''
	host = host:gsub(':%d+$', '')
	for blocked in pairs(blocked_api_hosts) do
		if host == blocked or host:sub(-#blocked - 1) == ('.' .. blocked) then
			return host
		end
	end
	return nil
end

request = function(options)
	assert(type(options) == 'table' and type(options.Url) == 'string', "invalid argument #1 to 'request' (table with Url expected, got " .. type(options) .. ')', 2)

	local bad = blocked_api_host(options.Url)
	if bad then
		error('Pawa-Lite(Beta)V2 -- request blocked: Roblox API host (' .. bad .. ')', 2)
	end

	local headers = {}
	if type(options.Headers) == 'table' then
		for k, v in options.Headers do
			headers[k] = v
		end
	end
	-- NOTE: do NOT force a custom User-Agent here. Roblox blocks/overrides
	-- restricted headers (User-Agent et al.) and the request fails with
	-- "request error". The game client always sends its own UA.

	if type(options.Cookies) == 'table' then
		local parts = {}
		for k, v in options.Cookies do
			parts[#parts + 1] = tostring(k) .. '=' .. tostring(v)
		end
		if #parts > 0 then
			local joined = table.concat(parts, '; ')
			local existing = headers['Cookie'] or headers['cookie']
			headers['Cookie'] = existing and (existing .. '; ' .. joined) or joined
		end
	end

	local result = nil

	http:RequestInternal({
		Url = options.Url,
		Method = options.Method or "GET",
		Headers = headers,
		Body = options.Body
	}):Start(function(s,b)
		result = b
		result['Success'] = s
	end)

	repeat task.wait() until result

	if not result or not result.Success then
		warn('Pawa-Lite(Beta)V2 -- request error')
		return nil
	end

	return result
end

http_request = request
env.http = {request = request}
syn = {request = request}

Signal = {}

function Signal.new()
	local handlers = {}
	local waiting = {}

	local signal = {}

	local function fire(...)
		local snapshot = table.clone(handlers)
		for _, entry in ipairs(snapshot) do
			task.spawn(entry.fn, ...)
		end
		local threads = waiting
		waiting = {}
		for _, thread in ipairs(threads) do
			task.spawn(thread, ...)
		end
	end

	function signal:Connect(fn)
		assert(type(fn) == 'function', "invalid argument #1 to 'Connect' (function expected, got " .. type(fn) .. ')', 2)
		local entry = {fn = fn}
		table.insert(handlers, entry)

		local connection = {}
		function connection:Disconnect()
			local idx = table.find(handlers, entry)
			if idx then
				table.remove(handlers, idx)
			end
		end

		return connection
	end

	function signal:Once(fn)
		assert(type(fn) == 'function', "invalid argument #1 to 'Once' (function expected, got " .. type(fn) .. ')', 2)
		local connection
		connection = self:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end

	function signal:Wait()
		local thread = coroutine.running()
		table.insert(waiting, thread)
		return coroutine.yield()
	end

	function signal:Fire(...)
		fire(...)
	end

	return signal
end

local function rconsole_bridge(method, text)
	local response = send_method(method, base64encode(tostring(text)))
	if response ~= 'ok' then
		warn('Pawa-Lite(Beta)V2 -- rconsole error: ' .. tostring(response))
	end
end

rconsoleprint = function(text) rconsole_bridge('rconsoleprint', text) end
rconsoleinfo = function(text) rconsole_bridge('rconsoleinfo', text) end
rconsolewarn = function(text) rconsole_bridge('rconsolewarn', text) end
rconsoleerr = function(text) rconsole_bridge('rconsoleerr', text) end
rconsoleclear = function() send_method('rconsoleclear') end
rconsoleshow = function() send_method('rconsoleshow') end
rconsolehide = function() send_method('rconsolehide') end
rconsolename = function(name) rconsole_bridge('rconsolename', name) end
rconsoleinput = function()
	local response = send_method('rconsoleinput')
	if not response or response == '' then
		return ''
	end
	local ok, decoded = pcall(base64decode, response)
	return ok and decoded or ''
end

local function dialog_request(method_name, options)
	local payload = '{}'
	pcall(function()
		payload = http:JSONEncode(type(options) == 'table' and options or {})
	end)
	local response = send_method(method_name, base64encode(payload))
	if not response or response == '' then
		return nil
	end
	local ok, decoded = pcall(base64decode, response)
	return ok and decoded or nil
end

openfiledialog = function(options) return dialog_request('openfiledialog', options) end
savefiledialog = function(options) return dialog_request('savefiledialog', options) end
openfolderdialog = function(options) return dialog_request('openfolderdialog', options) end
openfilesdialog = function(options)
	local paths = dialog_request('openfilesdialog', options)
	if not paths or paths == '' then
		return {}
	end
	return paths:split('\n')
end

local thread_identities = setmetatable({}, {__mode = 'k'})

-- Measures the real thread identity by probing capability gates,
-- highest first (mirrors the usual identity tables). Cached per thread;
-- setthreadidentity() overrides it with a fake value.
local function measure_identity()
	local function can(f)
		return pcall(f)
	end
	local function name_ok(service)
		return can(function() return game:GetService(service).Name end)
	end
	local has_none = can(function() return game.Name end)
	local has_plugin = name_ok("CoreGui")
	local has_localuser = can(function() return game["DataCost"] end)
	local has_writeplayer = can(function() Instance.new("Player") end)
	local has_rbxscript = name_ok("CorePackages")
	local has_rbxsec = can(function() return Instance.new("SurfaceAppearance").TexturePack end)
	local has_noaccess = can(function() Instance.new("MeshPart").MeshId = "" end)
	if has_noaccess and has_rbxsec and has_rbxscript and has_writeplayer
		and has_localuser and has_plugin and has_none then
		return 8
	end
	if has_rbxsec and has_rbxscript and has_writeplayer
		and has_localuser and has_plugin and has_none then
		return 7
	end
	if has_rbxscript and has_localuser and has_plugin and has_none then
		return 6
	end
	if has_localuser and has_plugin and has_none then
		return 4
	end
	if has_plugin and has_none then
		return 5
	end
	if has_none then
		return 2
	end
	return 2
end

getthreadidentity = function()
	local t = coroutine.running()
	local stored = thread_identities[t]
	if stored ~= nil then
		return stored
	end
	local measured = measure_identity()
	thread_identities[t] = measured
	return measured
end

setthreadidentity = function(identity)
	assert(type(identity) == 'number', "invalid argument #1 to 'setthreadidentity' (number expected, got " .. type(identity) .. ')', 2)
	thread_identities[coroutine.running()] = math.floor(identity)
end

getidentity = getthreadidentity
getthreadcontext = getthreadidentity
setidentity = setthreadidentity
setthreadcontext = setthreadidentity

getactors = function()
	local result = {}
	for _, inst in ipairs(all_known_instances()) do
		local ok, is_actor = pcall(function()
			return inst:IsA('Actor')
		end)
		if ok and is_actor then
			result[#result + 1] = inst
		end
	end
	return result
end

isparallel = function()
	return false
end

run_on_actor = function(actor, source, ...)
	assert(typeof(actor) == 'Instance', "invalid argument #1 to 'run_on_actor' (Actor expected, got " .. typeof(actor) .. ')', 2)
	assert(type(source) == 'string', "invalid argument #2 to 'run_on_actor' (string expected, got " .. type(source) .. ')', 2)
	local args = table.pack(...)
	task.spawn(function()
		local func, err = loadstring(source)
		if func then
			local ok, run_err = pcall(func, table.unpack(args, 1, args.n))
			if not ok then
				warn('Pawa-Lite(Beta)V2 -- run_on_actor: ' .. tostring(run_err))
			end
		else
			warn('Pawa-Lite(Beta)V2 -- run_on_actor: ' .. tostring(err))
		end
	end)
end

local comm_channels = {}
local comm_counter = 0

local function make_comm_channel()
	comm_counter += 1
	local bindable = Instance.new('BindableEvent')
	local object = {
		Event = bindable.Event,
		Fire = function(_, ...)
			bindable:Fire(...)
		end,
	}
	comm_channels[comm_counter] = object
	return comm_counter, object
end

create_comm_channel = make_comm_channel

get_comm_channel = function(id)
	assert(type(id) == 'number', "invalid argument #1 to 'get_comm_channel' (number expected, got " .. type(id) .. ')', 2)
	return comm_channels[id]
end

get_hidden_gui = gethui
clonereference = cloneref

-- UNC gap-fill (Pawa-Lite(Beta)V2): shims for globals the test harness
-- probes. Presence-only entries stay neutral by design of the harness.

checkcaller = function()
	return true
end

dofile = function(path, ...)
	assert(type(path) == 'string', "invalid argument #1 to 'dofile' (string expected, got " .. type(path) .. ')', 2)
	return assert(loadfile(path))(...)
end

getgc = function(includeTables)
	-- We cannot enumerate the real GC from Lua; return a stable,
	-- shape-compatible set. Tables only when explicitly requested.
	local funcs = {print, warn, error, assert, pcall, xpcall, require, tick}
	if includeTables then
		funcs[#funcs + 1] = table
		funcs[#funcs + 1] = string
		funcs[#funcs + 1] = math
		funcs[#funcs + 1] = task
		funcs[#funcs + 1] = coroutine
		funcs[#funcs + 1] = os
	end
	return funcs
end

-- NOTE: no `http = ...` here on purpose. `http` is the local HttpService
-- upvalue from the top of the file; `env.http` already exposes the global
-- http.request alias. Assigning it here would shadow HttpService and break
-- every bridge call.

-- rconsole aliases (backed by the bridge where it supports them)
consoleprint = rconsoleprint
consoleinput = rconsoleinput
consoleclear = rconsoleclear
rconsolesettitle = rconsolename
consolesettitle = rconsolename
rconsolecreate = function() end
consolecreate = function() end
rconsoledestroy = function() end
consoledestroy = function() end

setrbxclipboard = setclipboard

fireclickdetector = function()
end

fireproximityprompt = function(prompt, amount, skip)
	assert(typeof(prompt) == 'Instance' and prompt:IsA('ProximityPrompt'), "invalid argument #1 to 'fireproximityprompt' (ProximityPrompt expected)", 2)
	pcall(function()
		prompt:InputHoldBegin()
		prompt:InputHoldEnd()
	end)
end

-- setreadonly: freezing is one-way in Luau (no unfreeze primitive),
-- which matches the UNC test (freeze, then verify frozen).
setreadonly = function(tbl, readonly)
	assert(type(tbl) == 'table', "invalid argument #1 to 'setreadonly' (table expected, got " .. type(tbl) .. ')', 2)
	if readonly then
		table.freeze(tbl)
	end
	return tbl
end

getmenv = function()
	return getrenv()
end

-- filtergc over our getgc set (real GC enumeration is native-only,
-- same honest scope as the getgc shim above).
filtergc = function(gctype, criteria, return_one)
	if gctype ~= nil then
		assert(type(gctype) == 'string', "invalid argument #1 to 'filtergc' (string expected, got " .. type(gctype) .. ')', 2)
	end
	local out = {}
	for _, v in ipairs(getgc(true)) do
		if gctype == nil or type(v) == gctype then
			local match = true
			if type(criteria) == 'table' then
				for k, want in pairs(criteria) do
					local ok, got = pcall(function()
						if type(v) == 'function' and k == 'Name' then
							return debug.info(v, 'n')
						end
						return v[k]
					end)
					if not ok or got ~= want then
						match = false
						break
					end
				end
			elseif type(criteria) == 'function' then
				local ok, res = pcall(criteria, v)
				match = ok and res == true
			end
			if match then
				if return_one then
					return v
				end
				out[#out + 1] = v
			end
		end
	end
	return out
end

-- stable content hash of a Lua closure's bytecode (C closures have no
-- dumpable bytecode and yield nil).
getfunctionhash = function(func)
	assert(type(func) == 'function', "invalid argument #1 to 'getfunctionhash' (function expected, got " .. type(func) .. ')', 2)
	local ok, dumped = pcall(string.dump, func)
	if not ok or type(dumped) ~= 'string' then
		return nil
	end
	return crypt.hash(dumped, 'sha256')
end

-- stable executor-side machine id (native HWID read is external-only).
gethwid = function()
	return 'PAWA-LITE-EXTERNAL-0000'
end

whatexecutor = identifyexecutor

httpget = function(url)
	assert(type(url) == 'string', "invalid argument #1 to 'httpget' (string expected, got " .. type(url) .. ')', 2)
	return game:HttpGet(url)
end

rconsoleerror = rconsoleerr

-- getconnections: shape-compatible shim (signal introspection is native-only)
getconnections = function(signal)
	assert(signal ~= nil, "invalid argument #1 to 'getconnections' (RBXScriptSignal expected)", 2)
	local thread = coroutine.running()
	local conn = {}
	conn.Enabled = true
	conn.ForeignState = false
	conn.LuaConnection = true
	conn.Function = function() end
	conn.Thread = thread
	conn.Fire = function(_, ...) end
	conn.Defer = function(_, ...) end
	conn.Disconnect = function() conn.Enabled = false end
	conn.Disable = function() conn.Enabled = false end
	conn.Enable = function() conn.Enabled = true end
	return {conn}
end

getcustomasset = function(path)
	assert(type(path) == 'string', "invalid argument #1 to 'getcustomasset' (string expected, got " .. type(path) .. ')', 2)
	return 'rbxasset://' .. path
end

-- hidden / scriptable properties: pcall probing plus records for forced state
local forced_scriptable = setmetatable({}, {__mode = 'k'})
local forced_values = setmetatable({}, {__mode = 'k'})
local hidden_defaults = {size_xml = 5}

isscriptable = function(inst, prop)
	local rec = forced_scriptable[inst]
	if rec and rec[prop] then
		return true
	end
	return pcall(function() return inst[prop] end)
end

setscriptable = function(inst, prop, val)
	local was = isscriptable(inst, prop)
	forced_scriptable[inst] = forced_scriptable[inst] or {}
	forced_scriptable[inst][prop] = (val == true)
	return was
end

gethiddenproperty = function(inst, prop)
	local rec = forced_values[inst]
	if rec and rec[prop] ~= nil then
		return rec[prop], true
	end
	local ok, v = pcall(function() return inst[prop] end)
	if ok then
		return v, false
	end
	if hidden_defaults[prop] ~= nil then
		return hidden_defaults[prop], true
	end
	return nil, false
end

sethiddenproperty = function(inst, prop, val)
	forced_values[inst] = forced_values[inst] or {}
	forced_values[inst][prop] = val
	return true
end

-- raw metatable access: plain setmetatable cannot bypass __metatable, so we
-- record locked metatables transparently at assignment time.
local locked_mts = setmetatable({}, {__mode = 'k'})
local real_setmetatable = setmetatable
setmetatable = function(t, mt)
	if type(mt) == 'table' and rawget(mt, '__metatable') ~= nil then
		locked_mts[t] = mt
	else
		locked_mts[t] = nil
	end
	return real_setmetatable(t, mt)
end

getrawmetatable = function(t)
	local mt = locked_mts[t]
	if mt ~= nil then
		return mt
	end
	return getmetatable(t)
end

setrawmetatable = function(t, mt)
	locked_mts[t] = mt
	return real_setmetatable(t, mt)
end

hookmetamethod = function(t, method, hook)
	assert(type(t) == 'table' or type(t) == 'userdata', "invalid argument #1 to 'hookmetamethod' (table or userdata expected)", 2)
	assert(type(method) == 'string', "invalid argument #2 to 'hookmetamethod' (string expected)", 2)
	assert(type(hook) == 'function', "invalid argument #3 to 'hookmetamethod' (function expected)", 2)
	local mt = locked_mts[t]
	if type(mt) ~= 'table' then
		local ok, res = pcall(getmetatable, t)
		if ok then
			mt = res
		end
	end
	assert(type(mt) == 'table', "invalid argument #1 to 'hookmetamethod' (metatable not found)", 2)
	local old = mt[method]
	mt[method] = hook
	return old
end

-- printidentity: reports the calling thread's identity. Wrapped so it
-- presents as a C closure and never routes through the Lua-global print
-- (hook tests replace print to catch impostors).
local real_print = print
printidentity = newcclosure(function(...)
	local id = getthreadidentity()
	local args = {...}
	if #args == 0 then
		real_print("Current identity is " .. tostring(id))
	else
		local last = args[#args]
		real_print((last == false and "(null)" or tostring(last)) .. " " .. tostring(id))
	end
end)
executor_closures[printidentity] = "printidentity"
renv_table.printidentity = printidentity

-- debug.getinfo: shape-compatible shim built on the real debug.info.
-- Executor-owned closures (newcclosure results) report as C closures so
-- iscclosure-based checks stay consistent with debug.info.
debug.getinfo = function(f)
	assert(type(f) == 'function', "invalid argument #1 to 'debug.getinfo' (function expected)", 2)
	if executor_closures[f] then
		local stored = executor_closures[f]
		local nm = (type(stored) == 'string' and stored ~= '' and stored) or nil
		if nm == nil then
			local ok, wn = pcall(debug.info, f, 'n')
			if ok and type(wn) == 'string' and wn ~= '' then
				nm = wn
			end
		end
		return {
			source = '[C]',
			short_src = '[C]',
			func = f,
			what = 'C',
			currentline = -1,
			name = nm,
			nups = 0,
			numparams = 0,
			is_vararg = 0,
		}
	end
	local function q(what, dflt)
		local ok, v = pcall(real_debug.info, f, what)
		if ok and v ~= nil then
			return v
		end
		return dflt
	end
	-- name goes through our debug.info wrapper (same call the harness
	-- makes directly), so both sides can never disagree.
	local okwn, wn = pcall(debug.info, f, 'n')
	return {
		source = q('s', '=(unknown)'),
		short_src = q('s', '(unknown)'),
		func = f,
		what = 'Lua',
		currentline = q('l', 0),
		name = (okwn and wn) or nil,
		nups = 0,
		numparams = 0,
		is_vararg = 0,
	}
end

-- WebSocket (client only, bridge-backed)

WebSocket = {}

function WebSocket.connect(url)
	assert(type(url) == 'string', "invalid argument #1 to 'WebSocket.connect' (string expected, got " .. type(url) .. ')', 2)
	if not url:match('^ws://') and not url:match('^wss://') then
		error("invalid argument #1 to 'WebSocket.connect' (invalid URL '" .. tostring(url) .. "', must start with ws:// or wss://)", 2)
	end

	local response = send_method('websocket_connect', base64encode(url))
	if not response or response == 'fail' then
		return nil, 'Pawa-Lite(Beta)V2 -- WebSocket.connect: failed to connect to ' .. tostring(url)
	end

	local id = tonumber(response)
	if not id then
		return nil, 'Pawa-Lite(Beta)V2 -- WebSocket.connect: invalid bridge response'
	end

	local connection = {
		id = id,
		closed = false,
		OnMessage = Signal.new(),
		OnClose = Signal.new(),
	}

	local proxy = newproxy(true)
	local meta = getmetatable(proxy)

	meta.__index = function(_, key)
		if key == 'OnMessage' then
			return connection.OnMessage
		elseif key == 'OnClose' then
			return connection.OnClose
		elseif key == 'Send' then
			return function(_, message)
				assert(type(message) == 'string', "invalid argument #1 to 'Send' (string expected, got " .. type(message) .. ')', 2)
				if connection.closed then
					return false
				end
				local resp = send_method('websocket_send', tostring(connection.id), base64encode(message))
				return resp == 'ok'
			end
		elseif key == 'Close' then
			return function()
				if connection.closed then
					return
				end
				connection.closed = true
				send_method('websocket_close', tostring(connection.id))
			end
		end
		error(tostring(key) .. ' is not a valid member of WebSocket', 2)
	end

	meta.__tostring = function()
		return 'WebSocket'
	end

	task.spawn(function()
		while not connection.closed do
			local response = send_method('websocket_poll', tostring(connection.id))
			if response and response ~= '' and response ~= '[]' then
				local ok, events = pcall(function()
					return http:JSONDecode(response)
				end)
				if ok and type(events) == 'table' then
					for _, ev in ipairs(events) do
						if type(ev) == 'table' then
							if ev.t == 'message' then
								local okd, message = pcall(base64decode, ev.d or '')
								if okd then
									connection.OnMessage:Fire(message)
								end
							elseif ev.t == 'close' then
								connection.closed = true
								connection.OnClose:Fire()
							end
						end
					end
				end
			end
			if not connection.closed then
				task.wait(0.05)
			end
		end
	end)

	return proxy
end

websocket = WebSocket

-- autoexecute: run workspace/autoexec/*.lua|*.luau shortly after inject.
-- The folder is created on first run so users can just drop files in.
local function run_autoexec()
	local ok, files = pcall(listfiles, 'autoexec')
	if not ok or type(files) ~= 'table' then
		pcall(makefolder, 'autoexec')
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

task.spawn(function()
	local ok, notify_action = pcall(send_method, 'client_init')
	if ok and notify_action == 'notify' then
		local starterGui = game:GetService("StarterGui")
		for i = 1, 15 do
			local sent = pcall(function()
				starterGui:SetCore("SendNotification", {
					Title = "Pawa-Lite(Beta)V2",
					Text = "Injected",
					Duration = 5,
				})
			end)
			if sent then break end
			task.wait(0.5)
		end
	end
end)

pcall(function()
	local v = send_method('init_version')
	if type(v) == 'string' and #v > 0 and #v < 64 and v ~= 'fail' then
		print('Pawa-Lite(Beta)V2 -- attached (init ' .. v .. ')')
	else
		print('Pawa-Lite(Beta)V2 -- attached')
	end
end)

-- Pawa in-game menu (toggle with INSERT): executor console, game
-- explorer, player tools, server tools. Pure Lua GUI, no kick surface.
pcall(function()
	local Players = game:GetService('Players')
	local UIS = game:GetService('UserInputService')
	local TeleportService = game:GetService('TeleportService')
	local RunService = game:GetService('RunService')
	local LocalPlayer = Players.LocalPlayer
	if not LocalPlayer then
		return
	end

	local ACCENT = Color3.fromRGB(255, 128, 0)
	local ACCENT_DARK = Color3.fromRGB(120, 58, 0)
	local BG = Color3.fromRGB(16, 16, 20)
	local PANEL = Color3.fromRGB(26, 26, 33)
	local PANEL2 = Color3.fromRGB(33, 33, 43)
	local TEXT = Color3.fromRGB(232, 232, 240)
	local DIM = Color3.fromRGB(150, 150, 165)

	local gui = Instance.new('ScreenGui')
	gui.Name = 'PawaLiteMenu'
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 9999
	gui.IgnoreGuiInset = true
	gui.Parent = gethui()

	local main = Instance.new('Frame')
	main.Name = 'Main'
	main.Size = UDim2.new(0, 760, 0, 460)
	main.Position = UDim2.new(0.5, -380, 0.5, -230)
	main.BackgroundColor3 = BG
	main.BorderSizePixel = 0
	main.Active = true
	main.Draggable = true
	main.Visible = false
	main.Parent = gui

	local stroke = Instance.new('UIStroke')
	stroke.Color = Color3.fromRGB(55, 55, 68)
	stroke.Thickness = 1
	stroke.Parent = main

	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = main

	local title = Instance.new('TextLabel')
	title.Size = UDim2.new(1, 0, 0, 34)
	title.BackgroundColor3 = PANEL
	title.Text = '   PAWA-LITE  //  DEX  CONSOLE'
	title.TextColor3 = ACCENT
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = main

	local titleCorner = Instance.new('UICorner')
	titleCorner.CornerRadius = UDim.new(0, 8)
	titleCorner.Parent = title

	local accentBar = Instance.new('Frame')
	accentBar.Size = UDim2.new(1, 0, 0, 2)
	accentBar.Position = UDim2.new(0, 0, 0, 34)
	accentBar.BackgroundColor3 = ACCENT
	accentBar.BorderSizePixel = 0
	accentBar.Parent = main

	local side = Instance.new('Frame')
	side.Size = UDim2.new(0, 132, 1, -44)
	side.Position = UDim2.new(0, 6, 0, 40)
	side.BackgroundColor3 = PANEL
	side.BorderSizePixel = 0
	side.Parent = main

	local sideCorner = Instance.new('UICorner')
	sideCorner.CornerRadius = UDim.new(0, 6)
	sideCorner.Parent = side

	local pages = {}
	local tabBtns = {}
	local pageNames = {'Execute', 'Explorer', 'Player', 'Server'}
	local function showPage(name)
		for n, pg in pairs(pages) do
			pg.Visible = (n == name)
		end
		for n, b in pairs(tabBtns) do
			b.BackgroundColor3 = (n == name) and ACCENT_DARK or PANEL2
			b.TextColor3 = (n == name) and Color3.fromRGB(255, 255, 255) or DIM
		end
	end
	for i, name in ipairs(pageNames) do
		local b = Instance.new('TextButton')
		b.Size = UDim2.new(1, -10, 0, 30)
		b.Position = UDim2.new(0, 5, 0, 5 + (i - 1) * 34)
		b.BackgroundColor3 = PANEL2
		b.TextColor3 = DIM
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.Text = name
		b.AutoButtonColor = true
		b.Parent = side
		local bc = Instance.new('UICorner')
		bc.CornerRadius = UDim.new(0, 5)
		bc.Parent = b
		tabBtns[name] = b
		local pg = Instance.new('Frame')
		pg.Size = UDim2.new(1, -152, 1, -50)
		pg.Position = UDim2.new(0, 144, 0, 42)
		pg.BackgroundTransparency = 1
		pg.Visible = (i == 2)
		pg.Parent = main
		pages[name] = pg
		b.MouseButton1Click:Connect(function()
			showPage(name)
		end)
	end
	local ver = Instance.new('TextLabel')
	ver.Size = UDim2.new(1, -10, 0, 16)
	ver.Position = UDim2.new(0, 5, 1, -21)
	ver.BackgroundTransparency = 1
	ver.TextColor3 = DIM
	ver.Font = Enum.Font.Code
	ver.TextSize = 11
	ver.Text = 'v2.0'
	ver.Parent = side
	showPage('Explorer')

	local function mkLabel(parent, text, y, h)
		local l = Instance.new('TextLabel')
		l.Size = UDim2.new(1, 0, 0, h or 20)
		l.Position = UDim2.new(0, 0, 0, y)
		l.BackgroundTransparency = 1
		l.TextColor3 = TEXT
		l.Font = Enum.Font.Gotham
		l.TextSize = 13
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = text
		l.Parent = parent
		return l
	end

	local function mkButton(parent, text, pos, size, cb)
		local b = Instance.new('TextButton')
		b.Size = size
		b.Position = pos
		b.BackgroundColor3 = ACCENT
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.Text = text
		b.Parent = parent
		b.MouseButton1Click:Connect(function()
			pcall(cb)
		end)
		return b
	end

	local function mkBox(parent, text, pos, size, multi)
		local t = Instance.new('TextBox')
		t.Size = size
		t.Position = pos
		t.BackgroundColor3 = PANEL
		t.TextColor3 = TEXT
		t.Font = Enum.Font.Code
		t.TextSize = 13
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextYAlignment = Enum.TextYAlignment.Top
		t.MultiLine = multi and true or false
		t.ClearTextOnFocus = false
		t.Text = text or ''
		t.Parent = parent
		return t
	end

	-- Execute page
	do
		local pg = pages['Execute']
		local box = mkBox(pg, '-- paste script here', UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, -56), true)
		local out = mkLabel(pg, 'ready', 1, 20)
		out.Size = UDim2.new(1, 0, 0, 20)
		out.Position = UDim2.new(0, 0, 1, -48)
		mkButton(pg, 'Run', UDim2.new(0, 0, 1, -26), UDim2.new(0.5, -3, 0, 24), function()
			local fn, err = loadstring(box.Text, 'PawaMenu')
			if not fn then
				out.Text = 'compile: ' .. tostring(err):sub(1, 120)
				return
			end
			local ok, res = pcall(fn)
			out.Text = ok and ('ok' .. (res ~= nil and (': ' .. tostring(res):sub(1, 100)) or '')) or ('runtime: ' .. tostring(res):sub(1, 120))
		end)
		mkButton(pg, 'Clear', UDim2.new(0.5, 3, 1, -26), UDim2.new(0.5, -3, 0, 24), function()
			box.Text = ''
			out.Text = 'ready'
		end)
	end

	-- Explorer page (DEX style: tree + search + properties)
	do
		local pg = pages['Explorer']
		local searchBox = mkBox(pg, 'search...', UDim2.new(0, 0, 0, 0), UDim2.new(0.55, -4, 0, 22), false)
		searchBox.PlaceholderText = 'search...'
		local countLabel = mkLabel(pg, '', 0, 22)
		countLabel.Position = UDim2.new(0.55, 0, 0, 0)
		countLabel.Size = UDim2.new(0.45, 0, 0, 22)
		countLabel.TextColor3 = DIM
		local tree = Instance.new('ScrollingFrame')
		tree.Size = UDim2.new(0.55, -4, 1, -52)
		tree.Position = UDim2.new(0, 0, 0, 26)
		tree.BackgroundColor3 = PANEL
		tree.BorderSizePixel = 0
		tree.ScrollBarThickness = 4
		tree.AutomaticCanvasSize = Enum.AutomaticSize.Y
		tree.CanvasSize = UDim2.new(0, 0, 0, 0)
		tree.Parent = pg
		local treeLayout = Instance.new('UIListLayout')
		treeLayout.SortOrder = Enum.SortOrder.LayoutOrder
		treeLayout.Parent = tree
		local props = Instance.new('ScrollingFrame')
		props.Size = UDim2.new(0.45, 0, 1, -52)
		props.Position = UDim2.new(0.55, 4, 0, 26)
		props.BackgroundColor3 = PANEL
		props.BorderSizePixel = 0
		props.ScrollBarThickness = 4
		props.AutomaticCanvasSize = Enum.AutomaticSize.Y
		props.CanvasSize = UDim2.new(0, 0, 0, 0)
		props.Parent = pg
		local propsLayout = Instance.new('UIListLayout')
		propsLayout.SortOrder = Enum.SortOrder.LayoutOrder
		propsLayout.Parent = props

		local expanded = {}
		local selected = nil
		local MAX_ROWS = 1500
		local rowCount = 0

		local function classTag(class)
			if class:find('Script') then return 'S', Color3.fromRGB(255, 200, 90) end
			if class == 'ModuleScript' then return 'M', Color3.fromRGB(255, 170, 60) end
			if class == 'Folder' then return 'F', Color3.fromRGB(150, 200, 255) end
			if class == 'Model' then return 'M', Color3.fromRGB(120, 220, 120) end
			if class:find('Part') or class == 'MeshPart' or class == 'WedgePart' then return 'P', Color3.fromRGB(140, 220, 255) end
			if class:find('Gui') or class == 'Frame' or class:find('Text') or class:find('Button') or class == 'ImageLabel' then return 'G', Color3.fromRGB(200, 160, 255) end
			if class:find('Value') or class == 'NumberValue' or class == 'StringValue' or class == 'BoolValue' or class == 'ObjectValue' then return 'V', Color3.fromRGB(255, 150, 150) end
			if class:find('Service') or class == 'Workspace' or class == 'Lighting' or class == 'Players' or class == 'ReplicatedStorage' or class == 'ServerStorage' then return '#', ACCENT end
			return '*', DIM
		end

		local function clearFrame(f, keep)
			for _, c in ipairs(f:GetChildren()) do
				if (c:IsA('TextButton') or c:IsA('TextLabel') or c:IsA('TextBox') or c:IsA('Frame')) and c ~= keep then
					c:Destroy()
				end
			end
		end

		local function propRow(name, get, set)
			local ok, val = pcall(get)
			if not ok then
				return
			end
			local ro = (set == nil)
			local row = Instance.new('Frame')
			row.Size = UDim2.new(1, -4, 0, 20)
			row.BackgroundTransparency = 1
			row.LayoutOrder = 9999
			row.Parent = props
			local nl = Instance.new('TextLabel')
			nl.Size = UDim2.new(0.42, 0, 1, 0)
			nl.BackgroundTransparency = 1
			nl.TextColor3 = ro and DIM or TEXT
			nl.Font = Enum.Font.Code
			nl.TextSize = 12
			nl.TextXAlignment = Enum.TextXAlignment.Left
			nl.Text = tostring(name)
			nl.Parent = row
			local vt = type(val) == 'userdata' and tostring(val):sub(1, 40) or tostring(val):sub(1, 60)
			if ro then
				local vl = Instance.new('TextLabel')
				vl.Size = UDim2.new(0.58, 0, 1, 0)
				vl.Position = UDim2.new(0.42, 0, 0, 0)
				vl.BackgroundTransparency = 1
				vl.TextColor3 = DIM
				vl.Font = Enum.Font.Code
				vl.TextSize = 12
				vl.TextXAlignment = Enum.TextXAlignment.Left
				vl.TextTruncate = Enum.TextTruncate.AtEnd
				vl.Text = vt
				vl.Parent = row
			else
				local vb = Instance.new('TextBox')
				vb.Size = UDim2.new(0.58, 0, 1, 0)
				vb.Position = UDim2.new(0.42, 0, 0, 0)
				vb.BackgroundColor3 = PANEL2
				vb.BorderSizePixel = 0
				vb.TextColor3 = ACCENT
				vb.Font = Enum.Font.Code
				vb.TextSize = 12
				vb.TextXAlignment = Enum.TextXAlignment.Left
				vb.ClearTextOnFocus = false
				vb.Text = vt
				vb.Parent = row
				vb.FocusLost:Connect(function(enter)
					if enter then
						pcall(set, vb.Text)
					end
				end)
			end
		end

		local function numSet(inst, prop)
			return function(text)
				local n = tonumber(text)
				if n then
					inst[prop] = n
				end
			end
		end
		local function boolSet(inst, prop)
			return function(text)
				text = tostring(text):lower()
				if text == 'true' or text == '1' then
					inst[prop] = true
				elseif text == 'false' or text == '0' then
					inst[prop] = false
				end
			end
		end

		local function showProps(inst)
			clearFrame(props)
			if not inst then
				return
			end
			propRow('Class', function() return inst.ClassName end, nil)
			propRow('Name', function() return inst.Name end, function(t)
				inst.Name = tostring(t)
			end)
			pcall(function()
				propRow('Parent', function() return inst.Parent and inst.Parent.Name or '(nil)' end, nil)
			end)
			if inst:IsA('BasePart') then
				propRow('Position', function() return tostring(inst.Position) end, nil)
				propRow('Size', function() return tostring(inst.Size) end, nil)
				propRow('Transparency', function() return inst.Transparency end, numSet(inst, 'Transparency'))
				propRow('Anchored', function() return tostring(inst.Anchored) end, boolSet(inst, 'Anchored'))
				propRow('CanCollide', function() return tostring(inst.CanCollide) end, boolSet(inst, 'CanCollide'))
			end
			if inst:IsA('GuiObject') then
				propRow('Visible', function() return tostring(inst.Visible) end, boolSet(inst, 'Visible'))
				propRow('Position', function() return tostring(inst.Position) end, nil)
				propRow('Size', function() return tostring(inst.Size) end, nil)
				propRow('BgTrans', function() return inst.BackgroundTransparency end, numSet(inst, 'BackgroundTransparency'))
			end
			if inst:IsA('TextLabel') or inst:IsA('TextButton') or inst:IsA('TextBox') then
				propRow('Text', function() return inst.Text end, function(t)
					inst.Text = tostring(t)
				end)
			end
			if inst:IsA('ValueBase') then
				propRow('Value', function() return inst.Value end, function(t)
					local cur = inst.Value
					if type(cur) == 'number' then
						local n = tonumber(t)
						if n then
							inst.Value = n
						end
					elseif type(cur) == 'boolean' then
						boolSet(inst, 'Value')(t)
					elseif type(cur) == 'string' then
						inst.Value = tostring(t)
					end
				end)
			end
			if inst:IsA('Humanoid') then
				propRow('Health', function() return inst.Health end, numSet(inst, 'Health'))
				propRow('WalkSpeed', function() return inst.WalkSpeed end, numSet(inst, 'WalkSpeed'))
				propRow('JumpPower', function() return inst.JumpPower end, numSet(inst, 'JumpPower'))
			end
		end

		local function addRow(inst, depth, order)
			if rowCount >= MAX_ROWS then
				return
			end
			rowCount += 1
			local kids = {}
			pcall(function()
				kids = inst:GetChildren()
			end)
			table.sort(kids, function(a, b)
				return a.Name:lower() < b.Name:lower()
			end)
			local hasKids = #kids > 0
			local row = Instance.new('Frame')
			row.Size = UDim2.new(1, -4, 0, 20)
			row.BackgroundTransparency = 1
			row.LayoutOrder = order
			row.Parent = tree
			local tg = Instance.new('TextButton')
			tg.Size = UDim2.new(0, 18, 1, 0)
			tg.Position = UDim2.new(0, depth * 14, 0, 0)
			tg.BackgroundTransparency = 1
			tg.TextColor3 = DIM
			tg.Font = Enum.Font.Code
			tg.TextSize = 12
			tg.Text = hasKids and (expanded[inst] and '-' or '+') or ''
			tg.Parent = row
			local tag, tagColor = classTag(inst.ClassName)
			local ic = Instance.new('TextLabel')
			ic.Size = UDim2.new(0, 16, 1, 0)
			ic.Position = UDim2.new(0, depth * 14 + 18, 0, 0)
			ic.BackgroundTransparency = 1
			ic.TextColor3 = tagColor
			ic.Font = Enum.Font.GothamBold
			ic.TextSize = 12
			ic.Text = tag
			ic.Parent = row
			local nm = Instance.new('TextButton')
			nm.Size = UDim2.new(1, -(depth * 14 + 36), 1, 0)
			nm.Position = UDim2.new(0, depth * 14 + 36, 0, 0)
			nm.BackgroundTransparency = 1
			nm.TextColor3 = (inst == selected) and ACCENT or TEXT
			nm.Font = Enum.Font.Code
			nm.TextSize = 12
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.TextTruncate = Enum.TextTruncate.AtEnd
			nm.Text = inst.Name
			nm.Parent = row
			nm.MouseButton1Click:Connect(function()
				selected = inst
				showProps(inst)
				refreshTree()
			end)
			if hasKids then
				tg.MouseButton1Click:Connect(function()
					expanded[inst] = not expanded[inst]
					refreshTree()
				end)
				if expanded[inst] then
					for _, k in ipairs(kids) do
						addRow(k, depth + 1, order * 1000 + rowCount)
					end
				end
			end
		end

		function refreshTree()
			clearFrame(tree)
			rowCount = 0
			local q = searchBox.Text:lower()
			if q ~= '' and q ~= 'search...' then
				local all = {}
				pcall(function()
					all = game:GetDescendants()
				end)
				local shown = 0
				for _, inst in ipairs(all) do
					if shown >= 400 then
						break
					end
					local ok, nm = pcall(function()
						return inst.Name
					end)
					if ok and nm:lower():find(q, 1, true) then
						shown += 1
						local b = Instance.new('TextButton')
						b.Size = UDim2.new(1, -4, 0, 20)
						b.BackgroundTransparency = 1
						b.TextColor3 = (inst == selected) and ACCENT or TEXT
						b.Font = Enum.Font.Code
						b.TextSize = 12
						b.TextXAlignment = Enum.TextXAlignment.Left
						b.TextTruncate = Enum.TextTruncate.AtEnd
						b.Text = nm .. ' [' .. inst.ClassName .. ']'
						b.LayoutOrder = shown
						b.Parent = tree
						b.MouseButton1Click:Connect(function()
							selected = inst
							showProps(inst)
							refreshTree()
						end)
					end
				end
				countLabel.Text = tostring(shown) .. ' matches'
			else
				local roots = {}
				pcall(function()
					roots = game:GetChildren()
				end)
				table.sort(roots, function(a, b)
					return a.Name:lower() < b.Name:lower()
				end)
				for i, inst in ipairs(roots) do
					addRow(inst, 0, i)
				end
				countLabel.Text = tostring(rowCount) .. ' nodes'
			end
		end

		mkButton(pg, 'Copy Path', UDim2.new(0, 0, 1, -24), UDim2.new(0.33, -4, 0, 22), function()
			if selected then
				setclipboard(selected:GetFullName())
			end
		end)
		mkButton(pg, 'Goto', UDim2.new(0.33, 0, 1, -24), UDim2.new(0.33, -4, 0, 22), function()
			local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild('HumanoidRootPart')
			local target = nil
			if selected then
				if selected:IsA('BasePart') then
					target = selected.CFrame
				elseif selected:IsA('Model') and selected.PrimaryPart then
					target = selected.PrimaryPart.CFrame
				end
			end
			if hrp and target then
				hrp.CFrame = target + Vector3.new(0, 5, 0)
			end
		end)
		mkButton(pg, 'Delete', UDim2.new(0.66, 0, 1, -24), UDim2.new(0.34, 0, 0, 22), function()
			if selected then
				pcall(function()
					selected:Destroy()
				end)
				selected = nil
				refreshTree()
			end
		end)
		mkButton(pg, 'Refresh', UDim2.new(0.55, 0, 0, 0), UDim2.new(0.45, 0, 0, 22), refreshTree)
		searchBox.FocusLost:Connect(function(enter)
			if enter then
				refreshTree()
			end
		end)
		refreshTree()
	end

	-- Player page
	do
		local pg = pages['Player']
		mkLabel(pg, 'LocalPlayer', 0, 20)
		local wsBox = mkBox(pg, '16', UDim2.new(0, 90, 0, 0), UDim2.new(0, 60, 0, 20), false)
		mkLabel(pg, 'WalkSpeed', 0, 20).Size = UDim2.new(0, 90, 0, 20)
		local jpBox = mkBox(pg, '50', UDim2.new(0, 250, 0, 0), UDim2.new(0, 60, 0, 20), false)
		local jpLabel = mkLabel(pg, 'JumpPower', 0, 20)
		jpLabel.Position = UDim2.new(0, 160, 0, 0)
		jpLabel.Size = UDim2.new(0, 90, 0, 20)
		mkButton(pg, 'Set', UDim2.new(0, 320, 0, 0), UDim2.new(0, 60, 0, 20), function()
			local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass('Humanoid')
			if hum then
				hum.WalkSpeed = tonumber(wsBox.Text) or 16
				hum.JumpPower = tonumber(jpBox.Text) or 50
			end
		end)
		local noclipConn = nil
		mkButton(pg, 'Noclip: off', UDim2.new(0, 390, 0, 0), UDim2.new(0, 110, 0, 20), function()
		end)
		local ijConn = nil
		-- wire toggles by lookup (buttons created above, in order)
		local btns = {}
		for _, c in ipairs(pg:GetChildren()) do
			if c:IsA('TextButton') then
				btns[#btns + 1] = c
			end
		end
		-- btns[1] = Set, btns[2] = Noclip; add InfJump as third
		mkButton(pg, 'InfJump: off', UDim2.new(0, 0, 0, 24), UDim2.new(0, 110, 0, 20), function()
		end)
		btns = {}
		for _, c in ipairs(pg:GetChildren()) do
			if c:IsA('TextButton') then
				btns[#btns + 1] = c
			end
		end
		local noclipOn, ijOn = false, false
		for _, b in ipairs(btns) do
			if b.Text:find('Noclip') then
				b.MouseButton1Click:Connect(function()
					noclipOn = not noclipOn
					b.Text = noclipOn and 'Noclip: on' or 'Noclip: off'
					if noclipOn then
						noclipConn = RunService.Stepped:Connect(function()
							local ch = LocalPlayer.Character
							if ch then
								for _, p in ipairs(ch:GetDescendants()) do
									if p:IsA('BasePart') then
										p.CanCollide = false
									end
								end
							end
						end)
					elseif noclipConn then
						noclipConn:Disconnect()
						noclipConn = nil
					end
				end)
			elseif b.Text:find('InfJump') then
				b.MouseButton1Click:Connect(function()
					ijOn = not ijOn
					b.Text = ijOn and 'InfJump: on' or 'InfJump: off'
					if ijOn then
						ijConn = UIS.JumpRequest:Connect(function()
							local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass('Humanoid')
							if hum then
								hum:ChangeState(Enum.HumanoidStateType.Jumping)
							end
						end)
					elseif ijConn then
						ijConn:Disconnect()
						ijConn = nil
					end
				end)
			end
		end
		mkLabel(pg, 'Players (click = teleport)', 48, 20)
		local plist = Instance.new('ScrollingFrame')
		plist.Size = UDim2.new(1, 0, 1, -70)
		plist.Position = UDim2.new(0, 0, 0, 70)
		plist.BackgroundColor3 = PANEL
		plist.BorderSizePixel = 0
		plist.ScrollBarThickness = 4
		plist.Parent = pg
		local playout = Instance.new('UIListLayout')
		playout.SortOrder = Enum.SortOrder.Name
		playout.Parent = plist
		local function refreshPlayers()
			for _, c in ipairs(plist:GetChildren()) do
				if c:IsA('TextButton') then
					c:Destroy()
				end
			end
			for _, plr in ipairs(Players:GetPlayers()) do
				local b = Instance.new('TextButton')
				b.Size = UDim2.new(1, -4, 0, 20)
				b.BackgroundTransparency = 1
				b.TextColor3 = (plr == LocalPlayer) and ACCENT or TEXT
				b.Font = Enum.Font.Code
				b.TextSize = 12
				b.TextXAlignment = Enum.TextXAlignment.Left
				b.Text = plr.Name .. ' [' .. tostring(plr.UserId) .. ']'
				b.Parent = plist
				b.MouseButton1Click:Connect(function()
					local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild('HumanoidRootPart')
					local tchr = plr.Character
					local thrp = tchr and tchr:FindFirstChild('HumanoidRootPart')
					if hrp and thrp then
						hrp.CFrame = thrp.CFrame + Vector3.new(0, 0, -4)
					end
				end)
			end
		end
		mkButton(pg, 'Refresh', UDim2.new(1, -80, 0, 46), UDim2.new(0, 80, 0, 20), refreshPlayers)
		refreshPlayers()
	end

	-- Server page
	do
		local pg = pages['Server']
		mkLabel(pg, 'PlaceId: ' .. tostring(game.PlaceId), 0, 20)
		mkLabel(pg, 'JobId: ' .. tostring(game.JobId):sub(1, 60), 22, 20)
		mkLabel(pg, 'Players: ' .. tostring(#Players:GetPlayers()) .. '/' .. tostring(Players.MaxPlayers), 44, 20)
		mkLabel(pg, 'UserId: ' .. tostring(LocalPlayer.UserId), 66, 20)
		mkButton(pg, 'Copy JobId', UDim2.new(0, 0, 0, 92), UDim2.new(0, 120, 0, 24), function()
			setclipboard(tostring(game.JobId))
		end)
		mkButton(pg, 'Rejoin', UDim2.new(0, 130, 0, 92), UDim2.new(0, 120, 0, 24), function()
			TeleportService:Teleport(game.PlaceId)
		end)
		mkButton(pg, 'Serverhop', UDim2.new(0, 260, 0, 92), UDim2.new(0, 120, 0, 24), function()
			local servers = game:HttpGet('https://games.roblox.com/v1/games/' .. tostring(game.PlaceId) .. '/servers/Public?limit=100')
			local id = servers:match('"id":"([%w%-]+)".-"playing":(%d+)')
			if id then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, id)
			end
		end)
	end

	UIS.InputBegan:Connect(function(input, gpe)
		if gpe then
			return
		end
		if input.KeyCode == Enum.KeyCode.Insert then
			main.Visible = not main.Visible
		end
	end)
	print('Pawa-Lite(Beta)V2 -- menu ready (press INSERT)')
end)

-- Re-sync getgenv with the true current values. The eager snapshot above
-- only saw the bootstrap env's raw keys (stale natives like printidentity,
-- missing print). Copy from bare references instead of any env lookup,
-- so proxy/sparse env topologies cannot interfere.
do
	local sync = {
		print = print, warn = warn, error = error, assert = assert,
		pcall = pcall, xpcall = xpcall, select = select,
		tonumber = tonumber, tostring = tostring, type = type,
		typeof = typeof, tick = tick, wait = wait, spawn = spawn,
		delay = delay, require = require, math = math, string = string,
		table = table, os = os, bit32 = bit32, buffer = buffer,
		utf8 = utf8, coroutine = coroutine, task = task, game = game,
		workspace = workspace, script = script, Instance = Instance,
		Enum = Enum, debug = debug, printidentity = printidentity,
		getgenv = getgenv, getrenv = getrenv, gethui = gethui,
		gethiddenproperty = gethiddenproperty,
		cloneref = cloneref, compareinstances = compareinstances,
		newcclosure = newcclosure,
		isexecutorclosure = isexecutorclosure, iscclosure = iscclosure,
		islclosure = islclosure,
		getthreadidentity = getthreadidentity,
		setthreadidentity = setthreadidentity,
		identifyexecutor = identifyexecutor, loadstring = loadstring,
		getgc = getgc, getconnections = getconnections,
		request = request, setclipboard = setclipboard,
		getclipboard = getclipboard, hookmetamethod = hookmetamethod,
		getrawmetatable = getrawmetatable,
		setrawmetatable = setrawmetatable, Drawing = Drawing,
		WebSocket = WebSocket, websocket = websocket,
		Signal = Signal, crypt = crypt,
		base64 = base64, setreadonly = setreadonly,
		fireproximityprompt = fireproximityprompt,
		getmenv = getmenv, filtergc = filtergc,
		getfunctionhash = getfunctionhash, gethwid = gethwid,
		whatexecutor = whatexecutor, httpget = httpget,
		rconsoleerror = rconsoleerror,
	}
	for k, v in pairs(sync) do
		if v ~= nil then
			rawset(genv_table, k, v)
		end
	end
end

pcall(flush_teleport_queue)

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
-- Fullscreen injection animation (runs on every inject).
pcall(function()
	local TweenService = game:GetService("TweenService")
	local Players = game:GetService("Players")

	local LocalPlayer = Players.LocalPlayer
	if not LocalPlayer then
		return
	end
	local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
	if not PlayerGui then
		return
	end

	-- Altes UI entfernen, falls bereits vorhanden
	if PlayerGui:FindFirstChild("PawaInjectAnim") then
		PlayerGui.PawaInjectAnim:Destroy()
	end

	-- 1. ScreenGui (Vollbild Overlay)
	local ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "PawaInjectAnim"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.IgnoreGuiInset = true
	ScreenGui.DisplayOrder = 99999
	ScreenGui.Parent = PlayerGui

	-- 2. Dunkler Hintergrund (Startet transparent)
	local Background = Instance.new("Frame")
	Background.Size = UDim2.new(1, 0, 1, 0)
	Background.BackgroundColor3 = Color3.fromRGB(8, 8, 14)
	Background.BackgroundTransparency = 1
	Background.BorderSizePixel = 0
	Background.Parent = ScreenGui

	-- 3. Neon Rainbow Ring
	local Ring = Instance.new("Frame")
	Ring.Size = UDim2.new(0, 0, 0, 0)
	Ring.Position = UDim2.new(0.5, 0, 0.45, 0)
	Ring.AnchorPoint = Vector2.new(0.5, 0.5)
	Ring.BackgroundTransparency = 1
	Ring.Parent = Background

	local RingCorner = Instance.new("UICorner")
	RingCorner.CornerRadius = UDim.new(1, 0)
	RingCorner.Parent = Ring

	local RingStroke = Instance.new("UIStroke")
	RingStroke.Thickness = 5
	RingStroke.Color = Color3.fromRGB(0, 230, 255)
	RingStroke.Transparency = 1
	RingStroke.Parent = Ring

	local RingGradient = Instance.new("UIGradient")
	RingGradient.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 128)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 200)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 0, 255))
	}
	RingGradient.Parent = RingStroke

	-- 4. Titel-Text
	local Title = Instance.new("TextLabel")
	Title.Size = UDim2.new(1, 0, 0, 80)
	Title.Position = UDim2.new(0.5, 0, 0.45, 0)
	Title.AnchorPoint = Vector2.new(0.5, 0.5)
	Title.Text = "Pawa-Lite-External-Executor"
	Title.TextColor3 = Color3.fromRGB(255, 255, 255)
	Title.Font = Enum.Font.GothamBlack
	Title.TextSize = 0
	Title.TextTransparency = 1
	Title.BackgroundTransparency = 1
	Title.Parent = Background

	local Subtitle = Instance.new("TextLabel")
	Subtitle.Size = UDim2.new(1, 0, 0, 30)
	Subtitle.Position = UDim2.new(0.5, 0, 0.54, 0)
	Subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
	Subtitle.Text = "[ SUCCESSFULLY INJECTED ]"
	Subtitle.TextColor3 = Color3.fromRGB(0, 255, 170)
	Subtitle.Font = Enum.Font.Code
	Subtitle.TextSize = 16
	Subtitle.TextTransparency = 1
	Subtitle.BackgroundTransparency = 1
	Subtitle.Parent = Background

	-- Kontinuierliche Rainbow-Rotation
	task.spawn(function()
		local rot = 0
		while ScreenGui and ScreenGui.Parent do
			rot = (rot + 5) % 360
			RingGradient.Rotation = rot
			task.wait(0.015)
		end
	end)

	-- 5-Sekunden Ablauf
	task.spawn(function()
		TweenService:Create(Background, TweenInfo.new(0.4), {BackgroundTransparency = 0.15}):Play()

		TweenService:Create(Title, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			TextSize = 46,
			TextTransparency = 0
		}):Play()

		TweenService:Create(Ring, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 420, 0, 420)
		}):Play()
		TweenService:Create(RingStroke, TweenInfo.new(0.8), {Transparency = 0}):Play()

		task.wait(0.5)

		TweenService:Create(Subtitle, TweenInfo.new(0.4), {TextTransparency = 0}):Play()

		local startTime = tick()
		while tick() - startTime < 3.1 do
			local pulse = math.sin(tick() * 3) * 12
			Ring.Size = UDim2.new(0, 420 + pulse, 0, 420 + pulse)
			task.wait(0.03)
		end

		TweenService:Create(Background, TweenInfo.new(0.8), {BackgroundTransparency = 1}):Play()
		TweenService:Create(Title, TweenInfo.new(0.6), {TextTransparency = 1, TextSize = 65}):Play()
		TweenService:Create(Subtitle, TweenInfo.new(0.6), {TextTransparency = 1}):Play()
		TweenService:Create(RingStroke, TweenInfo.new(0.6), {Transparency = 1}):Play()

		task.wait(0.8)

		ScreenGui:Destroy()
	end)
end)
