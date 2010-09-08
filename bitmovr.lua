--
--	bitmovr.lua
--	simple lua webserver which starts to listen on a socket, and
--	forwards all GET calls it receives to a backend server
--	this is extremely lightweight, as it will move the bits from one
--	socket to another, without any disk i/o
--
--	Depends on md5, io, LuaSockets and Memcached.lua
--
--	Application flow:
--	1. File is requested: /m/xyz.jpg
--	2. A check is done if this file is already in the registers somewhere
--	   (eg:404, 5xx, etc.)
--	3. If the file was found in the registers, return the http code from the
--	   registers
--	4. If the file was not found, get the headers remotely, and strip some
--	   of the headers we don't want. We follow any redirects as well
--	5. If the response is non-valid, we set that response in the registers
--	   and return the correct http code (with some of the headers we got).
--	6. If the response is valid, do a proper GET request to the file and
--	   stream the contents directly to the client.
--	7. ---
--	8. Profit.
-- 
--	Created by Sander van de Graaf on 2010-06-28.
--	Copyright Sanoma Digital. All rights reserved.
--
 
-- parse the config file
local settings = {}
for line in io.lines('/etc/bitmovr/bitmovr.conf') do
	for key,value in string.gmatch(line, '([a-zA-Z0-9\_\@\,\:\\\/\.]+) ?= ?\"?([a-zA-Z0-9\_\@\,\:\\\/\.]+)\"?') do
		if value == 'false' then
		 value = false
		end
		if value == 'true' then
		 value = true
		end
		settings[key] = value;
	end
end
 
-- include libraries
local md5 = require("md5")
local io = require("io");
local httpSocket = require("socket.http");
local ltn12 = require("ltn12");
require('Memcached');
 
-- this will hold any non-200 files
errors = {}
spinners = {}
missing = {}
found = {}
 
-- load namespace
local socket = require("socket")
 
-- fetch the hostname and port based on the arg, or let luaSocket decide
assignedHostArg = arg[1] or '0.0.0.0:0'
local assignedHost, assignedPort = string.match(assignedHostArg,'^([0-9\.]+):([0-9]+);?$');
 
-- create a TCP socket and bind it to the local host at the given port
server = assert(socket.bind(assignedHost, assignedPort))
 
-- find out which port the OS chose for us
ip, port = server:getsockname();
hostname = socket.dns.gethostname(ip);
 
-- log function for logging messages to disk or stdout
function logit(msg)
	if settings.log then
		print('[' .. port .. '] ' .. msg);
		logger = io.open(settings.logfile, 'a+');
		logger:write('[' .. port .. '] ' .. msg .. "\n");
		logger:close();
	end
end
 
-- get a memcached connection to multiple servers
function getMemcacheConnection()
	servers = {}
	fields = {}
	settings.memcached_servers:gsub("([^,]*)"..',', function(c) table.insert(fields, c) end)
	for i,descr in ipairs(fields) do
				   local server, port = string.match(descr,'^([0-9\.]+):([0-9]+)$');
				   table.insert(servers,{server,port})
	end
	return Memcached.Connect(servers);
end
 
-- update the stats in memcached, so we can see what's happening
function updateStats(type, what)
	-- type can be of: 200, 201, 400, 404, 504, 'total' and 'sent'
	local key = hostname .. port .. type;
 
	-- connect to local memcached host
	local memcache = getMemcacheConnection();
 
	-- increase or set the amount
	result = memcache:incr(key, what);
	if result == 'NOT_FOUND' then
				   memcache:set(key,what);
				   result = what
	end
	logit('increased ' .. key .. ' with ' .. what .. ': ' .. result);
			   
	memcache:disconnect_all()
end
 
logit("Bitmovr listening");
 
-- loop forever waiting for clients
while 1 do
  -- wait for a connection from any client
  local client = server:accept()
  -- make sure we don't block waiting for this client's line
  client:settimeout(10)
  -- receive the line
  local line, err = client:receive()
  -- if there was no error, send it back to the client
	if not err then
	   logit(line);
	  
	   -- we do need a proper http 1.1 GET request
	   -- we strip out any get args, we ignore those!
	   local requestFilename = string.match(line,'^.+ (/m[\/a-zA-Z0-9_\.\-]+).* HTTP/1..$');
	   local otherRequest = string.match(line,'^.+ \/([status|statistics]).*$');

	   if requestFilename == nil and otherRequest == nil then
		   logit('400, bad file requested! exit;');
		   client:send('HTTP/1.1 400 Dunno what to do. "So long, and thanks for all the fish!"\r\n');
		   client:close()
		   updateStats(400,1);
		  
	   elseif requestFilename ~= nil then
		   logit(requestFilename);

		   local sourceFile = 'http://' .. settings.backend_host .. requestFilename
		   local fileHash = md5.sumhexa(sourceFile)
		   logit(sourceFile);
		   logit(fileHash);
		  
		   -- check if the filename is already in memcached
		   local memcache = getMemcacheConnection()
		   hash = memcache:get('hash_' .. fileHash)
		   responseHeadersCached = memcache:get('headers_' .. fileHash);
		   if hash ~= nil and responseHeadersCached ~= nil then
			   -- we found the file in memcached, fetch the result from castor, and be done with it
			   client:send('HTTP/1.1 200 OK\r\n')

			   -- send the headers, if any
			   responseHeadersCached = memcache:get('headers_' .. fileHash);
			   if responseHeadersCached ~= nil then
				  -- send out all headers
				  client:send(responseHeadersCached);
			   else
				  logit('Found filehash, but couldn\'t find headers, sending anyway');
			   end
			  
			   client:send('\r\n');
			  
			   local outputSink = socket.sink("close-when-done", client)
			   local r, c, h = socket.http.request{
					  sink = outputSink,
					  method = 'GET',
					  url =	 settings.binaryBackend .. hash,
					  redirect = true
			   }
			  
			   -- client:send('\r\n');
			   -- log it
			   updateStats(200,1);
			   logit('found hash in memcached: ' .. c .. ': ' .. hash);
			   statusCode = 200
			   status = 'done'
			   memcache:disconnect_all()
		   else
			   memcache:disconnect_all()
			   -- ok, the file was not in memcached yet, let's find out why, and fetch it once
			   -- then add it to memcached, and serve it from memcached if succesfull
			   local age = 0
			   local status = 'ok';
			   local statusCode = 200;

			   -- check if this is a spinner
			   if spinners[fileHash] ~= nil then
				  age = os.difftime(os.time(), spinners[fileHash]);

				  -- is this already expired?
				  if age > tonumber(settings.TTL_spinner) then
					  spinners[fileHash] = nil
				  else
					  status = 'spinner';
				  end
			   end

			   -- check if this is missing
			   if missing[fileHash] ~= nil then
				  age = os.difftime(os.time(), missing[fileHash])

				  -- is this already expired?
				  if age > tonumber(settings.TTL_missing) then
					  missing[fileHash] = nil;
				  else
					  status = 'missing';
				  end
			   end

			   -- check if we have an error
			   if errors[fileHash] ~= nil then

				  -- this is an error!
				  age = os.difftime(os.time(), errors[fileHash])

				  -- is this already expired?
				  if age == nil or age > tonumber(settings.TTL_errors) then
					  errors[fileHash] = nil;
				  else
					  status = 'error';
				  end
			   end

			   if status == 'ok' then
				  hash = nil

				  -- get the headers for this file remotely
				  local b = {};
				  r, c, h = socket.http.request{
						  method = 'GET',
						  url = sourceFile,
						  redirect = false
				  }

				  if c == 200 then
					  -- set any spinners or errors to nil
					  if errors[fileHash] ~= nil then
						  errors[fileHash] = nil;
					  end
					  if spinners[fileHash] ~= nil then
						  spinners[fileHash] = nil;
					  end
					  if missing[fileHash] ~= nil then
						  missing[fileHash] = nil;
					  end
					  status = 'ok';
				  elseif c == 404 then
					  -- we have a missing file!
					  missing[fileHash] = os.time();
					  status = 'missing';
				  elseif c == 302 then
					  -- woohoo, this file exists, add it to memcached
					  found[fileHash] = os.time();
					  status = 'found';
					  for header, value in pairs(h) do
						  if string.lower(header) == 'location' then
							 logit('found location: ' .. value);
							 hash = string.match(value,'^http://.+/(.+)$');
						  end
					  end
					 
					  logit('found hash in location: ' .. hash);
					  -- if the hash still is nil, then the location header was wrong :(
					  if hash == nil then
						  -- we have an error
						  errors[fileHash] = os.time();
						  status = 'error';
					  else
						  local memcache = getMemcacheConnection()
						  memcache:set('hash_' .. fileHash, hash);
						  memcache:disconnect_all()
						 
						  -- get the headers from the final file
						 rCastor, cCastor, h = socket.http.request{
								 method = 'HEAD',
								 url =	settings.binaryBackend .. hash,
								 redirect = true
						  }
					  end
					 
				  else
					  -- we have an error
					  errors[fileHash] = os.time();
					  status = 'error';
				  end

				  -- concat all allowed headers, we hate etags and stuff
				  iscastor = false;
				  responseHeaders = ''
				  if h ~= nil then
					  for header, value in pairs(h) do
						  if string.lower(header) == 'content-type' or
							 string.lower(header) == 'content-length' or
							 string.lower(header) == 'last-modified' then
								 responseHeaders = responseHeaders .. header .. ': ' .. value .. '\r\n';
						  end
						  -- if the server is not castor, this is a spinner
						  if string.lower(header) == 'server' then
							 local serverHeader = string.match(string.lower(value),'.*(castor).*');
							 if serverHeader ~= nil then
								 iscastor = true
							 end
						  end
						  if string.lower(header) == 'content-length' then
							 updateStats('sent',value);
						  end
					  end
				  end
				 
				  -- we store the headers only if we found a valid hash
				  if hash ~= nil then
					  local memcache = getMemcacheConnection()
					  logit('storing headers: ' .. responseHeaders);
					  memcache:set('headers_' .. fileHash, responseHeaders);
					  memcache:disconnect_all()
				  end
			   end
		  
			   -- check if the hash is in memcached
			   local memcache = getMemcacheConnection()
			   hash = memcache:get('hash_' .. fileHash)
			   responseHeadersCached = memcache:get('headers_' .. fileHash);
			  
			   if hash ~= nil and responseHeadersCached ~= nil then
				  client:send('HTTP/1.1 200 OK\r\n')
				 
				  -- send the headers, if any
				  responseHeadersCached = memcache:get('headers_' .. fileHash);
				  if responseHeadersCached ~= nil then
					  -- send out all headers
					  client:send(responseHeadersCached);
				  else
					  logit('Found filehash, but couldn\'t find headers, sending anyway');
				  end
				 
				  client:send('\r\n');

				  -- we found the file in memcached, fetch the result from castor, and be done with it
				  local outputSink = socket.sink("close-when-done", client)
				  local r, c, h = socket.http.request{
						  sink = outputSink,
						  method = 'GET',
						  url =	 settings.binaryBackend .. hash,
						  redirect = true
				  }

				  -- log it
				  updateStats(200,1);
				  logit('found hash in memcached: ' .. statusCode .. ': ' .. line);
				  statusCode = 200;
				  status = 'done'
			   end
			   memcache:disconnect_all()

			   if status == 'ok' then
				  statusCode = 200;
   
				  -- we only support 200, for now
				  client:send('HTTP/1.1 200 OK\r\n')

				  -- send out all headers
				  client:send(responseHeaders);

				  if iscastor == false then
					  -- ok, this is a spinner, check if we have this on disk
					  -- if so, serve that file
					  spinnerFile = settings.spinner_dir .. md5.sumhexa(requestFilename) .. '_spinner.gif';
					  logit(spinnerFile);
					  local f = io.open(spinnerFile, "r")
					  if (f and f:read()) then
						  -- file exists
					  else
						  fileOut = io.open(spinnerFile, 'wb')

						  local r, c, h = socket.http.request{
								 sink = ltn12.sink.file(fileOut),
								 method = 'GET',
								 url = sourceFile,
								 redirect = true
						  }
					  end

					  client:send('Cache-Control: max-age=10\r\n');
					  client:send('\r\n');
					  f = io.open(spinnerFile, "r");
					  t = f:read("*all");
					  client:send(t);

					  -- log it
					  updateStats(201,1);
				  else
					  client:send('\r\n');

					  -- this is where the magic happens, we send out the data immediatly
					  -- and don't save anything in memory or on disk. Sinks rock!
					  local outputSink = socket.sink("close-when-done", client)
					  local r, c, h = socket.http.request{
							 sink = outputSink,
							 method = 'GET',
							 url = sourceFile,
							 redirect = true
					  }
					  outputSink = nil;
			  
					  -- log it
					  updateStats(200,1);
				  end
			   elseif status == 'missing' then
					statusCode = 404;

					client:send('HTTP/1.1 404 Not Found\r\n');
					client:send('Connection: Close\r\n');
					client:send('\r\n');
					
					client:send('uhoh, 404 not found, woops!');

					-- log it
					updateStats(404,1);
			   elseif status == 'done' then
				  -- do nothing
			   else
				  statusCode = 504;
   
				  -- in all other case, send out a 504
				  client:send('HTTP/1.1 504 Something is wrong on the upstream server...\r\n');
		  
				  -- log it
				  updateStats(504,1);
			   end
			   logit(statusCode .. ': ' .. line);
			   updateStats('total',1);
		   end
	   end

	  
	   -- The following block is for checking a /status request
	   -- This request will check all local running bitmovr instances
	   -- for their status via /status?check=true and sum up the totals
	   -- for running and died instances
	   local statusRequest = string.match(line,'^.*(\/status).*$');
	   if statusRequest ~= nil then
		   logit('status!')
		   local check = string.match(line,'^.*status.+(check).*$');
		   if check ~= nil then
			   logit('alive!');
			   -- we're alive!
			   client:send('HTTP/1.1 200 OK\r\n');
			   client:send('\r\n');
			   client:send('OK');
		   else
			   -- count the total instances, we start with 1
			   -- as the current process is always running :)
			   local total = 1
			   local good = 1

			   -- loop through the config
			   for line in io.lines(settings.backendfile) do
				  local checkHostname, checkPort = string.match(line,'^.+server ([0-9\.]+):([0-9]+);?$');
				  if (checkHostname ~= nil and checkPort ~= nil) and tonumber(checkPort) ~= tonumber(port) then
					  total = total + 1;
					 
					  local checkUrl = 'http://' .. checkHostname .. ':' .. checkPort .. '/status?check=true';

					  -- timeout after 1 second
					  local TIMEOUT = 1

					  -- request the check url, and count how many are OK
					  local r, c, h = socket.http.request{
						  url = checkUrl,
					  }
					  if c == 200 then
						  good = good + 1
					  end
				  end
			   end
			   -- send the totals
			   client:send('HTTP/1.1 200 OK\r\n');
			   client:send('\r\n');
			   client:send(total .. ' ' .. good);
			   client:send('\r\n');
		   end
		   client:close()
	   end

	   -- this block is for a statistics request, it will gather all stats from
	   -- memcached and presents them in a nice little table
	   local statisticsRequest = string.match(line,'^.*(\/statistics).*$');
	   if statisticsRequest ~= nil then
		   client:send('HTTP/1.1 200 OK\r\n');
		   client:send('Content-Type: text/plain\r\n');
		   client:send('Cache-Control: max-age=0\r\n');
		   client:send('\r\n');
		  
		   -- type can be of: 200, 201, 400, 404, 504, 'sent'
		   -- we need to search all of them for all ports on this local machine
		   local ports = {}
		   -- read the lines of the config
		   for port in io.lines(settings.backendfile) do
			   table.insert(ports, port);
		   end

		   -- connect to local memcached host
		   local memcache = getMemcacheConnection();
		  
		   types = {200,201,400,404,504,'total','sent'}
		   totals = {}

		   client:send('\t\t');
		   for key,code in pairs(types) do
			   client:send(code .. '\t\t');
		   end
		   client:send('\r\n---\r\n');

		   -- loop through all ports, and collect all the data from the memcache instance
		   for key,location in pairs(ports) do
			   local localHost, localPort = string.match(location,'^.+server ([0-9\.]+):([0-9]+);?$');
			   localHost = socket.dns.gethostname(localHost);
			   if localHost ~= nil and localPort ~= nil then
				  client:send(localHost .. ':' .. localPort .. '\t');

				  for key,code in pairs(types) do
					  local key = localHost .. localPort .. code;
					  value = memcache:get(key);
					  if(value == nil) then
						  client:send('0');
					  else
						  -- count up the totals so we can echo these if requested
						  if totals[code] ~= nil then
							 totals[code] = totals[code] + value;
						  else
							 totals[code] = value;
						  end
						  if(code ~= 'sent') then
							 client:send(value);
						  else
							 -- Print in kiB,MiB,GiB,TiB
							 if(value > 2^40) then
								 client:send(string.format("%.2f TiB",value/(2^40)));
							 elseif(value > 2^30) then
								 client:send(string.format("%.2f GiB",value/(2^30)));
							 elseif(value > 2^20) then
								 client:send(string.format("%.2f MiB",value/(2^20)));
							 else
								 client:send(string.format("%.2f kiB",value/(2^10)));
							 end
						  end
					  end
					  client:send('\t\t');
				  end
				  client:send('\r\n');
			   end
		   end
		  
		   -- send out the totals for this listing
		   client:send('---\r\nTotals:\t\t');
		   for key,code in pairs(types) do
			   if totals[code] ~= nil then
				  if(code ~= 'sent') then
					  client:send(totals[code]);
				  else
					  -- Print in kiB,MiB,GiB,TiB
					  if(totals[code] > 2^40) then
						  client:send(string.format("%.2f TiB",totals[code]/(2^40)));
					  elseif(totals[code] > 2^30) then
						  client:send(string.format("%.2f GiB",totals[code]/(2^30)));
					  elseif(totals[code] > 2^20) then
						  client:send(string.format("%.2f MiB",totals[code]/(2^20)));
					  else
						  client:send(string.format("%.2f kiB",totals[code]/(2^10)));
					  end
				  end
			   else
				  client:send('0');
			   end
			   client:send('\t\t')
		   end
		   client:send('\r\n');

		  
		   -- if there was a flush, flush all local stats
		   local flush = string.match(line,'^.*statistics.+(flush).*$');
		   if flush ~= nil then
			   localHost = socket.dns.gethostname(ip);
			   for keu, code in pairs(types) do
				  local key = localHost .. port .. code;
				  memcache:delete(key);
			   end
			   logit('flushed stats for: ' .. localHost .. ':' .. port);
			   client:send(localHost .. ':' .. port .. ': flushed');
		   end
		  
		   -- disconnect from memcache, so we don't have any open connections
		   memcache:disconnect_all()

		   client:close()
	   end
	  
	   -- close the connection
	   client:close()
	end
end