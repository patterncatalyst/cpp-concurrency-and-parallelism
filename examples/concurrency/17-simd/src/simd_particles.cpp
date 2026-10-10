// concurrency/17-simd — scalar vs std::experimental::simd, AoS vs SoA.
//
// Doc 17 covers SIMD vectorization: one instruction, several data lanes,
// inside a single thread -- and the data layout choices (array-of-structs
// vs. struct-of-arrays) that determine whether vectorization is even
// available to the compiler or a portable SIMD library in the first place.
//
// This example updates the same kinematic recurrence (pos += vel * dt,
// applied for several steps) over the same initial particle data, three
// ways:
//
//   aos_scalar   -- array-of-structs layout, plain scalar loop. Each
//                   particle's x/y/z/vx/vy/vz fields sit interleaved in
//                   memory, so even the "x" update strides past five
//                   unrelated fields per particle -- the layout the chapter
//                   says defeats vectorization outright.
//   soa_scalar   -- struct-of-arrays layout (one contiguous array per
//                   field), plain scalar loop. Same arithmetic, contiguous
//                   access, no explicit vector type.
//   soa_simd     -- struct-of-arrays layout, explicit
//                   std::experimental::simd<float> (libstdc++'s Parallelism
//                   TS v2 implementation -- NOT std::simd, which is a
//                   proposed C++26 feature with no shipping standard-library
//                   support, per the chapter).
//
// Correctness: each particle's position update is a pure per-particle
// recurrence with no cross-particle interaction, and this program is
// compiled at the default (non-AVX2, no FMA) target baseline deliberately
// -- see the Containerfile/CMakeLists comments -- so neither path can fuse
// a multiply-add into a hardware FMA instruction the other lacks. Every
// variant therefore performs the IDENTICAL sequence of single-precision
// multiply-then-add operations per particle per step, just batched
// differently (one lane at a time vs. several lanes at once), so the final
// positions must be BIT-IDENTICAL across all three variants -- checked here
// via an order-sensitive FNV-1a hash over the final x/y/z values rather
// than a floating-point tolerance.
//
// Usage: simd_particles [-n PARTICLE_COUNT] [-s STEPS]
//
// Prints one simd_width= header line, then one layout= line per variant:
//
//   simd_width=4 n=2000000 steps=50 dt=0.01
//   layout=aos_scalar time_ms=312.456 hash=89abcdef01234567
//   layout=soa_scalar time_ms=198.234 hash=89abcdef01234567
//   layout=soa_simd   time_ms=61.789  hash=89abcdef01234567

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <experimental/simd>
#include <random>
#include <string>
#include <vector>

#include <fmt/core.h>

namespace stdx = std::experimental;

namespace {

constexpr std::size_t kDefaultN = 2'000'000;
constexpr int kDefaultSteps = 50;
constexpr float kDt = 0.01f;
constexpr std::uint32_t kSeed = 42;

// Array-of-structs: one particle's six fields interleaved contiguously,
// then the next particle's six fields. Updating just x/y/z strides past
// three unrelated fields (vx/vy/vz, which this demo never mutates) per
// particle -- the access pattern the chapter says defeats a SIMD load.
struct Particle {
    float x, y, z;
    float vx, vy, vz;
};

// Struct-of-arrays: every particle's x contiguous in one array, every y in
// another, and so on. The layout a vector load, multiply-add, and store
// actually want.
struct ParticlesSoA {
    std::vector<float> x, y, z;
    std::vector<float> vx, vy, vz;

    explicit ParticlesSoA(std::size_t n) : x(n), y(n), z(n), vx(n), vy(n), vz(n) {}
};

std::vector<Particle> make_aos(std::size_t n, std::uint32_t seed) {
    std::vector<Particle> particles(n);
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> pos_dist(-1000.0f, 1000.0f);
    std::uniform_real_distribution<float> vel_dist(-10.0f, 10.0f);
    for (auto& p : particles) {
        p.x = pos_dist(rng);
        p.y = pos_dist(rng);
        p.z = pos_dist(rng);
        p.vx = vel_dist(rng);
        p.vy = vel_dist(rng);
        p.vz = vel_dist(rng);
    }
    return particles;
}

ParticlesSoA aos_to_soa(const std::vector<Particle>& aos) {
    ParticlesSoA soa(aos.size());
    for (std::size_t i = 0; i < aos.size(); ++i) {
        soa.x[i] = aos[i].x;
        soa.y[i] = aos[i].y;
        soa.z[i] = aos[i].z;
        soa.vx[i] = aos[i].vx;
        soa.vy[i] = aos[i].vy;
        soa.vz[i] = aos[i].vz;
    }
    return soa;
}

// aos_scalar: array-of-structs, plain scalar loop. Every particle's three
// position fields are updated against its own velocity fields, but each
// field access strides past the others in memory.
void update_aos_scalar(std::vector<Particle>& particles, float dt, int steps) {
    for (int s = 0; s < steps; ++s) {
        for (auto& p : particles) {
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.z += p.vz * dt;
        }
    }
}

// soa_scalar: struct-of-arrays, plain scalar loop. Same arithmetic,
// contiguous per-field access, no explicit vector type -- the compiler MAY
// autovectorize this on its own, but nothing here asks it to.
void update_soa_scalar(ParticlesSoA& p, float dt, int steps) {
    const std::size_t n = p.x.size();
    for (int s = 0; s < steps; ++s) {
        for (std::size_t i = 0; i < n; ++i) p.x[i] += p.vx[i] * dt;
        for (std::size_t i = 0; i < n; ++i) p.y[i] += p.vy[i] * dt;
        for (std::size_t i = 0; i < n; ++i) p.z[i] += p.vz[i] * dt;
    }
}

// Explicit std::experimental::simd update of one contiguous field against
// its paired velocity field, width taken from the library's native width
// for this target rather than a hard-coded lane count -- the whole point of
// a portable SIMD type over hand-written intrinsics.
void update_axis_simd(float* pos, const float* vel, std::size_t n, float dt) {
    using V = stdx::native_simd<float>;
    const std::size_t width = V::size();
    const V vdt(dt);

    std::size_t i = 0;
    for (; i + width <= n; i += width) {
        V vp(pos + i, stdx::element_aligned);
        V vv(vel + i, stdx::element_aligned);
        (vp + vv * vdt).copy_to(pos + i, stdx::element_aligned);
    }
    for (; i < n; ++i) {
        pos[i] += vel[i] * dt; // scalar remainder, same arithmetic
    }
}

// soa_simd: struct-of-arrays, explicit std::experimental::simd per field.
void update_soa_simd(ParticlesSoA& p, float dt, int steps) {
    const std::size_t n = p.x.size();
    for (int s = 0; s < steps; ++s) {
        update_axis_simd(p.x.data(), p.vx.data(), n, dt);
        update_axis_simd(p.y.data(), p.vy.data(), n, dt);
        update_axis_simd(p.z.data(), p.vz.data(), n, dt);
    }
}

// Order-sensitive FNV-1a over the raw bits of every particle's final x, y,
// z value (in that order, particle by particle) -- a layout-independent
// checksum: whether the values came from an AoS struct or three SoA arrays,
// the same sequence of floats in the same order produces the same hash.
// Hashing bit patterns (not comparing with a tolerance) is deliberate: the
// arithmetic here is per-particle and FMA-free (see the file header), so
// the three variants are expected to be bit-identical, not merely close.
template <typename GetX, typename GetY, typename GetZ>
std::uint64_t hash_positions(std::size_t n, GetX get_x, GetY get_y, GetZ get_z) {
    std::uint64_t h = 1469598103934665603ULL; // FNV-1a 64-bit offset basis
    auto mix_byte = [&h](std::uint8_t byte) {
        h ^= byte;
        h *= 1099511628211ULL; // FNV-1a 64-bit prime
    };
    auto mix_float = [&](float f) {
        std::uint32_t bits;
        std::memcpy(&bits, &f, sizeof(bits));
        for (int b = 0; b < 4; ++b) {
            mix_byte(static_cast<std::uint8_t>(bits >> (b * 8)));
        }
    };
    for (std::size_t i = 0; i < n; ++i) {
        mix_float(get_x(i));
        mix_float(get_y(i));
        mix_float(get_z(i));
    }
    return h;
}

} // namespace

int main(int argc, char** argv) {
    std::size_t n = kDefaultN;
    int steps = kDefaultSteps;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-s" && i + 1 < argc) {
            steps = std::atoi(argv[++i]);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: simd_particles [-n PARTICLE_COUNT] [-s STEPS]\n");
            return 0;
        }
    }

    using V = stdx::native_simd<float>;
    fmt::print("simd_width={} n={} steps={} dt={}\n", V::size(), n, steps, kDt);

    std::vector<Particle> aos = make_aos(n, kSeed);
    ParticlesSoA soa_scalar = aos_to_soa(aos);
    ParticlesSoA soa_simd = aos_to_soa(aos);

    auto t0 = std::chrono::steady_clock::now();
    update_aos_scalar(aos, kDt, steps);
    auto t1 = std::chrono::steady_clock::now();
    double aos_scalar_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    auto t2 = std::chrono::steady_clock::now();
    update_soa_scalar(soa_scalar, kDt, steps);
    auto t3 = std::chrono::steady_clock::now();
    double soa_scalar_ms = std::chrono::duration<double, std::milli>(t3 - t2).count();

    auto t4 = std::chrono::steady_clock::now();
    update_soa_simd(soa_simd, kDt, steps);
    auto t5 = std::chrono::steady_clock::now();
    double soa_simd_ms = std::chrono::duration<double, std::milli>(t5 - t4).count();

    std::uint64_t aos_hash = hash_positions(
        n, [&](std::size_t i) { return aos[i].x; }, [&](std::size_t i) { return aos[i].y; },
        [&](std::size_t i) { return aos[i].z; });
    std::uint64_t soa_scalar_hash = hash_positions(
        n, [&](std::size_t i) { return soa_scalar.x[i]; },
        [&](std::size_t i) { return soa_scalar.y[i]; },
        [&](std::size_t i) { return soa_scalar.z[i]; });
    std::uint64_t soa_simd_hash = hash_positions(
        n, [&](std::size_t i) { return soa_simd.x[i]; },
        [&](std::size_t i) { return soa_simd.y[i]; },
        [&](std::size_t i) { return soa_simd.z[i]; });

    fmt::print("layout=aos_scalar time_ms={:.3f} hash={:016x}\n", aos_scalar_ms, aos_hash);
    fmt::print("layout=soa_scalar time_ms={:.3f} hash={:016x}\n", soa_scalar_ms, soa_scalar_hash);
    fmt::print("layout=soa_simd   time_ms={:.3f} hash={:016x}\n", soa_simd_ms, soa_simd_hash);

    return 0;
}
