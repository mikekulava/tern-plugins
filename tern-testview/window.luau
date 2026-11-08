--!strict
-- The window half: a palette command and key bind that open the Test Explorer for the
-- focused pane's directory, beside it (or focus the explorer already showing tests).

local KIND = "testview.explorer"

local function open_explorer(cx: WindowCx)
	local focused = cx.session:focused()
	local info = if focused then cx.session:pane(focused) else nil
	for _, pane in cx.session:panes() do
		if pane.block == KIND and not pane.parked then
			cx.layout:focus(pane.pane)
			return
		end
	end
	local cwd = if info and info.cwd ~= "" then info.cwd else nil
	local args = if cwd then { cwd :: string } else nil
	if cx:new_block(KIND, args, "beside", { ratio = 0.5 }) == nil then
		cx:toast("error", "Test Explorer is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open test explorer",
	icon = "list-checks",
	run = open_explorer,
})

tern.bind("cmd+shift+u", "plugin.testview.open")
