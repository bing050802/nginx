local h_util = require "ledge.header_util"
local http_headers = require "resty.http_headers"

local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local rawset = rawset
local rawget = rawget
local tonumber = tonumber
local tbl_concat = table.concat
local str_lower = string.lower
local str_gsub = string.gsub
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_match = ngx.re.match
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_req_get_headers = ngx.req.get_headers

local ngx_log = ngx.log
local ngx_var = ngx.var
local ngx_DEBUG = ngx.DEBUG
local json_safe = require "cjson"

local _M = {
    _VERSION = '0.3',
    CACHE_MODE_NOMATCH = 0,
    CACHE_MODE_DISABLED = 1,
    CACHE_MODE_BASIC = 2,
    CACHE_MODE_ADVANCED = 4,      
}

local mt = {
    __index = _M,
}

local NOCACHE_HEADERS = {
    ["Pragma"] = { "no-cache" },
    ["Cache-Control"] = {
        "no-cache",
        "no-store",
        "private",
    }
}


function _M.new()
    local body = ""
    local header = http_headers.new()
    local status = nil

    return setmetatable({   status = nil,
                            body = body,
                            header = header,
                            remaining_ttl = 0,
                            
    }, mt)
end


function _M.is_cacheable(self)
    -- Never cache partial content
    if self.status == 206 then
        return false
    end
   ngx_log(ngx.DEBUG, self.status, "ttl=", self:ttl(), tonumber(ngx_var.cache_status), ngx_var.cache_disabled)

    if (tonumber(ngx_var.cache_status) == _M.CACHE_MODE_ADVANCED and tonumber(ngx_var.cache_disabled) == 0) then
        return true
    end    
    ngx_log(ngx_DEBUG, "2")
    for k,v in pairs(NOCACHE_HEADERS) do
        for i,h in ipairs(v) do
            if self.header[k] and self.header[k] == h then
                return false
            end
        end
    end
    ngx_log(ngx_DEBUG, "3")
    if self:ttl() > 0 then
        return true
    else
        return false
    end
end


function _M.ttl(self)
    -- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM,
    -- and finally Expires: HTTP_TIMESTRING.
    local cc = self.header["Cache-Control"]
    if cc then
        if type(cc) == "table" then
            cc = tbl_concat(cc, ", ")
        end
        local max_ages = {}
        for max_age in ngx_re_gmatch(cc, 
            "(s\\-maxage|max\\-age)=(\\d+)", 
            "io") do
            max_ages[max_age[1]] = max_age[2]
        end

        if max_ages["s-maxage"] then
            return tonumber(max_ages["s-maxage"])
        elseif max_ages["max-age"] then
            return tonumber(max_ages["max-age"])
        end
    end
ngx_log(ngx_DEBUG, json_safe.encode(self.header))
    -- Fall back to Expires.
    local expires = self.header["Expires"]
    if expires then 
        local time = ngx_parse_http_time(expires)
        if time then return time - ngx_time() end
    end

    return 0
end


function _M.has_expired(self)
    if self.remaining_ttl <= 0 then
        return true
    end

    local cc = ngx_req_get_headers()["Cache-Control"]
    if self.remaining_ttl - (h_util.get_numeric_header_token(cc, "min-fresh") or 0) <= 0 then
        return true
    end
end


-- The amount of additional stale time allowed for this response considering
-- the current requests 'min-fresh'.
function _M.stale_ttl(self)
    -- Check response for headers that prevent serving stale
    local cc = self.header["Cache-Control"]
    if h_util.header_has_directive(cc, "revalidate") or
        h_util.header_has_directive(cc, "s-maxage") then
        return 0
    end

    local min_fresh = h_util.get_numeric_header_token(
        ngx_req_get_headers()["Cache-Control"], "min-fresh"
    ) or 0

    return self.remaining_ttl - min_fresh
end


-- Reduce the cache lifetime and Last-Modified of this response to match
-- the newest / shortest in a given table of responses. Useful for esi:include.
function _M.minimise_lifetime(self, responses)
    for _,res in ipairs(responses) do
        local ttl = res:ttl()
        if ttl < self:ttl() then
            self.header["Cache-Control"] = "max-age="..ttl
            if self.header["Expires"] then
                self.header["Expires"] = ngx_http_time(ngx_time() + ttl)
            end
        end

        if res.header["Age"] and self.header["Age"] and
            (tonumber(res.header["Age"]) < tonumber(self.header["Age"])) then
            self.header["Age"] = res.header["Age"]
        end

        if res.header["Last-Modified"] and self.header["Last-Modified"] then
            local res_lm = ngx_parse_http_time(res.header["Last-Modified"])
            if res_lm > ngx_parse_http_time(self.header["Last-Modified"]) then
                self.header["Last-Modified"] = res.header["Last-Modified"]
            end
        end
    end
end

return _M

