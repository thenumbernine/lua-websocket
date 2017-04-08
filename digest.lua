local digest
	
local has, crypto = pcall(require,'crypto')	-- luacrypto
if has then
	digest = crypto.digest
end
if not digest then
	local has, openssl_digest = pcall(require,'openssl.digest')	-- luaossl
	if has then
		local function bin2hex(c) return ('%02x'):format(c:byte()) end
		digest = function(algo, str, bin)
			local result = openssl_digest.new(algo):final(str)
			if not bin then result = result:gsub('.', bin2hex) end
			return result
		end
	end
end
if not digest then
	error("couldn't find a digest function")
end
return digest
