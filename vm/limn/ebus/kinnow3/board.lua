-- implements a simple 8-bit color, variable-resolution framebuffer, with simple 2d acceleration

local lshift, rshift, tohex, arshift, band, bxor, bor, bnot, bror, brol =
	lshift, rshift, tohex, arshift, band, bxor, bor, bnot, bror, brol

local floor = math.floor

local gpu = {}

local palette = require("limn/ebus/kinnow3/kinnow_palette")

-- slot space:
-- 0000000-0003FFF: declROM
-- 0004000-000401F: card command ports
-- 0100000-02FFFFF: possible VRAM

-- == card ==
-- port 0: commands
--	0: idle
--	1: get info
--  2: draw rectangle
--    port 1: x,y
--    port 2: w,h
--    port 3: color
--  3: scroll area vertically
--    port 1: x,y
--    port 2: w,h
--    port 3: rows,backfill
--  4: enable vsync interrupt
--  5: set pixelpipe read region
--    port 1: x,y
--    port 2: w,h
--  6: set pixelpipe write region
--    port 1: x,y
--    port 2: w,h 
--  7: set pixelpipe write ignore
--    port 1: color
-- port 1: data
-- port 2: data
-- port 3: data
-- port 4: pixelpipe

-- poorly written in some spots and doesn't do some bounds checks, a badly written driver could cause the vm to segfault here


function gpu.new(vm, c, page, intn)
	local g = {}

	local log = vm.log.log

	local function int()
		c.cpu.int(intn)
	end

	g.height = 768
	local height = g.height

	g.width = 1024
	local width = g.width

	local fbs = width * height
	local bytesPerRow = width

	g.framebuffer = ffi.new("uint8_t[?]", fbs) -- least significant bit is left-most pixel
	local framebuffer = g.framebuffer

	local imageData = love.image.newImageData(width, height)

	g.image = love.graphics.newImage(imageData)
	local image = g.image

	imageData:release()

	g.vsync = false

	local enabled = true

	vm.registerOpt("-kinnow3,display", function (arg, i)
		local w,h = tonumber(arg[i+1]), tonumber(arg[i+2])

		g.height = h
		g.width = w
		height = h
		width = w

		fbs = width * height
		bytesPerRow = width

		g.framebuffer = nil
		g.framebuffer = ffi.new("uint8_t[?]", fbs)
		framebuffer = g.framebuffer

		g.image:release()

		local imageData = love.image.newImageData(width, height)

		g.image = love.graphics.newImage(imageData)
		image = g.image

		imageData:release()

		love.window.setMode(width, height, {["resizable"]=true})

		if c.window then
			c.window:setDim(width, height)
		end

		return 3
	end)

	vm.registerOpt("-kinnow3,off", function (arg, i)
		enabled = false

		return 1
	end)

	local subRectX1 = false
	local subRectY1 = false
	local subRectX2 = false
	local subRectY2 = false
	local m = false

	local function saneX(x)
		if x < 0 then
			x = 0
		end
		if x >= width then
			x = width - 1
		end
		return x
	end

	local function saneY(y)
		if y < 0 then
			y = 0
		end
		if y >= height then
			y = height - 1
		end
		return y
	end

	local function subRect(x,y,x1,y1)
		x = saneX(x)
		y = saneY(y)
		x1 = saneX(x1)
		y1 = saneY(y1)

		if not subRectX1 then -- first thingy this frame
			subRectX1 = x
			subRectY1 = y
			subRectX2 = x1
			subRectY2 = y1
			return
		end

		if x < subRectX1 then
			subRectX1 = x
		end
		if y < subRectY1 then
			subRectY1 = y
		end
		if x1 > subRectX2 then
			subRectX2 = x1
		end
		if y1 > subRectY2 then
			subRectY2 = y1
		end
	end

	local function action(s, offset, v, d)
		if d == 0 then -- pixel
			if s == 0 then
				-- 1 modified pixel
				local e1 = band(v, 0xFF)

				framebuffer[offset] = e1

				local bx = offset % bytesPerRow
				local by = floor(offset / bytesPerRow)

				subRect(bx,by,bx,by)
			elseif s == 1 then
				-- 2 modified pixels

				local e1 = band(v, 0xFF)
				local e2 = rshift(band(v, 0xFF00), 8)

				framebuffer[offset] = e1
				framebuffer[offset + 1] = e2

				local bx = offset % bytesPerRow
				local by = floor(offset / bytesPerRow)

				subRect(bx,by,bx+1,by)
			elseif s == 2 then
				-- 4 modified pixels

				local e1 = band(v, 0xFF)
				local e2 = rshift(band(v, 0xFF00), 8)
				local e3 = rshift(band(v, 0xFF0000), 16)
				local e4 = rshift(band(v, 0xFF000000), 24)

				framebuffer[offset] = e1
				framebuffer[offset + 1] = e2
				framebuffer[offset + 2] = e3
				framebuffer[offset + 3] = e4

				local bx = offset % bytesPerRow
				local by = floor(offset / bytesPerRow)

				subRect(bx,by,bx+3,by)
			end
		elseif d == 1 then -- rectangle
			local rw = rshift(offset, 16)
			local rh = band(offset, 0xFFFF)

			local rx = rshift(s, 16)
			local ry = band(s, 0xFFFF)

			local x1 = rx+rw-1
			local y1 = ry+rh-1

			for x = rx, x1 do
				for y = ry, y1 do
					framebuffer[y * width + x] = v
				end
			end

			subRect(rx,ry,x1,y1)
		elseif d == 2 then -- scroll
			local rw = rshift(offset, 16)
			local rh = band(offset, 0xFFFF)

			local rx = rshift(s, 16)
			local ry = band(s, 0xFFFF)

			local rows = rshift(v, 16)
			local color = band(v, 0xFFFF)

			local mod = rows * width

			local x1 = rx+rw-1
			local y1 = ry+rh-1

			for y = ry, y1-rows do
				for x = rx, x1 do
					local b = y * width + x
					framebuffer[b] = framebuffer[b + mod]
				end
			end

			for y = y1-rows, y1 do
				for x = rx, x1 do
					framebuffer[y * width + x] = color
				end
			end

			subRect(rx,ry,x1,y1)
		elseif d == 3 then -- s2s
			-- TODO
		end
		m = true
	end

	local function gpuh(s, t, offset, v)
		if s == 0 then -- byte
			if t == 0 then
				return framebuffer[offset]
			else
				action(s, offset, v, 0)
			end
		elseif s == 1 then -- int
			if t == 0 then
				local u1, u2 = framebuffer[offset], framebuffer[offset + 1]

				return (u2 * 0x100) + u1
			else
				action(s, offset, v, 0)
			end
		elseif s == 2 then -- long
			if t == 0 then
				local u1, u2, u3, u4 = framebuffer[offset], framebuffer[offset + 1], framebuffer[offset + 2], framebuffer[offset + 3]

				return (u4 * 0x1000000) + (u3 * 0x10000) + (u2 * 0x100) + u1
			else
				action(s, offset, v, 0)
			end
		end
	end

	local pxpiperX = 0
	local pxpiperY = 0
	local pxpiperW = 0
	local pxpiperH = 0

	local pxpiperpX = 0
	local pxpiperpY = 0

	local pxpipewX = 0
	local pxpipewY = 0
	local pxpipewW = 0
	local pxpipewH = 0
	local pxpipewi = 0xFFFFFFFF

	local pxpipewpX = 0
	local pxpipewpY = 0

	local function readPixel()
		local tx = pxpiperX + pxpiperpX
		local ty = pxpiperY + pxpiperpY

		local px = framebuffer[ty * width + tx]

		pxpiperpX = pxpiperpX + 1
		if pxpiperpX >= pxpiperW then
			pxpiperpX = 0
			pxpiperpY = pxpiperpY + 1

			if pxpiperpY >= pxpiperH then
				pxpiperpX = 0
				pxpiperpY = 0
			end
		end

		return px
	end

	local function writePixel(color)
		local tx = pxpipewX + pxpipewpX
		local ty = pxpipewY + pxpipewpY

		framebuffer[ty * width + tx] = color
		subRect(tx, ty, tx, ty)

		pxpipewpX = pxpipewpX + 1
		if pxpipewpX >= pxpipewW then
			pxpipewpX = 0
			pxpipewpY = pxpipewpY + 1

			if pxpipewpY >= pxpipewH then
				pxpipewpX = 0
				pxpipewpY = 0
			end
		end
	end

	local port13 = 0
	local port14 = 0
	local port15 = 0

	local function cmdh(s, t, v)
		if not enabled then return 0 end

		if s ~= 0 then
			return 0
		end

		if t == 1 then
			if v == 1 then -- gpuinfo
				port13 = width
				port14 = height
			elseif v == 2 then -- rectangle
				-- port13 is x,y, both 16-bit
				-- port14 is w,h; both 16-bit
				-- port15 is color

				action(port13, port14, port15, 1)
			elseif v == 3 then -- scroll vertically
				-- port13 is x,y
				-- port14 is w,h
				-- port15 is rows,backfill

				action(port13, port14, port15, 2)
			elseif v == 4 then -- enable vsync
				g.vsync = true
			elseif v == 5 then -- set pixelpipe read region
				-- port13 is x,y
				-- port14 is w,h

				local x = rshift(port13, 16)
				local y = band(port13, 0xFFFF)

				local w = rshift(port14, 16)
				local h = band(port14, 0xFFFF)

				pxpiperX = x
				pxpiperY = y
				pxpiperW = w
				pxpiperH = h
				pxpiperpX = 0
				pxpiperpY = 0
			elseif v == 6 then -- set pixelpipe write region
				-- port13 is x,y
				-- port14 is w,h

				local x = rshift(port13, 16)
				local y = band(port13, 0xFFFF)

				local w = rshift(port14, 16)
				local h = band(port14, 0xFFFF)

				pxpipewX = x
				pxpipewY = y
				pxpipewW = w
				pxpipewH = h
				pxpipewpX = 0
				pxpipewpY = 0
			elseif v == 7 then -- set pixelpipe write ignore
				-- port13 is color

				pxpipewi = port13
			elseif v == 8 then -- s2s copy
				-- port13 is x1,y1
				-- port14 is x2,y2
				-- port15 is w,h

				action(port13, port14, port15, 3)
			end
		else
			return 0
		end
	end

	local k2lt = {
		[0] = string.byte("k"),
		string.byte("i"),
		string.byte("n"),
		string.byte("n"),
		string.byte("o"),
		string.byte("w"),
		string.byte("3"),
	}

	function g.handler(s, t, offset, v)
		if not enabled then return 0 end

		if offset < 0x4000 then -- declROM
			if offset == 0 then
				return 0x0C007CA1
			elseif offset == 4 then
				return 0x4B494E58
			elseif (offset - 8) < 7 then
				return k2lt[offset - 8]
			else
				return 0
			end
		elseif offset < 0x4010 then -- cmd
			local lo = offset - 0x4000
			if lo == 0 then
				return cmdh(s, t, v)
			elseif lo == 4 then
				if t == 0 then
					return port13
				else
					port13 = v
				end
			elseif lo == 8 then
				if t == 0 then
					return port14
				else
					port14 = v
				end
			elseif lo == 12 then
				if t == 0 then
					return port15
				else
					port15 = v
				end
			elseif lo == 16 then
				if t == 0 then
					return readPixel()
				else
					writePixel(v)
				end
			else
				return 0
			end
		elseif (offset >= 0x100000) and (offset < (0x100000 + fbs)) then
			return gpuh(s, t, offset-0x100000, v)
		else
			return 0
		end
	end

	function g.reset()
		g.vsync = false
	end

	if c.window then
		c.window.gc = true

		local wc = c.window:addElement(window.canvas(c.window, function (self, x, y) 
			if enabled then
				love.graphics.setColor(0.3,0.0,0.1,1)
				love.graphics.print("Framebuffer not initialized by guest.", x + 10, y + 10)
				love.graphics.setColor(1,1,1,1)

				if m then
					local uw, uh = subRectX2 - subRectX1 + 1, subRectY2 - subRectY1 + 1

					if (uw == 0) or (uh == 0) then
						m = false
						return
					end

					local imageData = love.image.newImageData(uw, uh)

					local base = (subRectY1 * width) + subRectX1

					imageData:mapPixel(function (x,y,r,g,b,a)
						local e = palette[framebuffer[base + (y * width + x)]]

						return e.r/255,e.g/255,e.b/255,1
					end, 0, 0, uw, uh)

					image:replacePixels(imageData, nil, nil, subRectX1, subRectY1)

					imageData:release()

					m = false
					subRectX1 = false
				end

				love.graphics.setColor(1,1,1,1)
				love.graphics.draw(image, x, y, 0)

				if g.vsync then
					int()
				end

				vsyncf = 1
			end
		end, width, height))

		wc.x = 0
		wc.y = 20
	end


	return g
end

return gpu