local http = game:GetService("HttpService")
local bridge = "http://localhost:9475"

local function bridge_request(method)
	local result = nil

	local ok = pcall(function()
		http:RequestInternal({
			Url = bridge,
			Method = "POST",
			Body = method,
			Headers = {
				["Content-Type"] = "text/plain"
			}
		}):Start(function(s, b)
			result = b
			result["Success"] = s
		end)
	end)

	if not ok then
		return nil
	end

	repeat task.wait() until result

	if not result or not result.Success then
		return nil
	end

	return result.Body
end

local namecall_registry = setmetatable({}, {__mode = "k"})

local function namecall_handler(method, self, ...)
	if typeof(self) ~= "table" then
		return false
	end

	local mt = getmetatable(self)
	local nc = type(mt) == "table" and rawget(mt, "__namecall")
	if type(nc) == "function" and debug.info(nc, 's') then
		namecall_registry[coroutine.running()] = method
		return true, nc(self, ...)
	end
	return false
end

getnamecallmethod = function()
	return namecall_registry[coroutine.running()]
end

load_bytecode = function(bytecode, env)
	local settings = fiu.luau_newsettings()
	settings.vectorCtor = Vector3.new
	settings.useNativeNamecall = true
	settings.namecallHandler = namecall_handler

	return (fiu.luau_load(bytecode, env or getfenv(), settings))
end

-- executor introspection helpers, published as globals so init.luau and user
-- scripts can use them (on an old init.bin these resolve to nil and every
-- consumer falls back gracefully, so this file stays backward compatible)
pawa_dbg = {
	isemulated = fiu.luau_isemulated,
	getfuncdata = fiu.luau_getfuncdata,
	getconstants = fiu.luau_getconstants,
	getconstant = fiu.luau_getconstant,
	setconstant = fiu.luau_setconstant,
	getprotofunc = fiu.luau_getprotofunc,
	getprotos = fiu.luau_getprotos,
	hookfunction = fiu.luau_hookfunction,
	restorefunction = fiu.luau_restorefunction,
	gcfuncs = fiu.luau_gcfuncs,
	gctables = fiu.luau_gctables,
	getstackframe = fiu.luau_getstackframe,
	signalconnections = fiu.luau_signalconnections,
	rawmetatable = fiu.luau_rawmetatable,
	unfreeze = fiu.luau_unfreeze,
	isfrozen = fiu.luau_isfrozen,
	invalidate = fiu.luau_invalidate,
	isinvalidated = fiu.luau_isinvalidated,
	callbackvalue = fiu.luau_callbackvalue,
	loadedmodules = fiu.luau_loadedmodules,
	createdinstances = fiu.luau_createdinstances,
	createdthreads = fiu.luau_createdthreads,
	calloriginal = fiu.luau_calloriginal,
	checkcaller = fiu.luau_checkcaller,
	wrapstats = fiu.luau_wrapstats,
	namelog = fiu.luau_namelog,
}

task.spawn(function()
	while true do
		local bytecode = bridge_request("getinitraw")

		if bytecode then
			local ok, func = pcall(load_bytecode, bytecode, getfenv())

			if ok and func then
				local ran, err = pcall(func)

				if not ran then
					warn("Pawa bootstrap: init.luau error: " .. tostring(err))
				end

				break
			elseif ok then
				warn("Pawa bootstrap: init.luau failed to load (bridge/bytecode mismatch?)")
			else
				warn("Pawa bootstrap: " .. tostring(func))
			end
		end

		task.wait(2)
	end
end)

return setmetatable({}, {
	__index = function()
		return function() end
	end
})
