local environment = getgenv() or getfenv() or {}
local HttpService = game:GetService("HttpService")

local Platform = {}
Platform.__index = Platform

local function normalizeSlashes(path)
	path = tostring(path or "")
	path = path:gsub("\\", "/")
	path = path:gsub("^%./", "")
	path = path:gsub("^/+", "")
	path = path:gsub("/+", "/")
	path = path:gsub("/$", "")
	return path
end

local function trimRoot(path, rootName)
	local normalized = normalizeSlashes(path)
	local rootLower = string.lower(rootName)
	local normalizedLower = string.lower(normalized)
	local rootPrefix = rootLower .. "/"

	if normalizedLower == rootLower then
		return ""
	end

	if normalizedLower:sub(1, #rootPrefix) == rootPrefix then
		return normalized:sub(#rootPrefix + 1)
	end

	return normalized
end

local function startsWith(value, prefix)
	return value:sub(1, #prefix) == prefix
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end

	local clone = {}
	for key, child in pairs(value) do
		clone[key] = deepCopy(child)
	end
	return clone
end

local function merge(defaults, overrides)
	if type(defaults) ~= "table" then
		return overrides == nil and defaults or overrides
	end

	local result = deepCopy(defaults)
	if type(overrides) ~= "table" then
		return result
	end

	for key, value in pairs(overrides) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = merge(result[key], value)
		else
			result[key] = deepCopy(value)
		end
	end

	return result
end

local function getRequestFunction()
	return environment.request
		or environment.http_request
		or (environment.syn and environment.syn.request)
		or (environment.http and environment.http.request)
		or (environment.fluxus and environment.fluxus.request)
end

local function extractInviteCode(value)
	value = tostring(value or "")
	return value:match("discord%%.gg/([%w_-]+)")
		or value:match("discord%%.com/invite/([%w_-]+)")
		or value:match("^([%w_-]+)$")
		or ""
end

local function isSuccessfulResponse(response)
	local statusCode = tonumber(response and response.StatusCode)
	if statusCode == nil then
		return response ~= nil
	end

	return statusCode >= 200 and statusCode < 300
end

local File = {}
File.__index = File

function File.new(rootName, logger)
	return setmetatable({
		rootName = rootName or "Phantom",
		logger = logger,
	}, File)
end

function File:GetRoot()
	return self.rootName
end

function File:Relative(path)
	return trimRoot(path, self.rootName)
end

function File:Resolve(path)
	local relative = self:Relative(path)
	if relative == "" then
		return self.rootName
	end
	return self.rootName .. "/" .. relative
end

function File:IsProtected(path)
	local relative = self:Relative(path)
	return startsWith(relative, "config/") or startsWith(relative, "configs/")
end

function File:Exists(path)
	local fullPath = self:Resolve(path)
	return isfile(fullPath) or isfolder(fullPath)
end

function File:IsFile(path)
	return isfile(self:Resolve(path))
end

function File:IsFolder(path)
	return isfolder(self:Resolve(path))
end

function File:MakeFolder(path)
	local relative = self:Relative(path)
	local current = self.rootName

	if not isfolder(current) then
		local ok, err = pcall(makefolder, current)
		if not ok and self.logger then
			self.logger:Warn("failed to create folder", current, err)
		end
	end

	if relative == "" then
		return true
	end

	for segment in relative:gmatch("[^/]+") do
		current = current .. "/" .. segment
		if not isfolder(current) then
			local ok, err = pcall(makefolder, current)
			if not ok then
				if self.logger then
					self.logger:Warn("failed to create folder", current, err)
				end
				return false, err
			end
		end
	end

	return true
end

function File:_ensureParent(path)
	local relative = self:Relative(path)
	local parent = relative:match("^(.*)/[^/]+$")
	if parent and parent ~= "" then
		return self:MakeFolder(parent)
	end
	return self:MakeFolder("")
end

function File:Read(path, defaultValue)
	local fullPath = self:Resolve(path)
	if not isfile(fullPath) then
		return defaultValue
	end

	local ok, contents = pcall(readfile, fullPath)
	if ok then
		return contents
	end

	if self.logger then
		self.logger:Warn("failed to read file", fullPath, contents)
	end

	return defaultValue
end

function File:Write(path, data, options)
	options = options or {}
	local fullPath = self:Resolve(path)

	if self:IsProtected(path) and isfile(fullPath) and not options.force then
		return false, "protected path"
	end

	local ok, err = self:_ensureParent(path)
	if not ok then
		return false, err
	end

	ok, err = pcall(writefile, fullPath, tostring(data or ""))
	if not ok and self.logger then
		self.logger:Warn("failed to write file", fullPath, err)
	end

	return ok, err
end

function File:Append(path, data, options)
	options = options or {}
	local fullPath = self:Resolve(path)

	if self:IsProtected(path) and isfile(fullPath) and not options.force then
		return false, "protected path"
	end

	local ok, err = self:_ensureParent(path)
	if not ok then
		return false, err
	end

	if appendfile then
		ok, err = pcall(appendfile, fullPath, tostring(data or ""))
	else
		local existing = self:Read(path, "")
		ok, err = self:Write(path, existing .. tostring(data or ""), { force = true })
	end

	if not ok and self.logger then
		self.logger:Warn("failed to append file", fullPath, err)
	end

	return ok, err
end

function File:Delete(path)
	local fullPath = self:Resolve(path)
	if isfile(fullPath) and delfile then
		return pcall(delfile, fullPath)
	end
	if isfolder(fullPath) and delfolder then
		return pcall(delfolder, fullPath)
	end
	return false, "unsupported delete operation"
end

function File:ListFiles(path)
	local fullPath = self:Resolve(path)
	if not isfolder(fullPath) then
		return {}
	end

	local ok, items = pcall(listfiles, fullPath)
	if not ok or type(items) ~= "table" then
		if self.logger then
			self.logger:Warn("failed to list files", fullPath, items)
		end
		return {}
	end

	local normalized = {}
	for _, item in ipairs(items) do
		normalized[#normalized + 1] = normalizeSlashes(item)
	end

	table.sort(normalized)
	return normalized
end

function File:ReadJson(path, defaultValue)
	local contents = self:Read(path)
	if not contents or contents == "" then
		return defaultValue
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(contents)
	end)

	if ok then
		return decoded
	end

	if self.logger then
		self.logger:Warn("failed to decode json", path, decoded)
	end

	return defaultValue
end

function File:WriteJson(path, data, options)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not ok then
		if self.logger then
			self.logger:Warn("failed to encode json", path, encoded)
		end
		return false, encoded
	end

	return self:Write(path, encoded, options)
end

function File:EnsureRuntimeFolders()
	self:MakeFolder("")
	self:MakeFolder("assets")
	self:MakeFolder("assets/icons")
	self:MakeFolder("cache")
	self:MakeFolder("config")
	self:MakeFolder("configs")
	self:MakeFolder("games")
	self:MakeFolder("lib")
	self:MakeFolder("lib/core")
	self:MakeFolder("scripts")
end

local Http = {}
Http.__index = Http

function Http.new(logger)
	return setmetatable({
		logger = logger,
	}, Http)
end

function Http:Request(options)
	local requestFunction = getRequestFunction()
	if not requestFunction then
		return false, "No request function available", { StatusCode = 0, Body = nil }
	end

	local ok, response = pcall(requestFunction, {
		Url = options.url,
		Method = options.method or "GET",
		Headers = options.headers or {},
		Body = options.body,
	})

	if ok and response and tonumber(response.StatusCode) then
		if response.StatusCode >= 200 and response.StatusCode < 300 then
			return true, response.Body, response
		end
		return false, response.Body, response
	end

	return false, response, { StatusCode = 0, Body = response }
end

function Http:Get(url, headers)
	return self:Request({
		url = url,
		method = "GET",
		headers = headers,
	})
end

function Http:GetJson(url, headers)
	local ok, body, response = self:Get(url, headers)
	if not ok then
		return false, body, response
	end

	local success, decoded = pcall(function()
		return HttpService:JSONDecode(body)
	end)

	if not success then
		if self.logger then
			self.logger:Warn("failed to decode http json", url, decoded)
		end
		return false, decoded, response
	end

	return true, decoded, response
end

local Config = {}
Config.__index = Config

function Config.new(fileApi, logger)
	return setmetatable({
		file = fileApi,
		logger = logger,
		stores = {},
		saveTokens = {},
		profileTokens = {},
	}, Config)
end

function Config:Load(name, defaults)
	local loaded = self.file:ReadJson("config/" .. name .. ".json", {})
	local store = merge(defaults or {}, loaded)
	self.stores[name] = store
	return store
end

function Config:Get(name)
	return self.stores[name]
end

function Config:Save(name, data)
	local store = data or self.stores[name] or {}
	local ok, err = self.file:WriteJson("config/" .. name .. ".json", store, { force = true })
	if not ok and self.logger then
		self.logger:Warn("failed to save config", name, err)
	end
	return ok, err
end

function Config:ScheduleSave(name, data, delaySeconds)
	self.saveTokens[name] = (self.saveTokens[name] or 0) + 1
	local token = self.saveTokens[name]

	task.delay(delaySeconds or 0.2, function()
		if self.saveTokens[name] ~= token then
			return
		end
		self:Save(name, data)
	end)
end

function Config:LoadProfile(placeId, slot, defaults)
	local profile = self.file:ReadJson(string.format("configs/%s/%s.json", tostring(placeId), slot or "default"), {})
	return merge(defaults or {}, profile)
end

function Config:SaveProfile(placeId, slot, data)
	local ok, err = self.file:WriteJson(string.format("configs/%s/%s.json", tostring(placeId), slot or "default"), data or {}, { force = true })
	if not ok and self.logger then
		self.logger:Warn("failed to save profile", placeId, slot, err)
	end
	return ok, err
end

function Config:ScheduleProfileSave(placeId, slot, data, delaySeconds)
	local key = tostring(placeId) .. ":" .. tostring(slot or "default")
	self.profileTokens[key] = (self.profileTokens[key] or 0) + 1
	local token = self.profileTokens[key]

	task.delay(delaySeconds or 0.3, function()
		if self.profileTokens[key] ~= token then
			return
		end
		self:SaveProfile(placeId, slot, data)
	end)
end

local Discord = {}
Discord.__index = Discord

local RPC_PORT_START = 6454
local RPC_PORT_END = 6467
local RPC_TIMEOUT = 3

function Discord.new(options)
	options = options or {}
	return setmetatable({
		file = options.file,
		http = options.http,
		logger = options.logger,
		statePath = options.statePath or "configs/discord.json",
		invite = options.invite or "",
	}, Discord)
end

function Discord:_readState()
	if not self.file then
		return {}
	end

	local state = self.file:ReadJson(self.statePath, {})
	if type(state) ~= "table" then
		return {}
	end

	return state
end

function Discord:_writeState(state)
	if not self.file then
		return false, "file api unavailable"
	end

	return self.file:WriteJson(self.statePath, state, { force = true })
end

function Discord:IsInvited(invite)
	local code = extractInviteCode(invite or self.invite)
	if code == "" then
		return false
	end

	local state = self:_readState()
	local invites = type(state.invites) == "table" and state.invites or {}
	return invites[code] == true
end

function Discord:MarkInvited(invite)
	local code = extractInviteCode(invite or self.invite)
	if code == "" then
		return false, "missing invite code"
	end

	local state = self:_readState()
	state.invites = type(state.invites) == "table" and state.invites or {}
	state.invites[code] = true
	state.lastInvite = code
	state.updatedAt = os.time()

	return self:_writeState(state)
end

function Discord:_requestRpc(port, body)
	local url = string.format("http://127.0.0.1:%d/rpc?v=1", port)
	local req = getRequestFunction()

	if req then
		local ok, response = pcall(req, {
			Method = "POST",
			Url = url,
			Headers = {
				["Content-Type"] = "application/json",
				Origin = "https://discord.com",
			},
			Body = body,
		})

		if ok and isSuccessfulResponse(response) then
			return true, response and response.Body, response
		end

		return false, response and response.Body or response, response
	end

	if self.http and type(self.http.Request) == "function" then
		return self.http:Request({
			url = url,
			method = "POST",
			headers = {
				["Content-Type"] = "application/json",
				Origin = "https://discord.com",
			},
			body = body,
		})
	end

	return false, "request function unavailable"
end

function Discord:Invite(invite)
	local code = extractInviteCode(invite or self.invite)
	if code == "" then
		return false, "missing invite code"
	end

	local body = HttpService:JSONEncode({
		nonce = HttpService:GenerateGUID(false),
		args = {
			invite = {
				code = code,
			},
			code = code,
		},
		cmd = "INVITE_BROWSER",
	})
	local totalRequests = (RPC_PORT_END - RPC_PORT_START) + 1
	local completed = 0
	local success = false
	local responseBody
	local responseData
	local lastErr = "discord rpc unavailable"

	for port = RPC_PORT_START, RPC_PORT_END do
		task.spawn(function()
			local ok, currentBody, currentResponse = self:_requestRpc(port, body)
			if ok and not success then
				success = true
				responseBody = currentBody
				responseData = currentResponse
			elseif not ok and currentBody and currentBody ~= "" then
				lastErr = currentBody
			end

			completed = completed + 1
		end)
	end

	local startedAt = os.clock()
	while completed < totalRequests and not success do
		if (os.clock() - startedAt) >= RPC_TIMEOUT then
			break
		end
		task.wait()
	end

	if success then
		local saved, saveErr = self:MarkInvited(code)
		if not saved then
			return false, saveErr
		end
		return true, responseBody, responseData
	end

	if self.logger then
		self.logger:Warn("discord invite failed", code, lastErr)
	end

	return false, lastErr
end

function Discord:EnsureInvite(invite)
	local code = extractInviteCode(invite or self.invite)
	if code == "" then
		return false, "missing invite code", false
	end

	if self:IsInvited(code) then
		return true, "already invited", true
	end

	local ok, result = self:Invite(code)
	return ok, result, false
end

function Platform.new(rootName, logger)
	local file = File.new(rootName, logger)
	local http = Http.new(logger)
	local config = Config.new(file, logger)

	return setmetatable({
		logger = logger,
		file = file,
		http = http,
		config = config,
	}, Platform)
end

function Platform:SetLogger(logger)
	self.logger = logger
	if self.file then
		self.file.logger = logger
	end
	if self.http then
		self.http.logger = logger
	end
	if self.config then
		self.config.logger = logger
	end
	return logger
end

function Platform:CreateDiscord(options)
	options = options or {}
	options.file = options.file or self.file
	options.http = options.http or self.http
	options.logger = options.logger or self.logger
	return Discord.new(options)
end

Platform.File = File
Platform.Http = Http
Platform.Config = Config
Platform.Discord = Discord

return Platform
