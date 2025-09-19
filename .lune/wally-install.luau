--[[
	https://github.com/Corecii/GreenTea/blob/main/lune/wally-install.luau
	
	Copyright 2024 Shae A.

	Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

local process = require("@lune/process")

local function exec(cmdline: string)
	local pieces = {}
	for piece in string.gmatch(" " .. cmdline, "%s+([^%s]+)") do
		table.insert(pieces, piece)
	end

	local program = table.remove(pieces, 1)
	assert(program ~= nil, "cmdline must include a program")
	local result = process.exec(program, pieces, {
		stdio = "forward",
	})
	if not result.ok then
		process.exit(result.code)
	end
end

exec("wally install")
exec("wally-patch-package")
exec("rojo sourcemap -o sourcemap.json ./test.project.json")
exec("wally-package-types --sourcemap sourcemap.json Packages/")
exec("wally-package-types --sourcemap sourcemap.json DevPackages/")
