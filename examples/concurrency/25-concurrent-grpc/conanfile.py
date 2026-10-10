"""concurrency/25-concurrent-grpc Conan recipe (Conan 2.x).

The heaviest dependency graph in this project: the gRPC + protobuf + abseil
trio, built fully static (grpc/*:shared=False, protobuf/*:shared=False,
and everything either pulls in transitively -- abseil, c-ares, re2, zlib,
OpenSSL/boringssl -- via the */*:shared wildcard) so the runtime image
needs nothing beyond libstdc++: no .so files to stage, unlike the shared-
lib pattern 01-execution-models uses for oneTBB.

Versions are pinned to the exact combination the sibling cpp-statelessness
tutorial's 10-grpc-microservices example already verified builds on UBI10/
gcc via Conan (its conanfile.py) -- reusing a known-good set rather than
re-discovering one against this project's heaviest build.
"""

from conan import ConanFile


class Concurrency25ConcurrentGrpcConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        "*/*:shared": False,
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        self.requires("grpc/1.54.3")
        self.requires("protobuf/3.21.12", override=True)
        self.requires("abseil/20230125.3", override=True)
