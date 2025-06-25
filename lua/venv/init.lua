local M = {}

-- Get LSP root directory or fallback to CWD
local function find_project_root()
	local clients = vim.lsp.get_clients({ bufnr = 0 })
	for _, client in ipairs(clients) do
		if client.config.root_dir then
			return client.config.root_dir
		end
	end
	return vim.fn.getcwd()
end

-- Recursively scan for a folder with python binary from the root
local function find_python_interpreter_venv(root)
	local function is_python(path)
		return vim.fn.executable(path .. "/bin/python") == 1 or vim.fn.executable(path .. "/Scripts/python.exe") == 1
	end

	local function scan_dir(dir)
		local handle = vim.uv.fs_scandir(dir)
		if not handle then
			return nil
		end
		while true do
			local name, t = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			if t == "directory" then
				if is_python(full) then
					return vim.fn.executable(full .. "/bin/python") == 1 and full .. "/bin/python"
						or full .. "/Scripts/python.exe"
				else
					local res = scan_dir(full)
					if res then
						return res
					end
				end
			end
		end
		return nil
	end

	return scan_dir(root)
end

-- Update pyright to the new path and make it reload the configuration
local function update_pyright_python_path(python_path)
	for _, client in pairs(vim.lsp.get_clients()) do
		if client.name == "pyright" then
			client.config.settings = client.config.settings or {}
			client.config.settings.python = client.config.settings.python or {}
			client.config.settings.python.pythonPath = python_path
			client.notify("workspace/didChangeConfiguration", {
				settings = client.config.settings,
			})
			break
		end
	end
end

local function find_system_pythons()
	local paths = vim.split(os.getenv("PATH") or "", (vim.uv.os_uname().version:match("Windows")) and ";" or ":")
	local found = {}
	local seen = {}

	for _, dir in ipairs(paths) do
		local handle = vim.uv.fs_scandir(dir)
		if handle then
			while true do
				local name, _ = vim.uv.fs_scandir_next(handle)
				if not name then
					break
				end
				if name:match("^python[0-9.]*$") then
					local sep = (vim.uv.os_uname().version:match("Windows")) and "\\" or "/"
					local full_path = dir .. sep .. name
					if vim.uv.fs_access(full_path, "X") and not seen[full_path] then
						table.insert(found, full_path)
						seen[full_path] = true
					end
				end
			end
		end
	end

	return found
end

---@class PythonInterpreter
---@field path string  # Full path to the interpreter
---@field type string  # Type of the interpreter (e.g., "venv" or "system")

-- Prompt the user to select a Python interpreter
---@param pythons PythonInterpreter[]
---@param callback fun(python: PythonInterpreter)
local function select_python_interpreter(pythons, callback)
	if vim.ui and vim.ui.select then
		vim.ui.select(pythons, {
			prompt = "Select Python interpreter:",
			format_item = function(item)
				local name = vim.fn.fnamemodify(item.path, ":t")
				if item.type == "venv" then
					name = name .. " (venv)"
				end
				return name .. " — " .. item.path
			end,
		}, callback)
	else
		callback(pythons[1])
	end
end

-- Setup function to create the Venv command
function M.setup(opts)
	vim.api.nvim_create_user_command("Venv", function()
		local root = find_project_root() or vim.fn.getcwd()

		-- Find all python interpreters from venvs and system
		local venv_python = find_python_interpreter_venv(root)
		local system_pythons = find_system_pythons()

		-- Combine lists, avoiding duplicates
		---@type PythonInterpreter[]
		local combined = {}
		local seen = {}
		if venv_python then
			table.insert(combined, { type = "venv", path = venv_python })
			seen[venv_python] = true
		end
		for _, p in ipairs(system_pythons) do
			if not seen[p] then
				table.insert(combined, { type = "system", path = p })
				seen[p] = true
			end
		end

		if #combined == 0 then
			vim.notify(
				"No Python interpreters found in project venvs or system PATH",
				vim.log.levels.ERROR,
				{ title = "Venv" }
			)
			return
		end

		select_python_interpreter(combined, function(selected)
			if not selected then
				vim.notify("No Python interpreter selected", vim.log.levels.WARN)
				return
			end

			-- If selected interpreter is inside a venv folder, set VIRTUAL_ENV accordingly
			local ve = nil
			if selected.type == "venv" then
				ve = vim.fn.fnamemodify(selected.path, ":h:h") -- go up two dirs to venv root
			end

			vim.env.VIRTUAL_ENV = ve

			-- Update PATH with venv bin if applicable
			local sep = (vim.loop.os_uname().sysname == "Windows") and "\\" or "/"
			if ve then
				local venv_bin = ve .. sep .. ((vim.loop.os_uname().sysname == "Windows") and "Scripts" or "bin")
				vim.env.PATH = venv_bin .. (vim.loop.os_uname().sysname == "Windows" and ";" or ":") .. vim.env.PATH
			end

			vim.g.python3_host_prog = selected.path
			update_pyright_python_path(selected.path)

			local msg = ve and ("Venv python selected: " .. ve) or ("System Python selected: " .. selected.path)
			vim.notify(msg, vim.log.levels.INFO, { title = "Venv" })
		end)
	end, { desc = "Select and activate Python interpreter from venv or system" })
end

return M
