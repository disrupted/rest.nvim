local vim = vim
local api, fn = vim.api, vim.fn

local curl = require('plenary.curl')
local utils = require('rest-nvim.utils')

-- get_or_create_buf checks if there is already a buffer with the rest run results
-- and if the buffer does not exists, then create a new one
local function get_or_create_buf()
	local tmp_name = 'rest_nvim_results'

	-- Check if the file is already loaded in the buffer
	local existing_bufnr = fn.bufnr(tmp_name)
	if existing_bufnr ~= -1 then
		-- Set modifiable
		api.nvim_buf_set_option(existing_bufnr, 'modifiable', true)
		-- Delete buffer content
		api.nvim_buf_set_lines(
			existing_bufnr,
			0,
			api.nvim_buf_line_count(existing_bufnr) - 1,
			false,
			{}
		)

		-- Make sure the filetype of the buffer is httpResult so it will be highlighted
		api.nvim_buf_set_option(existing_bufnr, 'ft', 'httpResult')

		return existing_bufnr
	end

	-- Create new buffer
	local new_bufnr = api.nvim_create_buf(false, 'nomodeline')
	api.nvim_buf_set_name(new_bufnr, tmp_name)
	api.nvim_buf_set_option(new_bufnr, 'ft', 'httpResult')

	return new_bufnr
end

-- parse_url returns a table with the method of the request and the URL
-- @param stmt the request statement, e.g., POST http://localhost:3000/foo
local function parse_url(stmt)
	local parsed = utils.split(stmt, ' ')
	return {
		method = parsed[1],
		-- Encode URL
		url = utils.encode_url(utils.replace_env_vars(parsed[2])),
	}
end

-- go_to_line moves the cursor to the desired line in the provided buffer
-- @param bufnr Buffer number, a.k.a id
-- @param line the desired cursor position
local function go_to_line(bufnr, line)
	api.nvim_buf_call(bufnr, function()
		fn.cursor(line, 1)
	end)
end

-- get_body retrieves the body lines in the buffer and then returns a raw table
-- if the body is not a JSON, otherwise, get_body will return a table
-- @param bufnr Buffer number, a.k.a id
-- @param stop_line Line to stop searching
-- @param query_line Line to set cursor position
-- @param json_body If the body is a JSON formatted POST request, false by default
local function get_body(bufnr, stop_line, query_line, json_body)
	if not json_body then
		json_body = false
	end
	local json = nil
	local start_line = 0
	local end_line = 0

	start_line = fn.search('{', '', stop_line)
	end_line = fn.search('}', 'n', stop_line)

	if start_line > 0 then
		local json_string = ''
		local json_lines = {}
		json_lines =
			api.nvim_buf_get_lines(bufnr, start_line, end_line - 1, false)

		for _, v in ipairs(json_lines) do
			json_string = json_string .. utils.replace_env_vars(v)
		end

		json_string = '{' .. json_string .. '}'
		json = fn.json_decode(json_string)
	end

	go_to_line(bufnr, query_line)

	if json_body and json ~= nil then
		-- If the body is a JSON request then return it as raw string
		-- e.g. `-d "{\"foo\":\"bar\"}"`
		json = utils.tbl_to_str(json)
	end

	return json
end

-- get_headers retrieves all the found headers and returns a lua table with them
-- @param bufnr Buffer number, a.k.a id
-- @param query_line Line to set cursor position
local function get_headers(bufnr, query_line)
	local headers = {}
	-- Set stop at end of buffer
	local stop_line = fn.line('$')
	-- If we should stop iterating over the buffer lines
	local break_loops = false
	-- HTTP methods
	local http_methods = { 'GET', 'POST', 'PUT', 'PATCH', 'DELETE' }

	-- Iterate over all buffer lines
	for line = 1, stop_line do
		local start_line = fn.search(':', '', stop_line)
		local end_line = start_line
		local next_line = fn.getbufline(bufnr, line + 1)
		if break_loops then
			break
		end

		for _, next_line_content in pairs(next_line) do
			if string.find(next_line_content, '{') then
				break_loops = true
				break
			else
				local get_header =
					api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

				for _, header in ipairs(get_header) do
					header = utils.split(header, ':')
					if
						header[1]:lower() ~= 'accept'
						and header[1]:lower() ~= 'authorization'
                        -- If header key doesn't contains double quotes,
                        -- so we don't get body keys
						and header[1]:find('"') == nil
                        -- If header key doesn't contains hashes,
                        -- so we don't get commented headers
                        and header[1]:find('^#') == nil
                        -- If header key doesn't contains HTTP methods,
                        -- so we don't get the http method/url
                        and not utils.has_value(http_methods, header[1])
                    then
						headers[header[1]:lower()] = header[2]
					end
				end
			end
		end
	end

	go_to_line(bufnr, query_line)
	return headers
end

-- get_accept retrieves the Accept field and returns it as string
-- @param bufnr Buffer number, a.k.a id
-- @param query_line Line to set cursor position
local function get_accept(bufnr, query_line)
	local accept = nil
	-- Set stop at end of bufer
	local stop_line = fn.line('$')

	-- Iterate over all buffer lines
	for _ = 1, stop_line do
		-- Case-insensitive search
		local start_line = fn.search('\\cAccept:', '', stop_line)
		local end_line = start_line
		local accept_line =
			api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

		for _, accept_data in pairs(accept_line) do
			accept = utils.split(accept_data, ':')[2]
		end
	end

	go_to_line(bufnr, query_line)

    return accept
end

-- get_auth retrieves the HTTP Authorization and returns a lua table with its values
-- @param bufnr Buffer number, a.k.a id
-- @param query_line Line to set cursor position
local function get_auth(bufnr, query_line)
	local auth = {}
    local auth_not_empty = false
	-- Set stop at end of bufer
	local stop_line = fn.line('$')

	-- Iterate over all buffer lines
	for _ = 1, stop_line do
		-- Case-insensitive search
		local start_line = fn.search('\\cAuthorization:', '', stop_line)
		local end_line = start_line
		local auth_line =
			api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

		for _, auth_data in pairs(auth_line) do
			-- Split by spaces, e.g. {'Authorization:', 'user:pass'}
			auth_data = utils.split(auth_data, '%s+')
			-- {'user', 'pass'}
			auth = utils.split(utils.replace_env_vars(auth_data[2]), ':')
		end
	end

	go_to_line(bufnr, query_line)
    if not auth_not_empty then
        return nil
    end
    return auth
end

-- curl_cmd runs curl with the passed options, gets or creates a new buffer
-- and then the results are printed to the recently obtained/created buffer
-- @param opts curl arguments
local function curl_cmd(opts)
	local res = curl[opts.method](opts)
	local res_bufnr = get_or_create_buf()
	local parsed_url = parse_url(fn.getline('.'))
	local json_body = false

	-- Check if the content-type is "application/json" so we can format the JSON
	-- output later
	for _, header in ipairs(res.headers) do
		if string.find(header, 'application/json') then
			json_body = true
			break
		end
	end

	--- Add metadata into the created buffer (status code, date, etc)
	local line_count = api.nvim_buf_line_count(res_bufnr) - 1
	-- Request statement (METHOD URL)
	api.nvim_buf_set_lines(
		res_bufnr,
		line_count,
		line_count,
		false,
		{ parsed_url.method .. ' ' .. parsed_url.url }
	)
	-- HTTP version, status code and its meaning, e.g. HTTP/1.1 200 OK
	line_count = api.nvim_buf_line_count(res_bufnr)
	api.nvim_buf_set_lines(
		res_bufnr,
		line_count,
		line_count,
		false,
		{ 'HTTP/1.1 ' .. utils.http_status(res.status) }
	)
	-- Headers, e.g. Content-Type: application/json
	for _, header in ipairs(res.headers) do
		line_count = api.nvim_buf_line_count(res_bufnr)
		api.nvim_buf_set_lines(res_bufnr, line_count, line_count, false, { header })
	end

	--- Add the curl command results into the created buffer
	for line in utils.iter_lines(res.body) do
		if json_body then
			-- Format JSON output and then add it into the buffer
			-- line by line because Vim doesn't allow strings with newlines
			local out = fn.system("jq", line)
			for _, _line in ipairs(utils.split(out, '\n')) do
				line_count = api.nvim_buf_line_count(res_bufnr) - 1
				api.nvim_buf_set_lines(
					res_bufnr,
					line_count,
					line_count,
					false,
					{ _line }
				)
			end
		else
			line_count = api.nvim_buf_line_count(res_bufnr) - 1
			api.nvim_buf_set_lines(
				res_bufnr,
				line_count,
				line_count,
				false,
				{ line }
			)
		end
	end

	-- Only open a new split if the buffer is not loaded into the current window
	if fn.bufwinnr(res_bufnr) == -1 then
		vim.cmd([[vert sb]] .. res_bufnr)
		-- Set unmodifiable state
		api.nvim_buf_set_option(res_bufnr, 'modifiable', false)
	end

	api.nvim_buf_call(res_bufnr, function()
		fn.cursor(1, 1) -- Send cursor to buffer start again
	end)
end

-- run will retrieve the required request information from the current buffer
-- and then execute curl
local function run()
	local bufnr = api.nvim_win_get_buf(0)
	local parsed_url = parse_url(fn.getline('.'))
	local last_query_line_number = fn.line('.')

	local next_query =
		fn.search(
			'GET\\|POST\\|PUT\\|PATCH\\|DELETE',
			'n',
			fn.line('$')
		)
	next_query = next_query > 1 and next_query or fn.line('$')

	local headers = get_headers(bufnr, last_query_line_number)

	local body = {}
	-- If the header Content-Type was passed and it's application/json then return
	-- body as `-d '{"foo":"bar"}'`
	if
		headers ~= nil
		and headers['content-type'] ~= nil
		and string.find(headers['content-type'], 'application/json')
	then
		body = get_body(bufnr, next_query, last_query_line_number, true)
	else
		body = get_body(bufnr, next_query, last_query_line_number)
	end

	local auth = get_auth(bufnr, last_query_line_number)
	local accept = get_accept(bufnr, last_query_line_number)

	curl_cmd({
		method = parsed_url.method:lower(),
		url = parsed_url.url,
		headers = headers,
		accept = accept,
		body = body,
		auth = auth,
	})

	go_to_line(bufnr, last_query_line_number)
end

return {
	run = run,
}
