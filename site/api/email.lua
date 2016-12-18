--[[
 Licensed to the Apache Software Foundation (ASF) under one or more
 contributor license agreements.  See the NOTICE file distributed with
 this work for additional information regarding copyright ownership.
 The ASF licenses this file to You under the Apache License, Version 2.0
 (the "License"); you may not use this file except in compliance with
 the License.  You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
]]--

-- This is email.lua - a script for fetching a document (email)

local JSON = require 'cjson'
local elastic = require 'lib/elastic'
local aaa = require 'lib/aaa'
local user = require 'lib/user'
local cross = require 'lib/cross'
local config = require 'lib/config'
local utils = require 'lib/utils'

function handle(r)
    cross.contentType(r, "application/json")
    local get = r:parseargs()
    local eid = (get.id or ""):gsub("\"", "")
    local _, doc = pcall(function() return elastic.get("mbox", eid or "hmm") end)
    
    -- Try searching by original source mid if not found, for backward compat
    if not doc or not doc.mid then
        doc = nil -- ensure subsequent check works if we don't find the email here either
        local docs = elastic.find("message-id:\"" .. r:escape(eid) .. "\"", 1, "mbox")
        if #docs == 1 then
            doc = docs[1]
        end
        
        -- shortened link maybe?
        if #docs == 0 and #eid == 18 then
            docs = elastic.find("mid:" .. r:escape(eid) .. "*", 1, "mbox")
        end
        if #docs == 1 then
            doc = docs[1]
        end
    end
    
    -- Did we find an email?
    if doc then
        local account = user.get(r)
        
        -- If we can access this email, ...
        if aaa.canAccessDoc(r, doc, account) then
            doc.tid = doc.request_id
            
            -- Are we in fact looking for an attachment inside this email?
            if get.attachment then
                local hash = r:escape(get.file)
                local fdoc = elastic.get("attachment", hash)
                if fdoc and fdoc.source then
                    local out = r:base64_decode(fdoc.source:gsub("\n", "")) -- bug in mod_lua?
                    local ct = "application/binary"
                    local fn = "unknown"
                    local fs = 0
                    for k, v in pairs(doc.attachments or {}) do
                        if v.hash == hash then
                            ct = v.content_type or "application/binary"
                            fn = v.filename
                            fs = v.size
                            break
                        end
                    end
                    cross.contentType(r, ct)
                    r.headers_out['Content-Length'] = fs
                    if not (ct:match("image") or ct:match("text")) then
                        r.headers_out['Content-Disposition'] = ("attachment; filename=\"%s\";"):format(fn)
                    end
                    r:write(out)
                    return cross.OK
                end
            -- Or do we just want the email itself?
            else
                local eml = utils.extractCanonEmail(doc.from or "unknown")
                if not account then -- anonymize email address if not logged in
                    doc = utils.anonymizeHdrs(doc, true)
                end
                
                -- Anonymize any email address mentioned in the email if not logged in
                if not account and config.antispam then
                    doc.body = utils.anonymizeBody(doc.body)
                end
                
                
                -- Anonymize to/cc if full_headers is false
                if not config.full_headers or not account then
                    doc.to = nil
                    doc.cc = nil
                end      
                doc.gravatar = r:md5(eml:lower())
                r:puts(JSON.encode(doc))
                return cross.OK
            end
        end
    end
    r:puts[[{"No such e-mail or you do not have access to it."}]]
    return cross.OK
end

cross.start(handle)