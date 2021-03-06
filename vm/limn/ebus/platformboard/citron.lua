local bus = {}

local lshift, rshift, tohex, arshift, band, bxor, bor, bnot, bror, brol =
	lshift, rshift, tohex, arshift, band, bxor, bor, bnot, bror, brol

local floor = math.floor

function bus.new(vm, c)
	local b = {}

	local mmu = c.mmu

	b.ports = {}
	local ports = b.ports

	function b.addPort(num, handler)
		if ports[num] then
			error(string.format("citron port 0x%X already taken", num))
		end

		ports[num] = handler
	end
	local addPort = b.addPort

	function b.bush(s, t, offset, v)
		if offset >= 1024 then
			return false
		end

		if band(offset, 3) ~= 0 then -- must be aligned to 4 bytes
			return false
		end

		local port = offset/4

		local h = ports[port]
		if h then
			return h(s, t, v)
		else
			return false
		end
	end

	return b
end

return bus