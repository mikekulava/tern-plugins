--!strict
local KIND = "git-identity.identity"

local FIND_REPO = [[
for p in "$@"; do
	[ -d "$p" ] || p=$(dirname "$p")
	top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) && { printf '%s' "$top"; exit 0; }
done
exit 1
]]

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

local function open(cx: WindowCx, repo: string)
	local title = "Git identity · " .. basename(repo)
	for _, p in cx.session:panes() do
		if p.block == KIND and p.title == title then
			if p.parked then
				cx.layout:unpark(p.pane)
			else
				cx.layout:focus(p.pane)
			end
			return
		end
	end
	cx:new_block(KIND, { repo }, "beside")
end

local function open_repo_of(paths: { string }, hint: string)
	if #paths == 0 then
		return
	end
	local argv = { "/bin/sh", "-c", FIND_REPO, "sh" }
	table.move(paths, 1, #paths, #argv + 1, argv)
	tern.process.run(argv, { timeout_ms = 5000 }, function(r: ProcessResult, cx: WindowCx?)
		if cx == nil then
			return
		end
		if r.status == 0 and r.stdout ~= "" then
			open(cx, r.stdout)
		else
			cx:toast("info", "Not inside a git repository", hint)
		end
	end)
end

local function in_repo(dir: string): boolean
	local at = string.gsub(dir, "/+$", "")
	while at ~= "" do
		if tern.fs.exists(at .. "/.git") then
			return true
		end
		at = string.match(at, "^(.*)/[^/]*$") or ""
	end
	return false
end

tern.files.button({
	id = "identity",
	title = "Git identity for the selected repository",
	icon = "user",
	run = function(files: FilesInfo, _cx: WindowCx)
		local paths: { string } = {}
		if files.selection[1] then
			table.insert(paths, files.selection[1])
		end
		if files.root then
			table.insert(paths, files.root)
		end
		open_repo_of(paths, "Select a folder of a repository in the Files pane first")
	end,
})

tern.command({
	id = "identity",
	title = "Git identity for this repository",
	icon = "user",
	keys = { "cmd+shift+y" },
	run = function(cx: WindowCx)
		local id = cx.session:focused()
		local p = if id then cx.session:pane(id) else nil
		if p == nil or p.block == KIND then
			return
		end
		if p.cwd == nil or p.cwd == "" then
			cx:toast("info", "This pane has no folder", "Focus a pane inside a repository first")
			return
		end
		open_repo_of({ p.cwd }, "Focus a pane inside a repository first")
	end,
})

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	if pane.block == KIND or pane.cwd == nil or pane.cwd == "" or not in_repo(pane.cwd) then
		return nil
	end
	return { { text = "git user", icon = "user", command = "plugin.git-identity.identity" } }
end)
