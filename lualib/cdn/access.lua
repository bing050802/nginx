local cjson = require "cjson"
local cookie = require "cdn.cookie"

local   tostring, ipairs, pairs, type, tonumber, next, unpack =
        tostring, ipairs, pairs, type, tonumber, next, unpack
        
local ngx_log = ngx.log
local ngx_var = ngx.var
local ngx_ctx = ngx.ctx
local ngx_re_find = ngx.re.find
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local ngx_now = ngx.now
local ngx_exit = ngx.exit
local ngx_md5 = ngx.md5
local ngx_time = ngx.time
local blocked_iplist = ngx.shared.blocked_iplist
local req_iplist = ngx.shared.req_iplist
local req_metrics = ngx.shared.req_metrics

local client_ip = ngx.var.remote_addr
local cookies = cookie.get()
local COOKIE_NAME = "__waf_uid"
local COOKIE_KEY = "xg0j21"

if blocked_iplist:get(client_ip) ~= nil then
	if blocked_iplist:get(client_ip) >= ngx_now() then
		ngx_exit(444)
	end
end

local http_ua = ngx_var.http_user_agent
if not http_ua then
	ngx_exit(400)
end

local zone_interval = 3
local zone_key = client_ip .. ":" .. ngx_var.uri .. ":" .. math.ceil (ngx_time() / zone_interval)
local zone_count, err = req_metrics:incr(zone_key, 1)
if not zone_count then
	req_metrics:add(zone_key, 1, zone_interval)
end

local req_interval = 5
local req_key = "total_req"
local req_count, err = req_metrics:incr(req_key, 1)
if not req_count then
	req_metrics:add(req_key, 1, req_interval)
end

local ip_interval = 5
local ip_key = "total_ip"
local ok, err = req_iplist:incr(ip_key, 0)
if not ok then
	req_iplist:flush_all()
    req_iplist:add(ip_key, 0, ip_interval)
end
local ok, err = req_iplist:safe_add(client_ip, 1)
if ok then
	req_iplist:incr(ip_key, 1)
end

ngx_log(ngx_INFO, "ip total: ", req_iplist:get(ip_key), "(", ip_interval, "s)", 
"req total: ", req_metrics:get(req_key), "(", req_interval, "s)"
)
-- identify if request is page or resource
if ngx_re_find(ngx.var.uri, "\\.(bmp|css|gif|ico|jpe?g|js|png|swf)$", "ioj") then
    ngx_ctx.cdn_rtype = "resource"
else
    ngx_ctx.cdn_rtype = "page"
end

-- if QPS is exceed 5, start cookie challenge
if req_count and req_count > 2 then
	local user_id = ngx_md5(zone_key)
    if cookies[COOKIE_NAME] ~= user_id then
        cookie.challenge(COOKIE_NAME, user_id)
        return
    end
end
