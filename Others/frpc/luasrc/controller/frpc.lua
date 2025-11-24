-- SPDX-License-Identifier: Apache-2.0
module("luci.controller.frpc", package.seeall)

local http        = require "luci.http"
local dispatcher  = require "luci.dispatcher"
local sys         = require "luci.sys"
local fs          = require "nixio.fs"
local uci         = require "luci.model.uci"

local appname = "frpc"

local function get_cursor()
	return uci.cursor()
end

local function ensure_global_section(cur)
	local sid = cur:get_first(appname, "global")
	if not sid then
		sid = cur:add(appname, "global")
	end
	return sid
end

local function is_hidden()
	local cur = get_cursor()
	local sid = cur:get_first(appname, "global")
	if not sid then
		return true
	end

	local val = cur:get(appname, sid, "hide_from_luci")
	return val ~= "0"
end

local function refresh_menu()
	sys.call("rm -rf /tmp/luci-* >/dev/null 2>&1")
	sys.call("/etc/init.d/rpcd restart >/dev/null 2>&1")
end

function index()
	if not fs.access("/etc/config/" .. appname) then
		return
	end

	entry({"admin", "services", appname, "show"}, call("show_menu")).leaf = true
	entry({"admin", "services", appname, "hide"}, call("hide_menu")).leaf = true

	local title
	if not is_hidden() then
		title = _("frp Client")
	end

	entry({"admin", "services", appname}, alias("admin", "services", appname, "settings"), title, 20)
	entry({"admin", "services", appname, "settings"}, view("frpc"), _("Settings"), 10).leaf = true
end

function show_menu()
	local cur = get_cursor()
	local sid = ensure_global_section(cur)
	cur:set(appname, sid, "hide_from_luci", "0")
	cur:save(appname)
	cur:commit(appname)

	refresh_menu()
	http.redirect(dispatcher.build_url("admin", "services", appname, "settings"))
end

function hide_menu()
	local cur = get_cursor()
	local sid = ensure_global_section(cur)
	cur:set(appname, sid, "hide_from_luci", "1")
	cur:save(appname)
	cur:commit(appname)

	refresh_menu()
	http.redirect(dispatcher.build_url("admin", "status", "overview"))
end

