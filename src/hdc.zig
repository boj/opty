const std = @import("std");

pub const DIMENSIONS: usize = 10000;
pub const WORDS: usize = (DIMENSIONS + 63) / 64;

pub const HyperVector = struct {
    bits: [WORDS]u64 = [_]u64{0} ** WORDS,

    /// XOR bind — associative, commutative, self-inverse
    pub fn bind(self: HyperVector, other: HyperVector) HyperVector {
        var result: HyperVector = .{};
        for (0..WORDS) |i| {
            result.bits[i] = self.bits[i] ^ other.bits[i];
        }
        return result;
    }

    /// Hamming distance via popcount
    pub fn distance(self: HyperVector, other: HyperVector) u32 {
        var dist: u32 = 0;
        for (0..WORDS) |i| {
            dist += @popCount(self.bits[i] ^ other.bits[i]);
        }
        return dist;
    }

    /// Normalized similarity in [-1, 1]. 1 = identical, 0 = orthogonal, -1 = inverse
    pub fn similarity(self: HyperVector, other: HyperVector) f64 {
        const dist: f64 = @floatFromInt(self.distance(other));
        return 1.0 - (2.0 * dist / @as(f64, @floatFromInt(DIMENSIONS)));
    }

    /// Deterministic generation from a 64-bit seed (splitmix64)
    pub fn fromSeed(seed: u64) HyperVector {
        var hv: HyperVector = .{};
        var s = seed;
        for (&hv.bits) |*word| {
            s +%= 0x9e3779b97f4a7c15;
            var z = s;
            z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
            z = z ^ (z >> 31);
            word.* = z;
        }
        return hv;
    }

    /// Circular bit-shift permutation (for sequence encoding)
    pub fn permute(self: HyperVector, n: u32) HyperVector {
        if (n == 0) return self;
        var result: HyperVector = .{};
        const total_bits: u32 = WORDS * 64;
        const shift = n % total_bits;
        const word_shift = shift / 64;
        const bit_shift: u6 = @intCast(shift % 64);

        for (0..WORDS) |i| {
            const src: usize = (i +% WORDS -% word_shift) % WORDS;
            if (bit_shift == 0) {
                result.bits[i] = self.bits[src];
            } else {
                const prev: usize = (src +% WORDS -% 1) % WORDS;
                result.bits[i] = (self.bits[src] << bit_shift) |
                    (self.bits[prev] >> @as(u6, @intCast(64 -% @as(u7, bit_shift))));
            }
        }
        return result;
    }

    pub fn isZero(self: HyperVector) bool {
        for (self.bits) |w| {
            if (w != 0) return false;
        }
        return true;
    }
};

/// Majority-vote bundle of multiple hypervectors
pub fn bundle(vectors: []const HyperVector) HyperVector {
    if (vectors.len == 0) return .{};
    if (vectors.len == 1) return vectors[0];

    var counts: [DIMENSIONS]i32 = [_]i32{0} ** DIMENSIONS;
    for (vectors) |v| {
        for (0..DIMENSIONS) |d| {
            const word = d / 64;
            const bit: u6 = @intCast(d % 64);
            if (v.bits[word] & (@as(u64, 1) << bit) != 0) {
                counts[d] += 1;
            } else {
                counts[d] -= 1;
            }
        }
    }

    var result: HyperVector = .{};
    for (0..DIMENSIONS) |d| {
        if (counts[d] > 0) {
            const word = d / 64;
            const bit: u6 = @intCast(d % 64);
            result.bits[word] |= (@as(u64, 1) << bit);
        }
    }
    return result;
}

/// Maps string identifiers to deterministic hypervectors via hashing
pub const AtomMap = struct {
    seed_base: u64 = 0x517cc1b727220a95,

    pub fn get(self: AtomMap, name: []const u8) HyperVector {
        const hash = std.hash.Wyhash.hash(self.seed_base, name);
        return HyperVector.fromSeed(hash);
    }
};

/// Fixed role vectors for structural code encoding
pub const Roles = struct {
    atoms: AtomMap = .{},

    pub fn name(self: Roles) HyperVector {
        return self.atoms.get("__role_name__");
    }
    pub fn params(self: Roles) HyperVector {
        return self.atoms.get("__role_params__");
    }
    pub fn returns(self: Roles) HyperVector {
        return self.atoms.get("__role_returns__");
    }
    pub fn calls(self: Roles) HyperVector {
        return self.atoms.get("__role_calls__");
    }
    pub fn module_role(self: Roles) HyperVector {
        return self.atoms.get("__role_module__");
    }
    pub fn fields(self: Roles) HyperVector {
        return self.atoms.get("__role_fields__");
    }
    pub fn kind(self: Roles) HyperVector {
        return self.atoms.get("__role_kind__");
    }
    pub fn imports(self: Roles) HyperVector {
        return self.atoms.get("__role_imports__");
    }
    pub fn file_role(self: Roles) HyperVector {
        return self.atoms.get("__role_filepath__");
    }
};

// -- tests --

test "bind is self-inverse" {
    const a = HyperVector.fromSeed(42);
    const b = HyperVector.fromSeed(99);
    const recovered = a.bind(b).bind(b);
    try std.testing.expectEqual(@as(u32, 0), a.distance(recovered));
}

test "bundle preserves similarity" {
    const a = HyperVector.fromSeed(1);
    const b = HyperVector.fromSeed(2);
    const c = HyperVector.fromSeed(3);
    const bundled = bundle(&[_]HyperVector{ a, b, c });
    try std.testing.expect(bundled.similarity(a) > 0.0);
    try std.testing.expect(bundled.similarity(b) > 0.0);
    try std.testing.expect(bundled.similarity(c) > 0.0);
}

test "random vectors are near-orthogonal" {
    const a = HyperVector.fromSeed(100);
    const b = HyperVector.fromSeed(200);
    try std.testing.expect(@abs(a.similarity(b)) < 0.1);
}

test "atom map is deterministic" {
    const atoms = AtomMap{};
    const v1 = atoms.get("hello");
    const v2 = atoms.get("hello");
    try std.testing.expectEqual(@as(u32, 0), v1.distance(v2));
}
