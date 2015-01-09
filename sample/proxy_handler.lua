Luaw.request_handler =  function(conn)
    conn:startReading()

    -- loop to support HTTP 1.1 persistent (keep-alive) connections
    while true do
        local req = Luaw.newServerHttpRequest(conn)
        local resp = Luaw.newServerHttpResponse(conn)

        -- read and parse full request
        local eof = req:readFull()
        if (eof) then
            conn:close()
            return "connection reset by peer"
        end

        local reqHeaders = req.headers
        local beHost =  reqHeaders['backend-host']
        local beURL = reqHeaders['backend-url']

        if (beHost and beURL) then
            local backendReq = Luaw.newClientHttpRequest()
            backendReq.hostName = beHost
            backendReq.url = beURL
            backendReq.method = 'GET'
            backendReq.headers = { Host = beHost }

            local status, backendResp = pcall(backendReq.execute, backendReq)
            if (status) then
                resp:setStatus(backendResp:getStatus())
                resp:appendBody(backendResp:getBody())
                local beHeaders = backendResp.headers
                for k,v in pairs(beHeaders) do
                    if ((k ~= 'Transfer-Encoding')and(k ~= 'Content-Length')) then
                        resp:addHeader(k,v)
                    end
                end
                backendResp:close()
            else
                resp:setStatus(500)
                resp:appendBody("connection to backend server failed")
            end
        else
            resp:setStatus(400)
            resp:appendBody("Request must contain headers backend-host and backend-url")
        end

        local status, mesg = pcall(resp.flush, resp)
        if (not status) then
            conn:close()
            return error(mesg)
        end

        if (req:shouldCloseConnection() or resp:shouldCloseConnection()) then
            conn:close()
            return "connection reset by peer"
        end
    end
end