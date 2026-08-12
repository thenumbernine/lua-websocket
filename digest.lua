local digest
-- luacrypto
local has, crypto = pcall(require,'crypto')
if has then
	digest = crypto.digest
end
if not digest then
	-- luaossl
	local has, openssl_digest = pcall(require, 'openssl.digest')
	if has then
		local string = require 'ext.string'
		digest = function(algo, str, bin)
			local result = openssl_digest.new(algo):final(str)
			if not bin then result = string.hex(result) end
			return result
		end
	end
end
if not digest then
	-- https://github.com/fffonion/lua-resty-openssl
	local has, openssl_digest = pcall(require, 'resty.openssl.digest')
	if has then
		local string = require 'ext.string'
		digest = function(algo, str, bin)
			local result = assert(assert(openssl_digest.new(algo)):final(str))
			if not bin then result = string.hex(result) end
			return result
		end
	end
end
if not digest then
	error("couldn't find a digest function")
end
return digest
