--!strict
-- Compact binary encoding for mob snapshots.
--
-- Unreliable remote events are dropped by Roblox when their payload is larger than ~900 bytes
-- (Phase 5 test: "Unreliable Event dropped as its payload is too large", so most mobs never
-- reached the client). Each mob is packed into 20 bytes in a buffer, and a snapshot is split
-- into packets of at most MOBS_PER_PACKET mobs (~600 bytes).
--
-- Record (little endian): u16 id | u8 type code | u8 flags | f32 x | f32 y | f32 z (studs)
--                         | i16 yaw | i16 pitch   (angles scaled: value / 32767 * pi)

local MobSnapshotCodec = {}

MobSnapshotCodec.RECORD_BYTES = 20
MobSnapshotCodec.MOBS_PER_PACKET = 30

export type Record = { id: number, code: number, flags: number, x: number, y: number, z: number, yaw: number, pitch: number }

local function angleToI16(a: number): number
	a = (a + math.pi) % (2 * math.pi) - math.pi -- wrap to [-pi, pi)
	return math.clamp(math.round(a / math.pi * 32767), -32767, 32767)
end

-- Encode records into one or more buffers (each <= MOBS_PER_PACKET records).
function MobSnapshotCodec.encode(records: { Record }): { buffer }
	local packets = {}
	local per = MobSnapshotCodec.MOBS_PER_PACKET
	local R = MobSnapshotCodec.RECORD_BYTES
	for start = 1, #records, per do
		local n = math.min(per, #records - start + 1)
		local b = buffer.create(n * R)
		for k = 0, n - 1 do
			local r = records[start + k]
			local o = k * R
			buffer.writeu16(b, o, r.id % 65536)
			buffer.writeu8(b, o + 2, r.code % 256)
			buffer.writeu8(b, o + 3, r.flags % 256)
			buffer.writef32(b, o + 4, r.x)
			buffer.writef32(b, o + 8, r.y)
			buffer.writef32(b, o + 12, r.z)
			buffer.writei16(b, o + 16, angleToI16(r.yaw))
			buffer.writei16(b, o + 18, angleToI16(r.pitch))
		end
		table.insert(packets, b)
	end
	return packets
end

function MobSnapshotCodec.decode(b: buffer): { Record }
	local out = {}
	local R = MobSnapshotCodec.RECORD_BYTES
	for o = 0, buffer.len(b) - R, R do
		table.insert(out, {
			id = buffer.readu16(b, o),
			code = buffer.readu8(b, o + 2),
			flags = buffer.readu8(b, o + 3),
			x = buffer.readf32(b, o + 4),
			y = buffer.readf32(b, o + 8),
			z = buffer.readf32(b, o + 12),
			yaw = buffer.readi16(b, o + 16) / 32767 * math.pi,
			pitch = buffer.readi16(b, o + 18) / 32767 * math.pi,
		})
	end
	return out
end

return MobSnapshotCodec
