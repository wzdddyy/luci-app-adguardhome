module("luci.controller.AdGuardHome", package.seeall)
local fs = require "nixio.fs"
local http = require "luci.http"
local util = require "luci.util"
local sys = require "luci.sys"
local uci = require"luci.model.uci".cursor()

local function update_running()
	local pid=tonumber((fs.readfile("/var/run/AdGuardHome_update.lock/pid") or ""):match("%d+"))
	if pid and sys.call("kill -0 %d >/dev/null 2>&1" % pid)==0 then
		return true
	end
	return false
end

function index()
local page = entry({"admin", "services", "AdGuardHome"}, cbi("AdGuardHome/base"), _("AdGuard Home"))
page.order = 11
page.dependent = true
page.acl_depends = { "luci-app-adguardhome" }
    entry({"admin", "services", "AdGuardHome", "status"}, call("act_status")).leaf = true
    entry({"admin", "services", "AdGuardHome", "check"}, call("check_update"))
    entry({"admin", "services", "AdGuardHome", "doupdate"}, call("do_update"))
    entry({"admin", "services", "AdGuardHome", "getlog"}, call("get_log"))
    entry({"admin", "services", "AdGuardHome", "dodellog"}, call("do_dellog"))
    entry({"admin", "services", "AdGuardHome", "reloadconfig"}, call("reload_config"))
    entry({"admin", "services", "AdGuardHome", "gettemplateconfig"}, call("get_template_config"))
end
function get_template_config()
	local b
	local d=""
	local file = "/tmp/resolv.conf.d/resolv.conf.auto"
	if not fs.access(file) then
		file = "/tmp/resolv.conf.auto"
	end
	if fs.access(file) then
		for cnt in io.lines(file) do
			b = string.match(cnt, "^[^#]*nameserver%s+([^%s]+)$")
			if (b ~= nil) then d = d .. "  - " .. b .. "\n" end
		end
	end
	local f=io.open("/usr/share/AdGuardHome/AdGuardHome_template.yaml", "r+")
	local tbl = {}
	local a=""
	while (1) do
    	a=f:read("*l")
		if (a=="#bootstrap_dns") then
			a=d
		elseif (a=="#upstream_dns") then
			a=d
		elseif (a==nil) then
			break
		end
		table.insert(tbl, a)
	end
	f:close()
	http.prepare_content("text/plain; charset=utf-8")
	http.write(table.concat(tbl, "\n"))
end
function reload_config()
	fs.remove("/tmp/AdGuardHometmpconfig.yaml")
	http.prepare_content("application/json")
	http.write('')
end
local function logposfile()
	local token=(http.formvalue("token") or ""):gsub("[^%w]","")
	if #token>0 and #token<=32 then
		return "/var/run/lucilogpos_"..token
	end
	return "/var/run/lucilogpos"
end

local function cleanup_logpos()
	local now=os.time()
	local matches=fs.glob("/var/run/lucilogpos_*")
	if matches then
		for f in matches do
			if now-(fs.stat(f,"mtime") or now) > 7200 then
				fs.remove(f)
			end
		end
	end
end

function act_status()
	local e={}
	local binpath=uci:get("AdGuardHome","AdGuardHome","binpath") or "/usr/bin/AdGuardHome"
	local configpath=uci:get("AdGuardHome","AdGuardHome","configpath") or "/etc/AdGuardHome.yaml"
	local dnsport=sys.exec("grep -A 5 '^dns:' %s 2>/dev/null | grep 'port:' | awk '{print $2}'" % util.shellquote(configpath))
	e.running=sys.call("pgrep %s >/dev/null" % util.shellquote(binpath))==0
	e.redirect=(fs.readfile("/var/run/AdGredir")=="1")
	e.redirmode=uci:get("AdGuardHome","AdGuardHome","redirect") or "none"
	local tlsenabled=sys.exec("grep -A 5 '^tls:' %s 2>/dev/null | grep 'enabled:' | awk '{print $2}'" % util.shellquote(configpath))
	e.tls=((tlsenabled or ""):gsub("%s+","")=="true")
	e.port=tonumber(uci:get("AdGuardHome","AdGuardHome","httpport") or "") or 3000
	e.dnsport=tonumber((dnsport or ""):match("%d+")) or 0
	local version=uci:get("AdGuardHome","AdGuardHome","version") or ""
	local binmtime=fs.stat(binpath,"mtime")
	if binmtime and tostring(binmtime)~=(uci:get("AdGuardHome","AdGuardHome","binmtime") or "0") then
		version=sys.exec("echo -n $(%s --version 2>&1 | awk -F 'version ' '{print $2}' | awk -F ',' '{print $1}')" % util.shellquote(binpath))
		if version=="" then version="core error" end
		uci:set("AdGuardHome","AdGuardHome","version",version)
		uci:set("AdGuardHome","AdGuardHome","binmtime",tostring(binmtime))
		uci:commit("AdGuardHome")
	end
	e.version=version
	e.uptime=0
	if e.running then
		local pid=tonumber((sys.exec("pgrep %s 2>/dev/null" % util.shellquote(binpath)) or ""):match("%d+"))
		local up=tonumber((fs.readfile("/proc/uptime") or ""):match("^%d+"))
		local stat=pid and fs.readfile("/proc/%d/stat" % pid)
		local rest=stat and stat:match("%)%s+(.*)$")
		if up and rest then
			local i,starttime=0,nil
			for w in rest:gmatch("%S+") do
				i=i+1
				if i==20 then
					starttime=tonumber(w)
					break
				end
			end
			if starttime then
				e.uptime=math.max(0, up-math.floor(starttime/100))
			end
		end
	end
	http.prepare_content("application/json")
	http.write_json(e)
end
function do_update()
	local arg
	if luci.http.formvalue("force") == "1" then
		arg="force"
	else
		arg=""
	end
	local running=update_running()
	if not running then
		fs.remove("/var/run/update_core")
		fs.remove("/var/run/update_core_start")
	end
	if running and arg ~= "force" then
		fs.writefile("/var/run/lucilogpos_update","0")
		return
	end
	fs.writefile("/var/run/lucilogpos_update","0")
	fs.writefile("/tmp/AdGuardHome_update.log","")
	-- 先落下进行中标记，避免前端首次轮询早于脚本建锁时误判为已完成
	fs.writefile("/var/run/update_core","1")
	fs.writefile("/var/run/update_core_start",tostring(os.time()))
	http.prepare_content("application/json")
	http.write('')
	luci.sys.exec("sh /usr/share/AdGuardHome/update_core.sh "..arg.." >/tmp/AdGuardHome_update.log 2>&1 &")
end
function get_log()
	local logfile=uci:get("AdGuardHome","AdGuardHome","logfile")
	if (logfile==nil) then
		http.write("no log available\n")
		return
	elseif (logfile=="syslog") then
		if not fs.access("/var/run/AdGuardHomesyslog") then
			luci.sys.exec("(/usr/share/AdGuardHome/getsyslog.sh &); sleep 1;")
		end
		logfile="/tmp/AdGuardHometmp.log"
		fs.writefile("/var/run/AdGuardHomesyslog","1")
	elseif not fs.access(logfile) then
		http.write("")
		return
	end
	http.prepare_content("text/plain; charset=utf-8")
	local posfile=logposfile()
	if not fs.access(posfile) then
		cleanup_logpos()
	end
	local fdp = tonumber(fs.readfile(posfile) or "") or 0
	local fsize = fs.stat(logfile, "size") or 0
	if fdp > fsize then
		fdp = 0
	end
	local f=io.open(logfile, "r+")
	f:seek("set",fdp)
	local a=f:read(2048000) or ""
	fdp=f:seek()
	fs.writefile(posfile,tostring(fdp))
	f:close()
	http.write(a)
end
function do_dellog()
	local logfile=uci:get("AdGuardHome","AdGuardHome","logfile")
	local target=(logfile=="syslog") and "/tmp/AdGuardHometmp.log" or logfile
	if target and fs.access(target) then
		fs.writefile(target,"")
	end
	fs.writefile("/var/run/lucilogpos","0")
	http.prepare_content("application/json")
	http.write('')
end
function check_update()
	http.prepare_content("text/plain; charset=utf-8")
	local fdp=tonumber(fs.readfile("/var/run/lucilogpos_update") or "") or 0
	local logpath="/tmp/AdGuardHome_update.log"
	local fsize=fs.stat(logpath,"size") or 0
	if fdp>fsize then
		fdp=0
	end
	local f=io.open(logpath, "r+")
	if not f then
		if fs.access("/var/run/update_core") then
			http.write("")
		else
			http.write("\1")
		end
		return
	end
	f:seek("set",fdp)
	local a=f:read(2048000) or ""
	fdp=f:seek()
	fs.writefile("/var/run/lucilogpos_update",tostring(fdp))
	f:close()
	local running=update_running()
	if not running then
		local started=tonumber(fs.readfile("/var/run/update_core_start") or "") or 0
		if fs.access("/var/run/update_core") and started>0 and (os.time()-started)<30 then
			-- 脚本刚启动、锁目录尚未就绪，继续轮询
			running=true
		else
			fs.remove("/var/run/update_core")
			fs.remove("/var/run/update_core_start")
		end
	end
if running then
	http.write(a)
elseif fs.access("/var/run/update_core_error") then
	http.write(a.."\1")
else
	http.write(a.."\0")
end
end
