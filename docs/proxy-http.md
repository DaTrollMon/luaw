#13. custom HTTP handler for proxying request

So far we have used default HTTP requests handler that ships with Luaw in all our examples. For most purposes it is indeed sufficient, even ideal HTTP handler to use. It handles all low level details of HTTP protocol parsing and routes incoming requests to REST resource by matching URL to user specified matching rules.

However, if you need it, Luaw also allows you to specify your own custom HTTP request handler - which is top level HTTP request router really comparable to Strut's main servlet or Spring MVC servlet counterpart in Java world - which will replace Luaw's default request handler. We will use this Luaw facility to develop a toy HTTP buffering reverse proxy server in this section.

A typical reverse proxy server accepts a HTTP request from a client, inspects its contents and then forwards it to one of many backend HTTP servers it is balancing load for depending upon the results of the request content inspection. On the return path it receives the response generated by the backend server and forwards it to the connected client. Buffering reverse proxy adds, well, buffering to the standard reverse proxy functionality. It buffers incoming HTTP client request till it is complete before it sends it to one of the backend servers. Similarly on the return path it buffers full response generated by the backend server before it starts returning it back to the original client. This buffering is important in order to defend backend servers' limited resoucres against slow client. Without buffering both consumption of input HTTP request and sending of HTTP response will proceed at "line speed" dictated by the slow client which will tie backend server's resources for a long time.

```
+------+ ----HTTP request---> +-------------+ --- Proxy HTTP request ---> +-------+
|Client|                      |Reverse Proxy|                             |Backend|
+------+ <---HTTP response--- +-------------+ <-- Proxy HTTP response --- +-------+
```

Below is the code for a toy buffering reverse proxy with inline comments explaining what's going on. Our toy proxy server uses a protocol where by client sends the backend host and URL it wants to connect through the proxy server in its HTTP request's "proxy-host" and "proxy-url" headers respectively. If any of these headers are missing our proxy server responds with 400 error. It also proxies only HTTP GET requests but its easy to see how it can be modified to proxy other HTTP methods too.

```lua
--[[
    Luaw allows you to replace it's default MVC/REST request handler with your own custom HTTP request handler implementation. To override the default HTTP request handler just set Luaw object's request_handler property to your custom Lua function. This function is passed in a low level connection object for each incoming request instead of the normal request and response objects. The function is called on its own separate Luaw coroutine for each HTTP request so you don't have to worry about multithreaded access to same state inside the function.
    ]]

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
```

The last bit of puzzle remaining is how do we actually load this new, shiny custom HTTP handler of ours into Luaw server? To this we use a simple trick that is quite flexible and powerful in practice. So far we have been starting our Luaw server with following command in luaw_roo_dir:
```
./bin/luaw_server ./conf/server.cfg
```
Where `server.cfg` is a Luaw server configuration file. In reality `luaw_server` binary will read and execute any number of Lua script files specified as series of command line arguments. The very first one is assumed to be server configuration file and is mandatory. Any number - and any kind - of Lua script files can follow the configuration file and are executed by `luaw_server` in the same order as they are specified on the start up commmand line using the same Lua VM and global environment. We can use this handy trick to load any functions we want into Luaw as well as hook up into Luaw's internal machinery using any of the public hook up points that Luaw advertises.

So for our case, just create a file called proxy-handler.lua under `luaw_roo_dir/bin` folder and put the above code in it. Then from your command prompt run Luaw like this:

    ./bin/luaw_server ./conf/server.cfg ./bin/proxy-handler.lua

`luaw_server` will run your proxy-handler.lua after it has initialized itself. The script in proxy-handler.lua then takes care of replacing Luaw's default HTTP request handler with the custom one by assigning the custom handler function to `Luaw.request_handler` property.

Now test your shiny new proxy server by running following tests:

## Test 1 - Missing required headers

    $ curl -v http://127.0.0.1:7001/
    *   Trying 127.0.0.1...
    * Connected to 127.0.0.1 (127.0.0.1) port 7001 (#0)
    > GET / HTTP/1.1
    > User-Agent: curl/7.37.1
    > Host: 127.0.0.1:7001
    > Accept: */*
    >
    < HTTP/1.1 400 Bad Request
    < Content-Length: 50
    <
    Headers proxy-host and proxy-url must be present

## Test 2 - With correct headers
    $ curl -v -H"proxy-host: www.google.com" -H"proxy-url: /" http://127.0.0.1:7001/
    *   Trying 127.0.0.1...
    * Connected to 127.0.0.1 (127.0.0.1) port 7001 (#0)
    > GET / HTTP/1.1
    > User-Agent: curl/7.37.1
    > Host: 127.0.0.1:7001
    > Accept: */*
    > proxy-host: www.google.com
    > proxy-url: /
    >
    < HTTP/1.1 200 OK
    < Content-Type: text/html; charset=ISO-8859-1
    < Transfer-Encoding: chunked
    * Server gws is not blacklisted
    < Server: gws

    (.. followed by the body of the home page at www.google.com)
